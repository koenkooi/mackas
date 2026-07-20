#!/usr/bin/env bats
#
# Tests for `mackas buildstats analyze` -- summarising a buildstats directory
# already on disk (see retrieve.bats for how it gets there).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `buildstats analyze` never touches the Apple container runtime -- it is a
# pure local read of files already on disk plus a `python3` invocation -- so
# these drive `mackas buildstats analyze` directly, with no `container` mock.
# Nothing here touches the real Apple container runtime, a volume, or the
# build SSD.

bats_require_minimum_version 1.5.0

load helpers

# A buildstats dir with one task that has tiny own-rusage and large
# CHILD-rusage: the whole point of the analyzer is that child rusage is
# counted, or every compile looks free.
buildstats_fixture() {
	local dir="$1"
	mkdir -p "$dir/20260717121723/busybox"
	cat > "$dir/20260717121723/build_stats" <<'EOF'
Host Info: Linux
Build Started: 1000.00
Elapsed time: 42.00 seconds
CPU usage: 55.5%
EOF
	cat > "$dir/20260717121723/busybox/do_compile" <<'EOF'
Event: TaskStarted
Started: 1000.00
rusage ru_utime: 0.05
rusage ru_stime: 0.05
Child rusage ru_utime: 120.00
Child rusage ru_stime: 30.00
IO read_bytes: 1048576
IO write_bytes: 2097152
Ended: 1030.00
Status: PASSED
EOF
}

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKE_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin"
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

mk() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

# ---------------------------------------------------------------------------
# Default PATH: $MACKAS_BASE/artifacts/buildstats
# ---------------------------------------------------------------------------

@test "buildstats analyze: with no PATH, resolves the default retrieve destination" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'buildstats:'
	printf '%s\n' "$output" | grep -q 'task CPU'
	# 0.05+0.05+120+30 = 150.1 CPU-s -- proves child rusage was counted.
	printf '%s\n' "$output" | grep -qF '150.1'
}

@test "buildstats analyze: an empty default dir fails, not silently succeeds" {
	mk buildstats analyze
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Explicit PATH
# ---------------------------------------------------------------------------

@test "buildstats analyze: an explicit PATH overrides the default" {
	buildstats_fixture "$TESTDIR/elsewhere/buildstats"
	mk buildstats analyze "$TESTDIR/elsewhere/buildstats"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '150.1'
}

@test "buildstats analyze: at most one PATH is accepted" {
	buildstats_fixture "$TESTDIR/elsewhere/buildstats"
	mk buildstats analyze "$TESTDIR/elsewhere/buildstats" "$TESTDIR/extra"
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Analyzer missing -- non-fatal warning, not a crash
# ---------------------------------------------------------------------------

@test "buildstats analyze: warns (non-fatal) when the analyzer script is missing" {
	# SCRIPT_DIR is derived from $0, so run a COPY of mackas from a directory
	# with no sibling tools/ -- this proves the missing-analyzer path without
	# touching the real repo's tools/mackas-buildstats-analyze.
	buildstats_fixture "$ROOT/artifacts/buildstats"
	local nodir="$TESTDIR/no-tools"
	mkdir -p "$nodir"
	cp "$MACKAS" "$nodir/mackas"
	chmod +x "$nodir/mackas"
	run "$nodir/mackas" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 buildstats analyze
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'analyzer not found'
}

# ---------------------------------------------------------------------------
# buildstats with no subcommand shows help, not an error
# ---------------------------------------------------------------------------

@test "buildstats: with no subcommand shows buildstats usage" {
	mk buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'analyze'
}

@test "buildstats --help shows usage" {
	mk buildstats --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'analyze'
}

@test "buildstats: an unknown subcommand is refused" {
	mk buildstats bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "unknown 'buildstats' subcommand"
}
