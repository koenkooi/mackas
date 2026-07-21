#!/usr/bin/env bats
#
# Tests for setup_kas_container's sha256 gate.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# setup_kas_container downloads kas-container and refuses to install it unless
# it matches the pinned sha256. That gate is the only thing standing between a
# moved/hijacked upstream URL and a script mackas then runs with the user's
# build. These drive it in lib mode (MACKAS_LIB_ONLY=1), shadowing `curl` and
# `shasum` with shell functions so the "download" and the checksum are fully
# controlled and nothing touches the network.
#
# NOTE: bats' `run` must not be used in tests that source mackas -- mackas
# defines its own run(). setup_kas_container calls die() on a mismatch, which
# exits, so it is invoked inside an explicit ( subshell ) whose status is
# captured, exactly as volumes.bats does.

bats_require_minimum_version 1.5.0

load helpers

lib_setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	SCRIPT_DIR="$REPO_ROOT"
	TESTDIR="$(make_tmpdir)"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	DRY_RUN=0
	ASSUME_YES=1
	CURL_MARKER="$TESTDIR/curl.ran"
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

# A fake curl: honour `-o FILE`, note that it ran, and write BODY (default a
# runnable stub) to FILE. The URL is ignored -- nothing leaves the machine.
# CURL_BODY/FAKE_SUM are GLOBAL on purpose: the nested curl()/shasum() run long
# after these helpers return, so a `local` would be out of scope at call time.
fake_curl() {
	CURL_BODY="${1:-$(printf '#!/bin/bash\nexit 0\n')}"
	# shellcheck disable=SC2317  # invoked indirectly via run()
	curl() {
		local out=""
		while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
		touch "$CURL_MARKER"
		printf '%s' "$CURL_BODY" > "$out"
	}
}

# A fake shasum that always prints SUM for whatever file it is handed.
fake_shasum() {
	FAKE_SUM="$1"
	# shellcheck disable=SC2317  # invoked directly by setup_kas_container
	shasum() { printf '%s  %s\n' "$FAKE_SUM" "${@: -1}"; }
}

# ---------------------------------------------------------------------------
# Mismatch: the gate must refuse AND remove the partial download.
# ---------------------------------------------------------------------------

@test "sha256 gate: a wrong checksum dies and deletes the partial download" {
	# curl writes attacker bytes; shasum reports a sum that is not the pinned one.
	fake_curl "PWNED-not-the-real-kas-container"
	fake_shasum "0000000000000000000000000000000000000000000000000000000000000000"

	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'sha256 mismatch'
	# The partial/attacker file must NOT be left on disk for anything to run.
	[ ! -e "$KAS_CONTAINER_BIN" ]
}

@test "sha256 gate: the attacker bytes are never left installed" {
	# The complement of the above, stated as the security property: whatever the
	# download contained, a failed verify leaves nothing executable behind.
	fake_curl "$(printf '#!/bin/sh\ntouch %s/EXPLOIT_RAN\n' "$TESTDIR")"
	fake_shasum "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	[ ! -e "$KAS_CONTAINER_BIN" ]
	# And it was never executed either (the gate runs BEFORE --version).
	[ ! -e "$TESTDIR/EXPLOIT_RAN" ]
}

# ---------------------------------------------------------------------------
# A pre-seeded binary whose (faked) sum is wrong forces a re-fetch.
# ---------------------------------------------------------------------------

@test "sha256 gate: an existing binary with the wrong sum triggers a re-fetch" {
	mkdir -p "$MACKAS_BIN"
	printf 'stale-kas-container\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"

	# The faked sum never matches the pinned one, so verification still fails
	# after the re-fetch -- but curl running at all proves the stale binary was
	# rejected rather than trusted.
	fake_curl "fresh-but-still-unverifiable"
	fake_shasum "1111111111111111111111111111111111111111111111111111111111111111"

	[ ! -f "$CURL_MARKER" ]
	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	printf '%s\n' "$out" | grep -qi 're-fetching'
	[ -f "$CURL_MARKER" ]
	# It still refused to install an unverifiable download.
	[ "$rc" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Happy paths: the pinned sum passes, and an already-correct binary is trusted
# without re-downloading.
# ---------------------------------------------------------------------------

@test "sha256 gate: a download matching the pinned sum installs cleanly" {
	fake_curl                       # default: a runnable exit-0 stub
	fake_shasum "$KAS_CONTAINER_SHA256"

	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ -x "$KAS_CONTAINER_BIN" ]
	printf '%s\n' "$out" | grep -qi 'installed'
}

@test "sha256 gate: an already-correct binary is trusted without re-fetching" {
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"

	fake_curl                       # would touch CURL_MARKER if ever called
	fake_shasum "$KAS_CONTAINER_SHA256"

	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	printf '%s\n' "$out" | grep -qi 'verified'
	# The early-return path: no download happened.
	[ ! -f "$CURL_MARKER" ]
}

# ---------------------------------------------------------------------------
# ensure_kas_container_installed -- smoketest/shell's own offer to install
# kas-container (via this exact setup_kas_container gate) instead of just
# refusing, when it is missing.
# ---------------------------------------------------------------------------

@test "ensure_kas_container_installed: already installed is a silent no-op, no prompt" {
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	fake_curl                       # would touch CURL_MARKER if ever called
	ASSUME_YES=0

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ ! -f "$CURL_MARKER" ]
	[ -z "$out" ]
}

@test "ensure_kas_container_installed: accepting the offer installs it via the real sha256 gate" {
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"
	ASSUME_YES=1

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ -x "$KAS_CONTAINER_BIN" ]
	printf '%s\n' "$out" | grep -qi 'installed'
}

@test "ensure_kas_container_installed: declining refuses with the same message as before" {
	fake_curl                       # would touch CURL_MARKER if ever called
	ASSUME_YES=0

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'kas-container not installed'
	[ ! -f "$CURL_MARKER" ]
}
