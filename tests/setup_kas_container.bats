#!/usr/bin/env bats
#
# Tests for setup_kas_container's sha256 gate and the write_kas_wrapper()
# protection wrapper it now always regenerates alongside it.
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
# The pinned, downloaded upstream script now lands at KAS_CONTAINER_REAL, not
# KAS_CONTAINER_BIN -- KAS_CONTAINER_BIN is the generated protection wrapper
# that $PATH actually resolves 'kas-container' to. The sha256-gate tests below
# were retargeted to KAS_CONTAINER_REAL for exactly that reason; their intent
# (verify the pin/download/mismatch logic) is unchanged.
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
	[ ! -e "$KAS_CONTAINER_REAL" ]
	# die() exits before write_kas_wrapper() is ever reached, so the wrapper
	# must not exist either -- a wrapper with no verified .real behind it
	# would be worse than nothing.
	[ ! -e "$KAS_CONTAINER_BIN" ]
}

@test "sha256 gate: the attacker bytes are never left installed" {
	# The complement of the above, stated as the security property: whatever the
	# download contained, a failed verify leaves nothing executable behind.
	fake_curl "$(printf '#!/bin/sh\ntouch %s/EXPLOIT_RAN\n' "$TESTDIR")"
	fake_shasum "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	[ ! -e "$KAS_CONTAINER_REAL" ]
	[ ! -e "$KAS_CONTAINER_BIN" ]
	# And it was never executed either (the gate runs BEFORE --version).
	[ ! -e "$TESTDIR/EXPLOIT_RAN" ]
}

# ---------------------------------------------------------------------------
# A pre-seeded binary whose (faked) sum is wrong forces a re-fetch.
# ---------------------------------------------------------------------------

@test "sha256 gate: an existing binary with the wrong sum triggers a re-fetch" {
	mkdir -p "$MACKAS_BIN"
	printf 'stale-kas-container\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"

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
	[ ! -e "$KAS_CONTAINER_BIN" ]
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
	[ -x "$KAS_CONTAINER_REAL" ]
	printf '%s\n' "$out" | grep -qi 'installed'
}

@test "sha256 gate: an already-correct binary is trusted without re-fetching" {
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"

	fake_curl                       # would touch CURL_MARKER if ever called
	fake_shasum "$KAS_CONTAINER_SHA256"

	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	printf '%s\n' "$out" | grep -qi 'verified'
	# The early-return path: no download happened.
	[ ! -f "$CURL_MARKER" ]
}

# ---------------------------------------------------------------------------
# The generated protection wrapper: KAS_CONTAINER_BIN, distinct from .real,
# written on every path through setup_kas_container -- including the skip
# path above, which is exactly why that last test still needs a wrapper
# assertion of its own here.
# ---------------------------------------------------------------------------

@test "wrapper: KAS_CONTAINER_BIN is executable and NOT byte-identical to .real" {
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"

	(setup_kas_container)
	[ -x "$KAS_CONTAINER_REAL" ]
	[ -x "$KAS_CONTAINER_BIN" ]
	# The wrapper is generated shell, not a copy of the fetched binary -- a
	# regression that made write_kas_wrapper() write a copy of .real instead
	# of the generated script would defeat the whole mechanism silently.
	! cmp -s "$KAS_CONTAINER_BIN" "$KAS_CONTAINER_REAL"
}

@test "wrapper: the skip path (already-verified .real) still (re)writes the wrapper" {
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"

	[ ! -e "$KAS_CONTAINER_BIN" ]
	(setup_kas_container)
	[ -x "$KAS_CONTAINER_BIN" ]
	[ ! -f "$CURL_MARKER" ]
}

# ---------------------------------------------------------------------------
# Migration: an older mackas left the raw upstream script sitting directly at
# the old path (KAS_CONTAINER_BIN, before it became the wrapper's path). A
# verified match there must be moved aside to .real with no re-download --
# curl running at all here would mean a perfectly good, already-verified
# script got thrown away and re-fetched for no reason.
# ---------------------------------------------------------------------------

@test "migration: a verified binary at the old path is moved to .real, not re-fetched" {
	mkdir -p "$MACKAS_BIN"
	printf 'this-is-the-real-upstream-script\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	fake_curl                       # would touch CURL_MARKER if ever called
	fake_shasum "$KAS_CONTAINER_SHA256"

	[ ! -e "$KAS_CONTAINER_REAL" ]
	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ ! -f "$CURL_MARKER" ]
	# The moved file, not a re-download, sits at .real with its exact content.
	[ -f "$KAS_CONTAINER_REAL" ]
	grep -q 'this-is-the-real-upstream-script' "$KAS_CONTAINER_REAL"
	# The wrapper -- a DIFFERENT file -- was written in the same run.
	[ -x "$KAS_CONTAINER_BIN" ]
	! cmp -s "$KAS_CONTAINER_BIN" "$KAS_CONTAINER_REAL"
	printf '%s\n' "$out" | grep -qi 'moved'
}

# ---------------------------------------------------------------------------
# Idempotency: running setup twice must not leave a stale wrapper behind on
# the second (skip) run -- only re-verifying .real without regenerating the
# wrapper was the actual bug this whole mechanism exists to close.
# ---------------------------------------------------------------------------

@test "idempotency: a second run skips the download and still regenerates the wrapper" {
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"

	(setup_kas_container)
	[ -x "$KAS_CONTAINER_BIN" ]
	first_image="$(grep '^KAS_IMAGE=' "$KAS_CONTAINER_BIN")"

	# Change something the wrapper bakes in, so a regenerated wrapper is
	# provably different from the first one rather than merely "still
	# present" (which a stale copy would also be). The volume names are NOT
	# such a thing any more -- the wrapper asks mackas for them live on every
	# call and refuses if that fails (issue #96), so nothing about them is in
	# this file to compare.
	KAS_IMAGE="ghcr.io/siemens/kas/kas:9.9.9"

	rm -f "$CURL_MARKER"
	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	printf '%s\n' "$out" | grep -qi 'verified'
	[ ! -f "$CURL_MARKER" ]                     # the download was skipped
	[ -x "$KAS_CONTAINER_BIN" ]                  # but the wrapper is still there
	second_image="$(grep '^KAS_IMAGE=' "$KAS_CONTAINER_BIN")"
	[ "$first_image" != "$second_image" ]        # ...and was actually rewritten
}

# ---------------------------------------------------------------------------
# --dry-run must write neither file.
# ---------------------------------------------------------------------------

@test "--dry-run writes neither .real nor the wrapper" {
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"
	DRY_RUN=1

	out="$( (setup_kas_container) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ ! -e "$KAS_CONTAINER_REAL" ]
	[ ! -e "$KAS_CONTAINER_BIN" ]
	printf '%s\n' "$out" | grep -qi -- '+ write'
}

# ---------------------------------------------------------------------------
# ensure_kas_container_installed -- smoketest/shell's own offer to install
# kas-container (via this exact setup_kas_container gate) instead of just
# refusing, when it is missing.
# ---------------------------------------------------------------------------

@test "ensure_kas_container_installed: already installed is a silent no-op, no prompt" {
	mkdir -p "$MACKAS_BIN"
	# Both files must be seeded -- ensure_kas_container_installed now requires
	# .real AND the wrapper, not the wrapper alone (see the split it guards
	# against, below).
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	fake_curl                       # would touch CURL_MARKER if ever called
	ASSUME_YES=0

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ ! -f "$CURL_MARKER" ]
	[ -z "$out" ]
}

@test "ensure_kas_container_installed: .real present but wrapper missing is treated as incomplete" {
	# Half-state: a verified .real with no wrapper in front of it means
	# \$PATH-resolved 'kas-container' invocations would reach nothing (the
	# wrapper) -- exactly the unprotected-invocation bug this task closes.
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"
	[ ! -e "$KAS_CONTAINER_BIN" ]
	fake_curl                       # would touch CURL_MARKER if ever called
	fake_shasum "$KAS_CONTAINER_SHA256"
	ASSUME_YES=1

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	# Not silent: it had to go through the confirm+install path, not the
	# short-circuit no-op.
	[ -n "$out" ]
	[ -x "$KAS_CONTAINER_REAL" ]
	[ -x "$KAS_CONTAINER_BIN" ]
}

@test "ensure_kas_container_installed: wrapper present but .real missing is treated as incomplete" {
	# The complementary half-state: a wrapper with no .real behind it would
	# fail at exec time when it tries to run a nonexistent file.
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	[ ! -e "$KAS_CONTAINER_REAL" ]
	fake_curl
	fake_shasum "$KAS_CONTAINER_SHA256"
	ASSUME_YES=1

	out="$( (ensure_kas_container_installed) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	[ -n "$out" ]
	[ -x "$KAS_CONTAINER_REAL" ]
	[ -x "$KAS_CONTAINER_BIN" ]
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

# ---------------------------------------------------------------------------
# check_state's kas-container rung -- diagnostic only, task 6 of the item-27
# plan. Drives check_state() directly (MACKAS_LIB_ONLY=1, same as the rest of
# this file), staging KAS_CONTAINER_REAL/KAS_CONTAINER_BIN by hand and reusing
# fake_shasum() for the exact same pin comparison setup_kas_container() itself
# uses. Spotlight is stubbed out (find_orphaned_volume_images) so these never
# touch the real index -- it is unrelated to what is under test here and would
# make the run environment-dependent.
# ---------------------------------------------------------------------------

# A stand-in .real that answers --version without needing the actual upstream
# script -- check_state must query THIS file, never the wrapper (see the
# comment above the rung it drives: doing it against the wrapper would shell
# out to `runtime-args` for a version check, which is pointless and wrong).
fake_kas_container_real() {
	mkdir -p "$MACKAS_BIN"
	printf '#!/bin/bash\necho "kas-container 1.2.3"\n' > "$KAS_CONTAINER_REAL"
	chmod +x "$KAS_CONTAINER_REAL"
}

# An empty Spotlight index -- find_orphaned_volume_images must never reach the
# real one from a test.
stub_mdfind() {
	mkdir -p "$TESTDIR/fakebin"
	printf '#!/usr/bin/env bash\ntrue\n' > "$TESTDIR/fakebin/mdfind"
	chmod +x "$TESTDIR/fakebin/mdfind"
	MACKAS_MDFIND="$TESTDIR/fakebin/mdfind"
	export MACKAS_MDFIND
}

@test "check_state: both files present, wrapper sha != pin -> PASS, version read from .real" {
	stub_mdfind
	fake_kas_container_real
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	# Any sum other than the pinned one reads as "an actual wrapper, not a
	# raw copy of upstream".
	fake_shasum "0000000000000000000000000000000000000000000000000000000000000000"

	out="$(check_state 2>&1)"
	printf '%s\n' "$out" | grep -qF '[PASS]'
	printf '%s\n' "$out" | grep -qF 'kas-container present: kas-container 1.2.3'
}

@test "check_state: .real present, wrapper missing -> FAIL naming the bypass risk" {
	stub_mdfind
	fake_kas_container_real
	[ ! -e "$KAS_CONTAINER_BIN" ]

	out="$(check_state 2>&1)"
	printf '%s\n' "$out" | grep -qF '[FAIL]'
	printf '%s\n' "$out" | grep -qF "protection wrapper at $KAS_CONTAINER_BIN is missing"
	printf '%s\n' "$out" | grep -qi 'unprotected'
	printf '%s\n' "$out" | grep -qF "$SCRIPT_CMD setup"
}

@test "check_state: wrapper overwritten with raw upstream (sha == pin) -> FAIL naming it 'overwritten', distinct wording from the missing-wrapper case" {
	stub_mdfind
	fake_kas_container_real
	printf '#!/bin/bash\nexit 0\n' > "$KAS_CONTAINER_BIN"
	chmod +x "$KAS_CONTAINER_BIN"
	fake_shasum "$KAS_CONTAINER_SHA256"

	out="$(check_state 2>&1)"
	printf '%s\n' "$out" | grep -qF '[FAIL]'
	printf '%s\n' "$out" | grep -qF 'overwritten with the raw upstream kas-container script'
	# Distinct from the missing-wrapper case's wording -- a diagnostic that
	# names the wrong problem is a silent failure of the whole point of it.
	! printf '%s\n' "$out" | grep -qF 'is missing (or not executable)'
}

@test "check_state: neither file present -> unchanged info message (regression)" {
	stub_mdfind
	[ ! -e "$KAS_CONTAINER_REAL" ]
	[ ! -e "$KAS_CONTAINER_BIN" ]

	out="$(check_state 2>&1)"
	printf '%s\n' "$out" | grep -qF '[info]'
	printf '%s\n' "$out" | grep -qF "kas-container not installed yet -> $KAS_CONTAINER_BIN"
}

# ---------------------------------------------------------------------------
# check_state's stray-bypass-wreckage rung: a bare $MACKAS_WORK/build existing
# at all is proof an unprotected build ran at some point, even with the
# wrapper/.real split installed correctly right now. Strictly report-only --
# 'check' must never delete it (see check_usage()'s "changes nothing"
# contract).
# ---------------------------------------------------------------------------

@test "check_state: a stray \$MACKAS_WORK/build WARNs, names the exact rm -rf, and deletes nothing" {
	stub_mdfind
	mkdir -p "$MACKAS_WORK/build"

	out="$(check_state 2>&1)"
	printf '%s\n' "$out" | grep -qF '[WARN]'
	printf '%s\n' "$out" | grep -qF "$MACKAS_WORK/build exists"
	printf '%s\n' "$out" | grep -qi 'issue #27'
	printf '%s\n' "$out" | grep -qF "rm -rf $(printf '%q' "$MACKAS_WORK/build")"
	# Report-only: the directory is still there after check_state runs.
	[ -d "$MACKAS_WORK/build" ]
}

@test "check_state: no \$MACKAS_WORK/build means no stray-bypass warning" {
	stub_mdfind
	[ ! -d "$MACKAS_WORK/build" ]

	out="$(check_state 2>&1)"
	! printf '%s\n' "$out" | grep -qF "$MACKAS_WORK/build exists"
}

# ---------------------------------------------------------------------------
# cmd_status()'s "Present?" section: KAS_CONTAINER_REAL must appear alongside
# KAS_CONTAINER_BIN so a user can see both halves of the split at a glance.
# ---------------------------------------------------------------------------

@test "cmd_status: Present? lists KAS_CONTAINER_REAL right after KAS_CONTAINER_BIN" {
	stub_mdfind
	out="$(cmd_status 2>&1)"
	# KAS_CONTAINER_REAL is KAS_CONTAINER_BIN + ".real", so a plain -F match on
	# KAS_CONTAINER_BIN also matches the REAL line -- `head -1` still picks the
	# right one because the loop lists BIN before REAL.
	local bin_line real_line
	bin_line="$(printf '%s\n' "$out" | grep -nF "$KAS_CONTAINER_BIN" | head -1 | cut -d: -f1)"
	real_line="$(printf '%s\n' "$out" | grep -nF "$KAS_CONTAINER_REAL" | head -1 | cut -d: -f1)"
	[ -n "$bin_line" ]
	[ -n "$real_line" ]
	# Order matters per the task: REAL immediately follows BIN in the list.
	[ "$real_line" -eq $((bin_line + 1)) ]
}
