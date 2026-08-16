#!/usr/bin/env bats
#
# Unit tests for mackas' pure helper functions, exercised in isolation by
# sourcing the script with MACKAS_LIB_ONLY=1 (which suppresses main).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

load helpers

setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	TESTDIR="$(make_tmpdir)"
}

teardown() {
	rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# size_to_gb -- parses the volume-size / memory strings
# ---------------------------------------------------------------------------

@test "size_to_gb: plain gigabytes, several spellings" {
	[ "$(size_to_gb 200G)" = "200" ]
	[ "$(size_to_gb 200g)" = "200" ]
	[ "$(size_to_gb 200GB)" = "200" ]
	[ "$(size_to_gb 200GiB)" = "200" ]
}

@test "size_to_gb: a bare number is treated as gigabytes" {
	[ "$(size_to_gb 42)" = "42" ]
}

@test "size_to_gb: terabytes are scaled by 1024" {
	[ "$(size_to_gb 2T)" = "2048" ]
	[ "$(size_to_gb 1tb)" = "1024" ]
}

@test "size_to_gb: megabytes round UP to whole gigabytes" {
	# 1024M is exactly 1G; anything above must not round down to 1.
	[ "$(size_to_gb 1024M)" = "1" ]
	[ "$(size_to_gb 1025M)" = "2" ]
	[ "$(size_to_gb 1M)" = "1" ]
}

@test "size_to_gb: a non-numeric string yields 0 rather than erroring" {
	[ "$(size_to_gb "")" = "0" ]
	[ "$(size_to_gb "abc")" = "0" ]
}

@test "size_to_gb: real 'du -h' output with a decimal point still parses (near-cap depends on it)" {
	# status_volume() feeds size_to_gb() real `du -h` output like "8.0M" --
	# the decimal point means the unit match below fails (".0m" is not "m"),
	# same as any other unrecognised-unit input, so it falls to the
	# catch-all. That fallback deliberately still reads as GiB, not 0: it
	# overestimates whatever slips through, which errs on the side of a
	# near-cap warning firing rather than a full volume going unreported.
	[ "$(size_to_gb "8.0M")" = "8" ]
}

@test "size_to_gb: the real default volume size parses to 200" {
	[ "$(size_to_gb 200G)" = "200" ]
}

# ---------------------------------------------------------------------------
# valid_size_shape -- the single shape validate_settings()/validate_setup_size()
# both pin MACKAS_VOLUME_SIZE_*/--tmpdir-size et al to.
# ---------------------------------------------------------------------------

@test "valid_size_shape: accepts every unit size_to_gb/size_to_bytes parse" {
	for v in 1T 200G 512M 42 1t 200g 512m 1TB 1TiB 200GB 200GiB 512MB 512MiB; do
		valid_size_shape "$v" || { echo "expected '$v' to be valid" >&2; return 1; }
	done
}

@test "valid_size_shape: refuses an unrecognised unit, garbage or empty" {
	for v in 512K lol "" abc "1t2" "1 T"; do
		! valid_size_shape "$v" || { echo "expected '$v' to be refused" >&2; return 1; }
	done
}

# ---------------------------------------------------------------------------
# nearest_existing_dir -- underpins the writability check
# ---------------------------------------------------------------------------

@test "nearest_existing_dir: an existing directory is returned as-is" {
	[ "$(nearest_existing_dir "$TESTDIR")" = "$TESTDIR" ]
}

@test "nearest_existing_dir: walks up to the nearest existing parent" {
	# Regression guard: writability must be tested against the nearest
	# existing parent, NOT the mount point.
	[ "$(nearest_existing_dir "$TESTDIR/a/b/c/d")" = "$TESTDIR" ]
}

@test "nearest_existing_dir: copes with a path containing spaces" {
	mkdir -p "$TESTDIR/My Build Disk"
	got="$(nearest_existing_dir "$TESTDIR/My Build Disk/oe/work")"
	[ "$got" = "$TESTDIR/My Build Disk" ]
}

@test "nearest_existing_dir: a wholly nonexistent path bottoms out at /" {
	[ "$(nearest_existing_dir "/nonexistent-xyzzy/a/b")" = "/" ]
}

# ---------------------------------------------------------------------------
# volume_mount_point
# ---------------------------------------------------------------------------

@test "volume_mount_point: resolves to a real mount point for /tmp" {
	got="$(volume_mount_point /tmp)"
	[ -n "$got" ]
	[ -d "$got" ]
}

@test "volume_mount_point: works for a path that does not exist yet" {
	got="$(volume_mount_point "$TESTDIR/not/created/yet")"
	[ -n "$got" ]
	[ -d "$got" ]
}

# ---------------------------------------------------------------------------
# adopt_check_ownership -- the noowners fast path must survive a mount point
# with a space in it (a Finder-named external drive, e.g. "1TB WD Blue").
# `df`/`mount`/`find` are overridden as one-line seams for the duration of a
# single test, the same pattern workspace_attach.bats uses for path_device --
# real df/mount output is reproduced verbatim, never reparsed loosely.
# ---------------------------------------------------------------------------

@test "adopt_check_ownership: a mount point containing a space is matched, not truncated" {
	mkdir -p "$TESTDIR/root/work"
	FIND_LOG="$TESTDIR/find.log"
	df() {
		printf 'Filesystem 512-blocks Used Available Capacity Mounted on\n'
		printf '/dev/disk15s1 1953115488 7104 1952703784 1%% /Volumes/1TB WD Blue\n'
	}
	mount() {
		printf '/dev/disk15s1 on /Volumes/1TB WD Blue (apfs, local, noowners)\n'
	}
	find() { printf 'called\n' >>"$FIND_LOG"; command find "$@"; }

	local out rc
	set +e; out="$(adopt_check_ownership "$TESTDIR/root" 2>&1)"; rc=$?; set -e

	[ "$rc" -eq 0 ]
	# The fast path must return before ever walking work/ -- that walk over a
	# real multi-GB OE checkout is the multi-minute stall this function
	# exists to avoid. If $NF truncated the mount point to "Blue", the
	# `mount` grep below would never match and this test would still see
	# 'find' invoked (harmlessly, since work/ is empty here) instead of
	# short-circuiting.
	[ ! -e "$FIND_LOG" ]
	[ -z "$out" ]
}

# ---------------------------------------------------------------------------
# is_setting_name -- guards --set
# ---------------------------------------------------------------------------

# NOTE: bats' own `run` helper must not be used in this file. mackas defines
# a run() of its own (the verbose/dry-run command wrapper), and sourcing the
# script shadows bats' version. These call the functions directly instead.

@test "is_setting_name: accepts real settings and rejects invented ones" {
	is_setting_name MACKAS_VOLUME_SIZE_TMP
	is_setting_name KAS_IMAGE
	! is_setting_name TOTALLY_MADE_UP
}

@test "is_setting_name: does not match on a prefix" {
	! is_setting_name MACKAS_VOLUME
}

# ---------------------------------------------------------------------------
# Defaults and derivation, called directly
# ---------------------------------------------------------------------------

@test "set_defaults leaves cpus and memory sane for this host" {
	set_defaults
	[ "$MACKAS_CPUS" -ge 2 ]
	printf '%s' "$MACKAS_MEMORY" | grep -qE '^[0-9]+g$'
}

@test "set_defaults never asks for more RAM than the host has" {
	set_defaults
	host="$(host_mem_gb)"
	want="$(size_to_gb "$MACKAS_MEMORY")"
	[ "$want" -le "$host" ]
}

@test "derive_paths derives the NFS mount from MACKAS_ROOT when unset" {
	set_defaults
	MACKAS_ROOT="/tmp/mackas-unit"
	MACKAS_NFS_MOUNT=""
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	[ "$MACKAS_NFS_MOUNT" = "/tmp/mackas-unit/nfs" ]
}

@test "derive_paths falls back to MACKAS_ROOT when the short link is absent" {
	set_defaults
	MACKAS_ROOT="/tmp/mackas-unit"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	[ "$MACKAS_BASE" = "/tmp/mackas-unit" ]
	[ "$MACKAS_WORK" = "/tmp/mackas-unit/work" ]
}

@test "derive_paths strips a trailing slash from MACKAS_ROOT (no doubled // in derived paths)" {
	# A user-typed or tab-completed root ("...Angstrom/") must not double up
	# in every "$MACKAS_ROOT/bin"-style concatenation below.
	set_defaults
	MACKAS_ROOT="/tmp/mackas-unit/"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	[ "$MACKAS_ROOT" = "/tmp/mackas-unit" ]
	[ "$MACKAS_BASE" = "/tmp/mackas-unit" ]
	[ "$MACKAS_WORK" = "/tmp/mackas-unit/work" ]
}

@test "derive_paths strips multiple trailing slashes from MACKAS_ROOT" {
	set_defaults
	MACKAS_ROOT="/tmp/mackas-unit///"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	[ "$MACKAS_ROOT" = "/tmp/mackas-unit" ]
}

@test "derive_paths leaves a bare / as MACKAS_ROOT intact" {
	set_defaults
	MACKAS_ROOT="/"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	[ "$MACKAS_ROOT" = "/" ]
}

@test "derive_paths prefers the short link when it RESOLVES to MACKAS_ROOT" {
	# This test used to point MACKAS_SHORT_LINK at a bare directory unrelated
	# to MACKAS_ROOT and assert it was adopted anyway -- it pinned the bug
	# rather than the contract. Merely existing is not the bar; resolving to
	# THIS MACKAS_ROOT is. The stale and dangling cases that "merely exists"
	# let through are covered in volumes.bats.
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$MACKAS_ROOT" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_SHORT_LINK" ]
	[ "$MACKAS_WORK" = "$MACKAS_SHORT_LINK/work" ]
}

@test "derive_paths does not adopt a short link that resolves elsewhere" {
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	mkdir -p "$MACKAS_ROOT" "$TESTDIR/somewhere-else"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$TESTDIR/somewhere-else" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_ROOT" ]
}

# ---------------------------------------------------------------------------
# kas_env_prefix -- the "paste this back to reproduce it by hand" log header
# ---------------------------------------------------------------------------

@test "kas_env_prefix: includes KAS_CONTAINER_ENGINE, KAS_CONTAINER_IMAGE, BB_NUMBER_THREADS and PARALLEL_MAKE" {
	# These four used to be silently missing from the printed header, so
	# pasting it back verbatim did not actually reproduce run_kas()'s own
	# _kas_exec invocation (now kas_invoke_env(), shared with it). Pin all
	# four so none of them can quietly drop out again.
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	MACKAS_CPUS=6
	derive_paths
	out="$(kas_env_prefix)"
	printf '%s\n' "$out" | grep -qF 'KAS_CONTAINER_ENGINE=docker'
	printf '%s\n' "$out" | grep -qF "KAS_CONTAINER_IMAGE=$KAS_IMAGE"
	printf '%s\n' "$out" | grep -qF 'BB_NUMBER_THREADS=6'
	printf '%s\n' "$out" | grep -qF 'PARALLEL_MAKE=-j 6'
}

@test "kas_env_prefix: still carries the pre-existing PATH/KAS_WORK_DIR/blanked-dirs/GITCONFIG_FILE fields" {
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	out="$(kas_env_prefix)"
	printf '%s\n' "$out" | grep -qF "PATH=$SHIM_DIR:/opt/homebrew/bin:\$PATH"
	printf '%s\n' "$out" | grep -qF "KAS_WORK_DIR=$MACKAS_WORK"
	printf '%s\n' "$out" | grep -qF 'KAS_BUILD_DIR= DL_DIR= SSTATE_DIR='
	printf '%s\n' "$out" | grep -qF "GITCONFIG_FILE=$MACKAS_GITCONFIG"
}

@test "sourcing with MACKAS_LIB_ONLY=1 does not run a command" {
	# If main had run, setup() would have emitted preflight output or exited.
	# Reaching this point at all is the assertion.
	[ "$MACKAS_LIB_ONLY" = "1" ]
}

# ---------------------------------------------------------------------------
# No maintainer-private identifiers ship in the tool.
#
# The tool must be generic: no encoding of one person's disks, host, uid or
# LAN. This greps the shipped files for the specific private strings that were
# purged and fails if any comes back. It is deliberately cheap and blunt --
# a guard, not a style check. The mirror-server files and the Python tests are
# scanned too; this file itself is not, because it necessarily spells out the
# forbidden patterns as literals below.
#
# Note the GPL header's "Koen Kooi <koen@dominion...>" is AUTHORSHIP and stays;
# the patterns below are chosen not to match it.
# ---------------------------------------------------------------------------

@test "guard: no maintainer-private strings remain in the shipped tool" {
	local f pat
	local files="mackas mackas.conf.example README.md docs/architecture.md docs/homebrew.md"
	files="$files mirror-server/mackas-mirrord mirror-server/mackas-mirrord.service"
	files="$files mirror-server/mackas-mirrord.conf.example run-tests.sh"
	files="$files tests/test_mirrord.py"
	# disk names, the private LAN host + its subnet, the taken port + its
	# owner, the uid, and the host-owner literal.
	for pat in \
		'2TB Samsung' \
		'970 EVO' \
		'/Volumes/Foto' \
		'rogue' \
		'172.20.' \
		'iiotool' \
		'8090' \
		'koen:staff'
	do
		for f in $files; do
			if grep -nF "$pat" "$REPO_ROOT/$f"; then
				echo "FORBIDDEN string '$pat' found in $f" >&2
				return 1
			fi
		done
	done
}

@test "guard: MACKAS_ROOT has no built-in disk-path default in the source" {
	# The default assignment must be empty. A regex catch-all for any
	# 'MACKAS_ROOT="/...' default would have caught the old shipped disk.
	! grep -nE '^\s*MACKAS_ROOT="/.+"' "$MACKAS"
}
