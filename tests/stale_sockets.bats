#!/usr/bin/env bats
#
# Tests for clear_stale_sockets() -- the host-side sweep that removes any
# bitbake.sock/hashserve.sock stranded on the host-visible checkout/work tree
# (virtiofs) instead of inside an ext4 volume.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Once such a socket exists it is stuck FOREVER from the guest's side (bind()
# succeeds once, but every later stat/unlink on it fails ENOTSUP), but it is
# an ordinary special file from macOS's own side -- these tests drive the
# function directly (MACKAS_LIB_ONLY=1, function-level, no `mackas` subcommand)
# with `volume_in_use` shadowed as a plain shell function, the same idiom
# tests/volume_mgmt.bats already uses for its cross-filesystem move test.

bats_require_minimum_version 1.5.0

load helpers

# A real AF_UNIX socket special file at $1 (not a regular file that merely
# happens to be named right -- proves -type s is doing real work).
make_socket() {
	/usr/bin/python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
' "$1"
}

setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	setup_colors

	# NOT make_tmpdir(): a real AF_UNIX bind() caps the path at 104 bytes
	# (sizeof sun_path) on macOS, and bats' own nesting
	# (bats-run-.../test/N/mackas-test.XXXXXX) already eats most of that
	# budget before this test ever appends /work/build/bitbake.sock. A
	# short path straight under /tmp leaves enough room.
	TESTDIR="$(mktemp -d /tmp/mkss.XXXXXX)"

	# Hand-built paths, same shape as a real derive_paths() result, but not
	# going through it -- nothing here needs MACKAS_ROOT/MACKAS_SHORT_LINK.
	MACKAS_WORK="$TESTDIR/work"
	MACKAS_PROJECT="$TESTDIR/work/checkout"
	mkdir -p "$MACKAS_WORK/build" "$MACKAS_PROJECT"

	MACKAS_VOL_TMP="oe-build-tmp"
	MACKAS_VOL_DL="oe-build-dl"
	MACKAS_VOL_SSTATE="oe-build-sstate"

	MACKAS_SOCKET_SWEEP=1

	# Default: nothing holds any volume. Individual tests override this.
	volume_in_use() { return 1; }
}

teardown() {
	rm -rf "$TESTDIR"
}

@test "clear_stale_sockets: a real socket at MACKAS_WORK/build/bitbake.sock is removed" {
	make_socket "$MACKAS_WORK/build/bitbake.sock"
	out="$(clear_stale_sockets 2>&1)"
	[ ! -e "$MACKAS_WORK/build/bitbake.sock" ]
	printf '%s\n' "$out" | grep -qi 'stale socket'
}

@test "clear_stale_sockets: a regular file of the same name/path is left alone" {
	: > "$MACKAS_WORK/build/bitbake.sock"
	clear_stale_sockets
	[ -f "$MACKAS_WORK/build/bitbake.sock" ]
	[ ! -L "$MACKAS_WORK/build/bitbake.sock" ]
}

@test "clear_stale_sockets: a socket in a sibling dir (not under build/) is left alone" {
	mkdir -p "$MACKAS_WORK/somethingelse"
	make_socket "$MACKAS_WORK/somethingelse/bitbake.sock"
	clear_stale_sockets
	[ -e "$MACKAS_WORK/somethingelse/bitbake.sock" ]
}

@test "clear_stale_sockets: a socket nested beyond -maxdepth 2 is left alone" {
	mkdir -p "$MACKAS_WORK/build/a/b/c"
	make_socket "$MACKAS_WORK/build/a/b/c/bitbake.sock"
	clear_stale_sockets
	[ -e "$MACKAS_WORK/build/a/b/c/bitbake.sock" ]
}

@test "clear_stale_sockets: a socket at MACKAS_PROJECT/bitbake.sock is removed" {
	make_socket "$MACKAS_PROJECT/bitbake.sock"
	out="$(clear_stale_sockets 2>&1)"
	[ ! -e "$MACKAS_PROJECT/bitbake.sock" ]
	printf '%s\n' "$out" | grep -qi 'stale socket'
}

@test "clear_stale_sockets: hashserve.sock is swept at both locations too" {
	make_socket "$MACKAS_WORK/build/hashserve.sock"
	make_socket "$MACKAS_PROJECT/hashserve.sock"
	clear_stale_sockets
	[ ! -e "$MACKAS_WORK/build/hashserve.sock" ]
	[ ! -e "$MACKAS_PROJECT/hashserve.sock" ]
}

@test "clear_stale_sockets: any ONE volume reported in-use stops the sweep entirely" {
	make_socket "$MACKAS_WORK/build/bitbake.sock"
	make_socket "$MACKAS_PROJECT/bitbake.sock"
	# Only MACKAS_VOL_DL reports in-use; the other two would say "free" --
	# still enough to refuse the whole sweep.
	volume_in_use() { [ "$1" = "$MACKAS_VOL_DL" ]; }
	clear_stale_sockets
	[ -e "$MACKAS_WORK/build/bitbake.sock" ]
	[ -e "$MACKAS_PROJECT/bitbake.sock" ]
}

@test "clear_stale_sockets: MACKAS_SOCKET_SWEEP=0 removes and prints nothing" {
	make_socket "$MACKAS_WORK/build/bitbake.sock"
	MACKAS_SOCKET_SWEEP=0
	out="$(clear_stale_sockets 2>&1)"
	[ -e "$MACKAS_WORK/build/bitbake.sock" ]
	[ -z "$out" ]
}

@test "clear_stale_sockets: a file rm cannot remove still returns 0 and warns (mutation-tested)" {
	make_socket "$MACKAS_WORK/build/bitbake.sock"
	chmod 555 "$MACKAS_WORK/build"
	# Deliberately NOT `out="$(clear_stale_sockets)" || status=$?`: wrapping
	# the call as the left side of `||` (even indirectly, through a command
	# substitution assigned in that position) suspends `set -e` for the
	# whole subshell running it, in bash -- which would make this call
	# silently survive an UNGUARDED failure too, defeating the very thing
	# this test exists to catch. A bare statement is what actually lets a
	# missing `|| true` abort this test (see the mutation note below).
	clear_stale_sockets >"$TESTDIR/sweep.out" 2>&1
	status=$?
	chmod 755 "$MACKAS_WORK/build"   # restore so teardown's rm -rf can clean up
	[ "$status" -eq 0 ]
	grep -qi 'stale socket' "$TESTDIR/sweep.out"
	# It really did fail to remove -- otherwise this test would not be
	# exercising the `|| true` guard at all.
	[ -e "$MACKAS_WORK/build/bitbake.sock" ]
}

# ---------------------------------------------------------------------------
# run_kas() wiring -- source-grep, since exercising a real kas invocation is
# out of scope here (see tests/volumes.bats for that machinery).
# ---------------------------------------------------------------------------

@test "run_kas: calls clear_stale_sockets between auto_fstrim(before) and clear_buildstats_before_build (source-grep)" {
	local body ln_fstrim ln_sweep ln_buildstats
	body="$(awk '/^run_kas\(\)/{f=1} f{print} f&&/^}/{exit}' "$MACKAS")"

	# Each anchor's line number WITHIN the function body -- the literal call
	# forms (with their "$log" argument) are pinned so a comment merely
	# mentioning a function's name by prose can't be mistaken for its call.
	ln_fstrim="$(printf '%s\n' "$body" | grep -nF 'auto_fstrim before "$log"' | head -1 | cut -d: -f1)"
	ln_sweep="$(printf '%s\n' "$body" | grep -nF 'clear_stale_sockets "$log"' | head -1 | cut -d: -f1)"
	ln_buildstats="$(printf '%s\n' "$body" | grep -nF 'clear_buildstats_before_build "$log"' | head -1 | cut -d: -f1)"

	[ -n "$ln_fstrim" ]
	[ -n "$ln_sweep" ]
	[ -n "$ln_buildstats" ]
	[ "$ln_fstrim" -lt "$ln_sweep" ]
	[ "$ln_sweep" -lt "$ln_buildstats" ]
}

