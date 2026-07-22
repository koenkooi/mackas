#!/usr/bin/env bats
#
# Tests for `mackas buildstats analyze` -- summarising a buildstats directory
# already on disk (see retrieve.bats for how it gets there).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The JSON/text summary half of `buildstats analyze` never touches the Apple
# container runtime -- it is a pure local read of files already on disk plus a
# `python3` invocation -- so most tests here drive `mackas buildstats analyze`
# directly, with no `container` mock. The bootchart-SVG half DOES run inside a
# throwaway container (pybootchartgui needs pycairo, which this Mac's own
# Python does not have); the tests for that below add a fake `container` on
# PATH, same convention as retrieve.bats. Nothing here touches the real Apple
# container runtime, a volume, or the build SSD.

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

# A second, minimal BUILDNAME dir under the same parent -- just enough for
# list_buildstats_dirs to recognize it (a real build_stats file), for the
# multi-build SVG tests below. Older than buildstats_fixture's own BUILDNAME
# by name (BUILDNAME sorts lexically).
extra_buildstats_dir() {
	local dir="$1" name="$2"
	mkdir -p "$dir/$name"
	cat > "$dir/$name/build_stats" <<'EOF'
Host Info: Linux
Build Started: 500.00
Elapsed time: 10.00 seconds
CPU usage: 40.0%
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

assert_call() {
	if ! grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected a `container` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
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

@test "buildstats analyze: finds a build_stats nested under retrieve's own timestamp dir" {
	# The shape `mackas retrieve buildstats` produces now (fetch_tmp_subdir's
	# EXTRA param): buildstats/<retrieve-timestamp>/<BUILDNAME>/build_stats,
	# one level deeper than the old flat buildstats/<BUILDNAME>/. Resolution
	# must be recursive, not hardcode one fixed level.
	buildstats_fixture "$ROOT/artifacts/buildstats/20260722000000"
	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '150.1'
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
# Bootchart SVG -- runs pybootchartgui inside a throwaway container
# ---------------------------------------------------------------------------

# A fake `container` that models `run --rm -v PBC:/pbc:ro -v BSDIR:/in:ro
# -v OUTDIR:/out IMAGE python3 /pbc/pybootchartgui.py -f svg -M -T -o
# /out/NAME.svg /in`: it logs every call to CLOG, and -- unless MOCK_SVG_FAIL
# is set -- writes a fake SVG at the requested host -o path, the same way the
# real pybootchartgui would, so the test can assert the file actually lands.
svg_container_mock() {
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"

[ "$1" = "run" ] || exit 0
[ -z "${MOCK_SVG_FAIL:-}" ] || exit 1

outdir="" oflag=""
prev=""
for a in "$@"; do
	case "$prev" in
		-v) case "$a" in *:/out) outdir="${a%:/out}" ;; esac ;;
		-o) oflag="$a" ;;
	esac
	prev="$a"
done
# Real pybootchartgui's _get_filename does `os.path.isdir(-o's value)` FIRST:
# if "$outdir/$name" already exists as a directory, it writes
# "$name/bootchart.svg" instead of "$name.svg" -- the exact live-reported bug
# (mackas used to mount bsdir's own parent straight as /out, so /out/$name WAS
# bsdir, an existing dir). Modelling that branch here means a regression back
# to that mount shape is caught by the "file lands at the top level" assert
# below, not just by code review.
if [ -n "$outdir" ] && [ -n "$oflag" ]; then
	name="${oflag##*/out/}"
	if [ -d "$outdir/$name" ]; then
		mkdir -p "$outdir/$name"
		echo '<svg/>' > "$outdir/$name/bootchart.svg"
	else
		mkdir -p "$outdir"
		echo '<svg/>' > "$outdir/$name.svg"
	fi
fi
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

@test "buildstats analyze: no checkout under MACKAS_WORK -- SVG step skips, not fatal" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'no checkout under'
	printf '%s\n' "$output" | grep -qi 'skipping the SVG chart'
}

@test "buildstats analyze: pybootchartgui.py missing under MACKAS_WORK -- SVG step skips, not fatal" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	mkdir -p "$ROOT/work/some-other-layer"
	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'pybootchartgui.py not found'
}

@test "buildstats analyze: renders a bootchart SVG via a throwaway kas-image container" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	mkdir -p "$ROOT/work/openembedded-core/scripts/pybootchartgui"
	touch "$ROOT/work/openembedded-core/scripts/pybootchartgui/pybootchartgui.py"

	CLOG="$TESTDIR/container.log"
	export CLOG
	svg_container_mock

	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'chart:'

	assert_call ':/pbc:ro'
	assert_call ':/in:ro'
	assert_call ':/out'
	assert_call '[python3] [/pbc/pybootchartgui.py]'
	assert_call '[-f] [svg]'
	# The bare BUILDNAME, no ".svg" -- pybootchartgui appends that itself, so
	# passing it here would double up into "...svg.svg" (a real bug this once
	# shipped with).
	assert_call '[-o] [/out/20260717121723]'

	[ -f "$ROOT/artifacts/buildstats/20260717121723.svg" ]
}

@test "buildstats analyze: charts EVERY build under PATH, not just the newest" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	extra_buildstats_dir "$ROOT/artifacts/buildstats" "20260601000000"
	mkdir -p "$ROOT/work/openembedded-core/scripts/pybootchartgui"
	touch "$ROOT/work/openembedded-core/scripts/pybootchartgui/pybootchartgui.py"

	CLOG="$TESTDIR/container.log"
	export CLOG
	svg_container_mock

	mk buildstats analyze
	[ "$status" -eq 0 ]

	assert_call '[-o] [/out/20260601000000]'
	assert_call '[-o] [/out/20260717121723]'
	[ -f "$ROOT/artifacts/buildstats/20260601000000.svg" ]
	[ -f "$ROOT/artifacts/buildstats/20260717121723.svg" ]
}

@test "buildstats analyze: a build already charted is skipped, not re-rendered" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	extra_buildstats_dir "$ROOT/artifacts/buildstats" "20260601000000"
	mkdir -p "$ROOT/work/openembedded-core/scripts/pybootchartgui"
	touch "$ROOT/work/openembedded-core/scripts/pybootchartgui/pybootchartgui.py"

	# 20260601000000 already has a chart -- a sentinel content proves it was
	# left alone, not regenerated by the mock (which would overwrite it with
	# '<svg/>').
	echo '<svg>already here</svg>' > "$ROOT/artifacts/buildstats/20260601000000.svg"

	CLOG="$TESTDIR/container.log"
	export CLOG
	svg_container_mock

	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi '20260601000000.svg already exists'

	! grep -qF -- '[-o] [/out/20260601000000]' "$CLOG"
	assert_call '[-o] [/out/20260717121723]'
	grep -qF 'already here' "$ROOT/artifacts/buildstats/20260601000000.svg"
	[ -f "$ROOT/artifacts/buildstats/20260717121723.svg" ]
}

@test "buildstats analyze: a failed pybootchartgui run warns (non-fatal), analyze's own exit code stands" {
	buildstats_fixture "$ROOT/artifacts/buildstats"
	mkdir -p "$ROOT/work/openembedded-core/scripts/pybootchartgui"
	touch "$ROOT/work/openembedded-core/scripts/pybootchartgui/pybootchartgui.py"

	CLOG="$TESTDIR/container.log"
	export CLOG
	MOCK_SVG_FAIL=1
	export MOCK_SVG_FAIL
	svg_container_mock

	mk buildstats analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'pybootchartgui failed'
	[ ! -f "$ROOT/artifacts/buildstats/20260717121723.svg" ]
}

@test "buildstats analyze: an explicit relative PATH is absolutised before it reaches the container mount" {
	buildstats_fixture "$TESTDIR/elsewhere/buildstats"
	mkdir -p "$ROOT/work/openembedded-core/scripts/pybootchartgui"
	touch "$ROOT/work/openembedded-core/scripts/pybootchartgui/pybootchartgui.py"

	CLOG="$TESTDIR/container.log"
	export CLOG
	svg_container_mock

	cd "$TESTDIR"
	mk buildstats analyze "elsewhere/buildstats"
	[ "$status" -eq 0 ]
	# A relative "elsewhere/buildstats" must become an absolute -v source --
	# Apple container reads a relative host path as a NAMED VOLUME instead.
	assert_call "$TESTDIR/elsewhere/buildstats/20260717121723:/in:ro"
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
