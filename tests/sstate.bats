#!/usr/bin/env bats
#
# Tests for `mackas sstate prune` -- deleting sstate objects bitbake hasn't
# reused in a while, inside a throwaway container mounting the sstate volume.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas sstate prune` as a subprocess with a fake `container` on
# PATH. The fake does not run a real `find` against real mtimes -- it returns
# a SCRIPTED report (MOCK_SSTATE_SIZES, one byte-size per object) for the scan
# call, and just records the delete call, the same controlled-response style
# volumes_cmd.bats/retrieve.bats already use elsewhere in this suite. Nothing
# here touches the real Apple container runtime, a volume, or the build SSD.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin"

	CLOG="$TESTDIR/container.log"
	export CLOG

	# MOCK_SSTATE_SIZES: space-separated byte sizes, one per "object older
	# than N days" the scan should report. Empty/unset -> nothing to prune.
	MOCK_SSTATE_SIZES=""
	export MOCK_SSTATE_SIZES

	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"

case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") echo "NAME"; exit 0 ;;
	"container ls"|"ls ")
		echo "ID  IMAGE  STATE"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "buildbox  kas  running"
		exit 0
		;;
	"container inspect"|"inspect "*|"inspect")
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		exit 0
		;;
esac

# Fall through: a `container run ...`. The last arg(s) are the find command.
last="${@: -1}"
case "$*" in
	*"-printf"*)
		for sz in ${MOCK_SSTATE_SIZES:-}; do printf '%s\n' "$sz"; done
		exit 0
		;;
	*"-delete"*)
		exit 0
		;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
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

refute_call() {
	if grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected NO `container` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# --older-than parsing
# ---------------------------------------------------------------------------

@test "sstate prune: --older-than is required" {
	mk -y sstate prune
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs --older-than'
}

@test "sstate prune: --older-than must be a whole number of days" {
	mk -y sstate prune --older-than banana
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'whole number of days'
}

@test "sstate prune: --older-than accepts the N=... form too" {
	MOCK_SSTATE_SIZES="1024" mk -y sstate prune --older-than=30d
	[ "$status" -eq 0 ]
	assert_call "find] [/sstate] [-type] [f] [-mtime] [+30] [-delete]"
}

@test "sstate prune: the scan uses the right -mtime threshold" {
	mk -y sstate prune --older-than 90d
	assert_call "find] [/sstate] [-type] [f] [-mtime] [+90] [-printf]"
}

# ---------------------------------------------------------------------------
# Nothing to prune
# ---------------------------------------------------------------------------

@test "sstate prune: nothing to prune is a clean, non-mutating no-op" {
	mk -y sstate prune --older-than 90d
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to prune'
	refute_call "-delete"
}

# ---------------------------------------------------------------------------
# The prune itself
# ---------------------------------------------------------------------------

@test "sstate prune: reports the count and reclaimable size before deleting" {
	MOCK_SSTATE_SIZES="1048576 2097152" mk -y sstate prune --older-than 90d
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "found      : 2 object(s)"
	printf '%s\n' "$output" | grep -qi '3.0M'
}

@test "sstate prune: actually issues the delete after confirmation" {
	MOCK_SSTATE_SIZES="1048576" mk -y sstate prune --older-than 90d
	[ "$status" -eq 0 ]
	assert_call "find] [/sstate] [-type] [f] [-mtime] [+90] [-delete]"
	printf '%s\n' "$output" | grep -qF "pruned 1 sstate object(s)"
}

@test "sstate prune: declining the confirmation deletes nothing" {
	MOCK_SSTATE_SIZES="1048576" mk sstate prune --older-than 90d <<< "n"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	refute_call "-delete"
}

@test "sstate prune: -u 0:0 is used for both the scan and the delete" {
	MOCK_SSTATE_SIZES="1048576" mk -y sstate prune --older-than 90d
	assert_call "run] [--rm] [-u] [0:0] [-v] [oe-build-sstate:/sstate] [ghcr.io/siemens/kas/kas:5.4] [find] [/sstate] [-type] [f] [-mtime] [+90] [-printf]"
	assert_call "run] [--rm] [-u] [0:0] [-v] [oe-build-sstate:/sstate] [ghcr.io/siemens/kas/kas:5.4] [find] [/sstate] [-type] [f] [-mtime] [+90] [-delete]"
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "sstate prune --dry-run reports but never deletes" {
	MOCK_SSTATE_SIZES="1048576 2097152" mk -y --dry-run sstate prune --older-than 90d
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "found      : 2 object(s)"
	refute_call "-delete"
}

# ---------------------------------------------------------------------------
# One-VM rule
# ---------------------------------------------------------------------------

@test "sstate prune: refuses when a running container holds the sstate volume" {
	MOCK_BUSY_VOLUME="oe-build-sstate" mk -y sstate prune --older-than 90d
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_call "find] [/sstate"
}

@test "sstate prune: a container holding a DIFFERENT volume does not block it" {
	MOCK_BUSY_VOLUME="some-other-volume" MOCK_SSTATE_SIZES="1024" mk -y sstate prune --older-than 90d
	[ "$status" -eq 0 ]
	assert_call "find] [/sstate"
}

# ---------------------------------------------------------------------------
# --help / dispatch
# ---------------------------------------------------------------------------

@test "sstate --help prints usage and does nothing" {
	mk sstate --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'sstate prune'
	refute_call "find] [/sstate"
}

@test "sstate: an unknown subcommand is refused" {
	mk -y sstate bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "unknown 'sstate' subcommand"
}

@test "sstate prune: an unknown option is refused" {
	mk -y sstate prune --bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown option'
}
