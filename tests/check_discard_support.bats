#!/usr/bin/env bats
#
# Tests for check_target_volume()'s fstrim/discard-reclaim probe.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Real-world finding, not a hypothetical: mackas relocates Apple container's
# volume storage under MACKAS_ROOT (see docs/storage.md), so every
# volume.img physically lives on whatever filesystem MACKAS_ROOT is on.
# Measured live on two Macs, same `container` version: MACKAS_ROOT on APFS
# reclaims space via `volume fstrim`; MACKAS_ROOT on ExFAT fails every
# fstrim with "discard operation is not supported" -- on a completely fresh
# volume, not just an old one, so it tracks the filesystem, not mackas or a
# particular volume's history.
#
# This must be informational, NEVER fatal: some hosts have no APFS option at
# all (a drive that has to stay ExFAT to also work with another device), and
# the ext4 volumes themselves work fine either way -- they just cannot
# shrink back below their peak usage on such a host.
#
# diskutil is stubbed (real diskutil's exact wording/locale is not something
# to depend on in a hermetic test) so this exercises check_target_volume()
# directly via MACKAS_LIB_ONLY=1, without needing a real container runtime.
#
# NOTE: bats' own `run` helper must not be used here -- mackas defines a
# run() of its own, and sourcing the script shadows bats' version. These use
# plain command substitution instead (same reason/pattern as units.bats).

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/diskutil" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
	if [ -z "${FAKE_DISKUTIL_FS_PERSONALITY+x}" ]; then
		exit 1   # simulates diskutil itself failing / reporting nothing
	fi
	printf '   File System Personality:   %s\n' "$FAKE_DISKUTIL_FS_PERSONALITY"
	exit 0
fi
exit 1
EOF
	chmod +x "$TESTDIR/fakebin/diskutil"
	PATH="$TESTDIR/fakebin:$PATH"

	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	MACKAS_SHORT_LINK="$TESTDIR/nonexistent-short-link-xyzzy"
	mkdir -p "$MACKAS_ROOT"
	derive_paths
	DRY_RUN=0
}

teardown() {
	rm -rf "$TESTDIR"
}

@test "check: APFS gets a PASS mentioning fstrim reclaim" {
	local out
	out="$(FAKE_DISKUTIL_FS_PERSONALITY="Case-sensitive APFS" check_target_volume 2>&1)"
	printf '%s\n' "$out" | grep -qF '[PASS]'
	printf '%s\n' "$out" | grep -qi 'reclaim'
	printf '%s\n' "$out" | grep -qF 'APFS'
}

@test "check: ExFAT gets a WARN (not a FAIL) explaining fstrim may not reclaim" {
	local out
	out="$(FAKE_DISKUTIL_FS_PERSONALITY="ExFAT" check_target_volume 2>&1)"
	printf '%s\n' "$out" | grep -qF '[WARN]'
	printf '%s\n' "$out" | grep -qi 'may not be able to reclaim'
}

@test "check: ExFAT's warning points at lowering the volume size caps, not at reformatting" {
	# The fix must not presume APFS is reachable -- some hosts (e.g. a drive
	# shared with an iPhone, which requires ExFAT) have no APFS option.
	# Isolated to the discard-related [WARN]/fix pair specifically: the
	# UNRELATED case-sensitivity check in this same sandbox (a bats tmpdir is
	# case-insensitive APFS) legitimately says "reformat" in ITS OWN fix
	# hint, and that must not make this assertion pass for the wrong reason.
	local out block
	out="$(FAKE_DISKUTIL_FS_PERSONALITY="ExFAT" check_target_volume 2>&1)"
	block="$(printf '%s\n' "$out" | grep -A1 -i 'reclaim')"
	printf '%s\n' "$block" | grep -qF 'MACKAS_VOLUME_SIZE'
	! printf '%s\n' "$block" | grep -qi 'reformat'
}

@test "check: an undetermined filesystem is informational only, not a WARN or FAIL" {
	local out
	out="$(check_target_volume 2>&1)"   # FAKE_DISKUTIL_FS_PERSONALITY unset -> diskutil "fails"
	printf '%s\n' "$out" | grep -qF '[info]'
	printf '%s\n' "$out" | grep -qi 'could not determine'
}

@test "check: a failing diskutil during the case-sensitivity fallback does not abort (regression, set -e/pipefail)" {
	# A DIFFERENT, pre-existing call site with the identical bug: reach it by
	# making MACKAS_ROOT unwritable, so the case-sensitivity probe cannot
	# write test files and falls back to parsing diskutil instead. Before the
	# `|| true` fix, a "failing" diskutil (FAKE_DISKUTIL_FS_PERSONALITY
	# unset here) aborted check_target_volume outright under pipefail,
	# instead of falling through to "diskutil reports: unknown".
	chmod 555 "$MACKAS_ROOT"
	local out
	out="$(check_target_volume 2>&1)"
	chmod 755 "$MACKAS_ROOT"   # restore so teardown's rm -rf can clean up
	printf '%s\n' "$out" | grep -qi 'cannot probe empirically'
	printf '%s\n' "$out" | grep -qi 'unknown'
}

@test "check: the fstrim/discard line itself is never a FAIL, whatever the filesystem" {
	# Isolated from the OTHER checks in check_target_volume (case-sensitivity,
	# free space), which fail unconditionally in this sandbox (a bats tmpdir
	# is case-insensitive APFS with no 200+ GiB free) -- that is expected and
	# unrelated; only the fstrim/discard line itself must never say [FAIL].
	local fs out line
	for fs in "Case-sensitive APFS" "ExFAT" "MS-DOS FAT32" "NTFS"; do
		out="$(FAKE_DISKUTIL_FS_PERSONALITY="$fs" check_target_volume 2>&1)"
		line="$(printf '%s\n' "$out" | grep -i 'reclaim')"
		[ -n "$line" ]
		! printf '%s\n' "$line" | grep -qF '[FAIL]'
	done
}
