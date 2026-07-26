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
	unset MACKAS_MONITOR_NOTIFY MACKAS_MONITOR_POLL_INTERVAL
	export HOME="$TESTDIR"
	SERVER_PID=""
	MONITOR_TOOL="$REPO_ROOT/tools/mackas-monitor"
	mkdir -p "$TESTDIR/bin"
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

# Same, but each argument is one JSON body, served one per request in order;
# the last one is sticky (a poller that keeps asking keeps getting it). This
# is what makes "notify once across many 'building' polls" assertable: the
# bridge really does change state under the poller, exactly as a build does.
# HTTPServer is single-threaded, so the counter needs no lock.
#
# It also reads its bodies from a FILE rather than interpolating them into a
# Python literal the way start_fake_bridge does. That matters for any body
# containing a backslash: inside `b'''$body'''` Python would eat the JSON's
# own \" and \\ escapes before json.loads ever sees them, so a payload-bearing
# recipe name would arrive as invalid JSON instead of as the payload.
start_fake_bridge_sequence() {
	printf '%s\n' "$@" > "$TESTDIR/bodies.jsonl"
	cat > "$TESTDIR/fake_bridge_seq.py" <<'PYEOF'
import http.server
import sys

with open(sys.argv[1]) as fh:
    BODIES = [line.encode() for line in fh.read().splitlines() if line.strip()]
served = [0]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = BODIES[min(served[0], len(BODIES) - 1)]
        served[0] += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
	python3 "$TESTDIR/fake_bridge_seq.py" "$TESTDIR/bodies.jsonl" > "$TESTDIR/port.txt" &
	SERVER_PID=$!
	for _ in $(seq 1 50); do
		[ -s "$TESTDIR/port.txt" ] && break
		sleep 0.1
	done
	FAKE_PORT="$(cat "$TESTDIR/port.txt" 2>/dev/null)"
	[ -n "$FAKE_PORT" ]
}

# ---------------------------------------------------------------------------
# Notification fixtures
#
# Every notify test runs the tool with PATH set to $TESTDIR/bin and NOTHING
# else (run_monitor), so `shutil.which` can only ever find the fakes below.
# That is not just tidiness: without it, a dev Mac with a real osascript (all
# of them) or a brew-installed terminal-notifier would pop actual
# notifications on the desktop during the suite, and the "prefers
# terminal-notifier" test would pass or fail depending on what the machine
# happens to have installed. Hence also the absolute /usr/bin/python3 -- the
# same interpreter mackas itself invokes, and one that survives an emptied
# PATH.
# ---------------------------------------------------------------------------

# fake_notifier NAME [EXIT_STATUS] -- installs $TESTDIR/bin/NAME, which
# appends one CALL line plus one ARG: line per argument to $TESTDIR/NAME.log.
fake_notifier() {
	local name="$1" status="${2:-0}"
	# printf, not echo: macOS's /bin/sh is bash in POSIX mode with xpg_echo on,
	# so `echo` there EXPANDS backslash escapes -- which would quietly rewrite
	# the very escaping the injection test exists to check.
	cat > "$TESTDIR/bin/$name" <<EOF
#!/bin/sh
{
	printf 'CALL\n'
	for a in "\$@"; do printf 'ARG:%s\n' "\$a"; done
} >> "$TESTDIR/$name.log"
exit $status
EOF
	chmod +x "$TESTDIR/bin/$name"
}

run_monitor() {
	local saved_path="$PATH"
	PATH="$TESTDIR/bin"
	run /usr/bin/python3 "$MONITOR_TOOL" "$@"
	PATH="$saved_path"
}

# How many times NAME was invoked.
notifier_calls() {
	grep -c '^CALL$' "$TESTDIR/$1.log" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# --notify: native macOS notifications
# ---------------------------------------------------------------------------

@test "monitor: --notify is off by default -- no notifier is invoked" {
	fake_notifier osascript
	fake_notifier terminal-notifier
	start_fake_bridge '{"status": "building", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 3, "total": 10}, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --once
	[ "$status" -eq 0 ]
	assert_fails test -e "$TESTDIR/osascript.log"
	assert_fails test -e "$TESTDIR/terminal-notifier.log"
}

@test "monitor --notify: a building bridge notifies 'build started' via osascript" {
	fake_notifier osascript
	start_fake_bridge '{"status": "building", "targets": ["core-image-base"], "machine": "beaglebone", "distro": "Angstrom", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 3, "total": 10}, "failed_tasks": [], "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --once --notify
	[ "$status" -eq 0 ]
	# The BODY is what the build was asked to produce and what for -- not the
	# task that happens to be running, which at 'started' is usually nothing.
	grep -qxF 'ARG:display notification "core-image-base for beaglebone/Angstrom" with title "mackas: build started"' \
		"$TESTDIR/osascript.log"
	[ "$(notifier_calls osascript)" -eq 1 ]
}

@test "monitor --notify: MACKAS_MONITOR_NOTIFY=1 is equivalent to the flag" {
	fake_notifier osascript
	start_fake_bridge '{"status": "success", "targets": ["core-image-base"], "machine": "beaglebone", "distro": "Angstrom", "current": {"recipe": null, "task": null}, "progress": {"done": 10, "total": 10}, "failed_tasks": [], "recent_events": []}'
	export MACKAS_MONITOR_NOTIFY=1
	run_monitor --port "$FAKE_PORT"
	[ "$status" -eq 0 ]
	grep -qF 'with title "mackas: build succeeded"' "$TESTDIR/osascript.log"
	# Success leads with WHAT was built and what for, then the counts.
	grep -qF "core-image-base for beaglebone/Angstrom" "$TESTDIR/osascript.log"
	grep -qF "10/10 tasks" "$TESTDIR/osascript.log"
}

@test "monitor --notify: MACKAS_MONITOR_NOTIFY=1 also works through 'mackas monitor'" {
	# The wrapper has no --notify flag of its own, so the env var is the only
	# way to reach this feature via `mackas monitor`. Both fakes are installed
	# and PATH-prepended (not replaced -- mackas itself needs a real PATH), so
	# no real notifier can be reached.
	fake_notifier osascript
	fake_notifier terminal-notifier
	start_fake_bridge '{"status": "failed", "targets": ["core-image-base"], "machine": "beaglebone", "distro": "Angstrom", "current": {"recipe": "zlib", "task": "do_install"}, "progress": {"done": 4, "total": 10}, "failed_tasks": [{"recipe": "busybox_1.36.bb", "task": "do_compile"}], "failed_count": 1, "recent_events": []}'
	PATH="$TESTDIR/bin:$PATH" MACKAS_MONITOR_NOTIFY=1 run "$MACKAS" monitor --port "$FAKE_PORT"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF '[failed] 4/10'
	grep -qxF 'ARG:mackas: build failed' "$TESTDIR/terminal-notifier.log"
	# The task that FAILED, not the one that happened to be current (zlib),
	# plus which build it was.
	grep -qF 'busybox_1.36.bb:do_compile' "$TESTDIR/terminal-notifier.log"
	grep -qF 'beaglebone/Angstrom' "$TESTDIR/terminal-notifier.log"
	assert_fails grep -qF 'zlib' "$TESTDIR/terminal-notifier.log"
}

@test "monitor --notify: terminal-notifier is preferred when both are on PATH" {
	fake_notifier osascript
	fake_notifier terminal-notifier
	start_fake_bridge '{"status": "success", "current": {"recipe": null, "task": null}, "progress": {"done": 10, "total": 10}, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --notify
	[ "$status" -eq 0 ]
	grep -qxF 'ARG:-title' "$TESTDIR/terminal-notifier.log"
	grep -qxF 'ARG:mackas: build succeeded' "$TESTDIR/terminal-notifier.log"
	grep -qxF 'ARG:-group' "$TESTDIR/terminal-notifier.log"
	# ...and osascript is not used as well as it, only instead of it.
	assert_fails test -e "$TESTDIR/osascript.log"
}

@test "monitor --notify: exactly one start notification across many building polls" {
	fake_notifier osascript
	export MACKAS_MONITOR_POLL_INTERVAL=0.05
	start_fake_bridge_sequence \
		'{"status": "idle", "current": {"recipe": null, "task": null}, "progress": {"done": 0, "total": 0}, "recent_events": []}' \
		'{"status": "building", "current": {"recipe": "busybox", "task": "do_fetch"}, "progress": {"done": 1, "total": 10}, "recent_events": []}' \
		'{"status": "building", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 2, "total": 10}, "recent_events": []}' \
		'{"status": "building", "current": {"recipe": "zlib", "task": "do_compile"}, "progress": {"done": 3, "total": 10}, "recent_events": []}' \
		'{"status": "building", "current": {"recipe": "zlib", "task": "do_install"}, "progress": {"done": 4, "total": 10}, "recent_events": []}' \
		'{"status": "success", "current": {"recipe": null, "task": null}, "progress": {"done": 10, "total": 10}, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --notify
	[ "$status" -eq 0 ]
	# Six polls, four of them 'building', four different recipe:task pairs --
	# and exactly two notifications: started, succeeded. Never per task.
	[ "$(notifier_calls osascript)" -eq 2 ]
	[ "$(grep -cF 'mackas: build started' "$TESTDIR/osascript.log")" -eq 1 ]
	[ "$(grep -cF 'mackas: build succeeded' "$TESTDIR/osascript.log")" -eq 1 ]
	assert_fails grep -qF 'mackas: build failed' "$TESTDIR/osascript.log"
}

@test "monitor --notify: a build that fails notifies started then failed, once each" {
	fake_notifier osascript
	export MACKAS_MONITOR_POLL_INTERVAL=0.05
	start_fake_bridge_sequence \
		'{"status": "building", "current": {"recipe": "busybox", "task": "do_fetch"}, "progress": {"done": 1, "total": 10}, "recent_events": []}' \
		'{"status": "building", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 2, "total": 10}, "recent_events": []}' \
		'{"status": "failed", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 2, "total": 10}, "failed_tasks": [{"recipe": "busybox_1.36.bb", "task": "do_compile"}], "failed_count": 1, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --notify
	[ "$status" -eq 1 ]
	[ "$(notifier_calls osascript)" -eq 2 ]
	[ "$(grep -cF 'mackas: build started' "$TESTDIR/osascript.log")" -eq 1 ]
	grep -qxF 'ARG:display notification "busybox_1.36.bb:do_compile" with title "mackas: build failed"' \
		"$TESTDIR/osascript.log"  # no machine/distro known in this fixture
}

@test "monitor --notify: a hostile recipe name cannot break out of the AppleScript" {
	# The recipe name comes from the build, and osascript parses its -e
	# argument as AppleScript SOURCE: an unescaped double quote would end the
	# string literal and everything after it would run as script. `do shell
	# script` is what that buys an attacker, hence this exact payload.
	fake_notifier osascript
	start_fake_bridge_sequence '{"status": "building", "targets": ["ev\"il\\pkg\"; do shell script \"touch /tmp/mackas-pwned"], "current": {"recipe": null, "task": null}, "progress": {"done": 1, "total": 2}, "failed_tasks": [], "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --once --notify
	[ "$status" -eq 0 ]
	# Exact match: both the " and the \ are backslash-escaped, so the whole
	# payload stays inside one string literal and the statement still ends
	# with the title.
	grep -qxF 'ARG:display notification "ev\"il\\pkg\"; do shell script \"touch /tmp/mackas-pwned" with title "mackas: build started"' \
		"$TESTDIR/osascript.log"
	# The whole payload is one -e argument, not several: no injected statement.
	[ "$(grep -c '^ARG:' "$TESTDIR/osascript.log")" -eq 2 ]
	assert_fails test -e /tmp/mackas-pwned
}

@test "monitor --notify: the escaping round-trips through the real osascript" {
	# The unit above pins the bytes; this pins that those bytes are VALID
	# AppleScript that evaluates back to the original string. `return <literal>`
	# displays nothing -- it only prints to stdout -- so this stays hermetic.
	[ -x /usr/bin/osascript ] || skip "no /usr/bin/osascript on this host"
	local hostile='ev"il\pkg "; beep'
	local literal
	literal="$(/usr/bin/python3 - "$MONITOR_TOOL" "$hostile" <<'PYEOF'
import importlib.machinery
import importlib.util
import sys

# spec_from_file_location alone returns a loader-less spec here: mackas-monitor
# has no .py suffix, so no source loader matches it. Name the loader instead.
loader = importlib.machinery.SourceFileLoader("mackas_monitor", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
sys.stdout.write(mod.applescript_string(sys.argv[2]))
PYEOF
)"
	# osascript is invoked with a BOUNDED wait, and a timeout SKIPS rather
	# than fails. Found the hard way: in a background/SSH session with no Aqua
	# session, osascript writes its answer correctly and then never exits --
	# so a plain `run` here wedges the whole suite forever rather than failing.
	# The escaping itself is already pinned byte-exactly by the test above;
	# this one only adds "and those bytes are valid AppleScript", which is not
	# worth a hang when the host cannot answer.
	/usr/bin/osascript -e "return $literal" > "$TESTDIR/osa.out" 2>/dev/null &
	local osa=$! i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$osa" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$osa" 2>/dev/null; then
		kill -9 "$osa" 2>/dev/null
		skip "osascript did not exit within 10s (no Aqua session -- it answers but hangs on exit here)"
	fi
	[ "$(cat "$TESTDIR/osa.out")" = "$hostile" ]
}

@test "monitor --notify: a notifier that fails never breaks the monitor" {
	fake_notifier terminal-notifier 1
	fake_notifier osascript 1
	start_fake_bridge '{"status": "success", "current": {"recipe": null, "task": null}, "progress": {"done": 10, "total": 10}, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --notify
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[success] 10/10'
	# terminal-notifier failing is what makes osascript get tried at all.
	[ "$(notifier_calls terminal-notifier)" -eq 1 ]
	[ "$(notifier_calls osascript)" -eq 1 ]
}

@test "monitor --notify: no notifier at all degrades to plain output" {
	# $TESTDIR/bin is empty and is the whole PATH, so neither binary exists.
	start_fake_bridge '{"status": "failed", "current": {"recipe": "busybox", "task": "do_compile"}, "progress": {"done": 4, "total": 10}, "recent_events": []}'
	run_monitor --port "$FAKE_PORT" --notify
	[ "$status" -eq 1 ]
	printf '%s\n' "$output" | grep -qF '[failed] 4/10'
}

@test "monitor --notify: the tool's --help documents the osascript permission gotcha" {
	run /usr/bin/python3 "$MONITOR_TOOL" --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'silently dropped'
	printf '%s\n' "$output" | grep -qi 'MACKAS_MONITOR_NOTIFY'
}
