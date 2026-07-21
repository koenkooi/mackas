#!/usr/bin/env bats
#
# Tests for `mackas monitor` -- polling the in-container bitbake progress
# bridge (mackas-uibridge/mackasjson.py, TODO.md item 22).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `monitor` never touches the Apple container runtime -- it only polls an
# HTTP port. These start a tiny real Python HTTP server (bound to an
# OS-assigned ephemeral port, printed back so the test can point `monitor`
# at it -- no fixed-port collision risk) standing in for the real bridge,
# matching buildstats_analyze.bats's own "pure local process, no container
# mock needed" style.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	export HOME="$TESTDIR"
	SERVER_PID=""
}

teardown() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	cd /
	rm -rf "$TESTDIR"
}

# Starts a fixture bridge serving BODY once per request, forever, on an
# OS-assigned port. Sets FAKE_PORT and SERVER_PID.
start_fake_bridge() {
	local body="$1"
	cat > "$TESTDIR/fake_bridge.py" <<PYEOF
import http.server

BODY = b'''$body'''

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
	python3 "$TESTDIR/fake_bridge.py" > "$TESTDIR/port.txt" &
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		[ -s "$TESTDIR/port.txt" ] && break
		sleep 0.1
	done
	FAKE_PORT="$(cat "$TESTDIR/port.txt" 2>/dev/null)"
	[ -n "$FAKE_PORT" ]
}

# ---------------------------------------------------------------------------
# --help / argument parsing
# ---------------------------------------------------------------------------

@test "monitor --help prints usage and does nothing" {
	run "$MACKAS" monitor --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'bitbake progress'
}

@test "monitor: an unknown option is refused" {
	run "$MACKAS" monitor --bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown option'
}

@test "monitor: an unexpected positional argument is refused" {
	run "$MACKAS" monitor bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unexpected argument'
}

@test "monitor: --port needs a value" {
	run "$MACKAS" monitor --port
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a value'
}

# ---------------------------------------------------------------------------
# Unreachable bridge
# ---------------------------------------------------------------------------

@test "monitor: an unreachable port gives a clear error, not a stack trace" {
	run "$MACKAS" monitor --port 18801 --once
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'could not reach the bridge'
}

# ---------------------------------------------------------------------------
# A real fixture bridge, polled for real
# ---------------------------------------------------------------------------

@test "monitor --once prints a single snapshot from a real bridge" {
	start_fake_bridge '{"status": "building", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 3, "total": 10}, "recent_events": []}'
	run "$MACKAS" monitor --port "$FAKE_PORT" --once
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[building] 3/10  busybox:do_compile'
}

@test "monitor follows until the bridge reports success, then exits 0" {
	start_fake_bridge '{"status": "success", "current": {"recipe": null, "task": null}, "progress": {"done": 10, "total": 10}, "recent_events": []}'
	run "$MACKAS" monitor --port "$FAKE_PORT"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[success] 10/10'
}

@test "monitor follows until the bridge reports failed, then exits non-zero" {
	start_fake_bridge '{"status": "failed", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 4, "total": 10}, "recent_events": []}'
	run "$MACKAS" monitor --port "$FAKE_PORT"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF '[failed] 4/10'
}
