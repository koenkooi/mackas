#!/usr/bin/env bats
#
# Tests for the three ext4 volumes and the --runtime-args string that mounts
# them: the wiring between mackas and kas-container.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Every test here is a regression guard for a bug that actually shipped, with
# a green test suite, because nothing asserted the contract with kas:
#
#   1. The volumes were created and mounted NOWHERE. KAS_BUILD_DIR was
#      exported at an APFS path, and kas-container's forward_dir() dutifully
#      BIND-MOUNTED that over /build -- so TMPDIR ran on virtiofs, which is
#      the one thing the ext4 volumes exist to prevent.
#   2. KAS_EXTRA_RUNTIME_ARGS was exported from env.sh. It is NOT an
#      environment variable: kas-container blanks it before parsing its own
#      arguments, so the cpu/memory limits were silently discarded and every
#      container ran at Apple's defaults of cpus=4/memory=1gb.
#   3. A fresh volume's root is root:root. kas correctly drops to
#      USER_ID/GROUP_ID and then dies on /build/CACHEDIR.TAG with EACCES.
#
# The kas-container half of the contract is verified by reading upstream (see
# README) and by hand; these tests pin mackas' half of it, which is where all
# three bugs lived.
#
# NOTE: bats' own `run` helper must not be used in the tests that source
# mackas -- mackas defines a run() of its own and sourcing shadows bats'
# version. Those use command substitution and explicit subshells, as
# mirrors.bats does.

bats_require_minimum_version 1.5.0

load helpers

# ---------------------------------------------------------------------------
# kas_runtime_args -- the string that carries everything
# ---------------------------------------------------------------------------

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
	MACKAS_CPUS=6
	MACKAS_MEMORY=12g
	derive_paths
	DRY_RUN=0
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

@test "runtime-args: carries the cpu and memory limits" {
	# Bug 2. Apple container defaults to cpus=4/memory=1gb, and an exported
	# KAS_EXTRA_RUNTIME_ARGS never arrives, so these MUST be on the flag.
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qE '(^| )-c 6( |$)'
	printf '%s\n' "$args" | grep -qE '(^| )-m 12g( |$)'
}

@test "runtime-args: mounts the TMPDIR volume at /build and names it there" {
	# Bug 1. The -v and the -e must travel together: the -v provides a real
	# ext4 at /build, the -e tells kas to use it WITHOUT forward_dir() ever
	# seeing a host path to bind-mount.
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v oe-build-tmp:/build -e KAS_BUILD_DIR=/build"
}

@test "runtime-args: mounts the downloads volume at /downloads" {
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v oe-build-dl:/downloads -e DL_DIR=/downloads"
}

@test "runtime-args: mounts the sstate volume at /sstate" {
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate"
}

@test "runtime-args: names three DIFFERENT volumes" {
	# The whole point of the split: TMPDIR can be destroyed without losing the
	# caches. One volume mounted three times would silently defeat that.
	[ "$MACKAS_VOL_TMP" != "$MACKAS_VOL_DL" ]
	[ "$MACKAS_VOL_DL" != "$MACKAS_VOL_SSTATE" ]
	[ "$MACKAS_VOL_TMP" != "$MACKAS_VOL_SSTATE" ]
}

@test "runtime-args: mounts no host path over /build, /downloads or /sstate" {
	# The regression that WAS bug 1: any '-v /some/host/path:/build' here means
	# TMPDIR is back on APFS/virtiofs. A volume reference has no leading slash.
	args="$(kas_runtime_args)"
	! printf '%s\n' "$args" | grep -qE -- '-v +/[^ ]*:(/build|/downloads|/sstate)'
}

@test "runtime-args: contains no whitespace-bearing value (kas word-splits it)" {
	# kas-container expands ${KAS_EXTRA_RUNTIME_ARGS} unquoted, so a space
	# inside any single value would split it into two arguments.
	MACKAS_VOLUME_NAME="oe build"
	derive_paths
	args="$(kas_runtime_args)"
	# 'oe build:/build' would appear as two words; assert the value we would
	# have produced is caught by setup rather than shipped.
	out="$( (setup_volumes) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'whitespace'
}

@test "runtime-args: the NFS mirror mounts ride along when enabled" {
	MACKAS_USE_NFS_MIRRORS=1
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- ":/sstate-mirror:ro"
	printf '%s\n' "$args" | grep -qF -- ":/downloads-mirror:ro"
	# ...and the real volumes are still there.
	printf '%s\n' "$args" | grep -qF -- "-e KAS_BUILD_DIR=/build"
}

# ---------------------------------------------------------------------------
# MACKAS_MONITOR -- the bitbake progress bridge (TODO.md item 22). OFF by
# default; when on, mounts mackasjson.py and the wrapper file (each as its
# OWN individual -v mount, never one whole-directory mount alongside a
# second mount targeting a file inside that same directory -- confirmed
# live that Apple's container silently drops the first mount when two -v
# HOST source paths overlap that way) over the real bitbake checkout's own
# bin/bitbake, discovered from the host side.
# ---------------------------------------------------------------------------

@test "runtime-args: MACKAS_MONITOR=0 (the default) adds nothing" {
	args="$(kas_runtime_args)"
	! printf '%s\n' "$args" | grep -q 'mackas-uibridge'
	! printf '%s\n' "$args" | grep -qE -- '(^| )-p '
}

@test "runtime-args: MACKAS_MONITOR=1 mounts the bridge over a real bitbake checkout" {
	MACKAS_MONITOR=1
	mkdir -p "$MACKAS_WORK/bitbake/bin"
	touch "$MACKAS_WORK/bitbake/bin/bitbake"
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v $REPO_ROOT/mackas-uibridge/mackasjson.py:/mackas-uibridge/mackasjson.py:ro"
	printf '%s\n' "$args" | grep -qF -- "-v $REPO_ROOT/mackas-uibridge/bitbake:/work/bitbake/bin/bitbake:ro"
	printf '%s\n' "$args" | grep -qF -- "-p 8801:8801"
	printf '%s\n' "$args" | grep -qF -- "-e MACKAS_MONITOR_PORT=8801"
}

@test "runtime-args: MACKAS_MONITOR=1 never whole-directory-mounts mackas-uibridge/" {
	# Regression guard for a bug that actually shipped and was caught live:
	# Apple's container silently drops a -v mount whenever a LATER -v's host
	# source path is nested inside an EARLIER -v's host source directory --
	# even when their container targets are unrelated (e.g. one whole-dir
	# mount at /mackas-uibridge alongside a second mount of
	# mackas-uibridge/bitbake onto /work/.../bitbake made the FIRST mount
	# vanish; nothing said so). mackasjson.py must be mounted as its own
	# individual file, matching the bitbake wrapper's own mount shape.
	MACKAS_MONITOR=1
	mkdir -p "$MACKAS_WORK/bitbake/bin"
	touch "$MACKAS_WORK/bitbake/bin/bitbake"
	args="$(kas_runtime_args)"
	! printf '%s\n' "$args" | grep -qE -- "-v [^ ]*mackas-uibridge:/mackas-uibridge:ro"
}

@test "runtime-args: MACKAS_MONITOR=1 honours a custom MACKAS_MONITOR_PORT" {
	MACKAS_MONITOR=1
	MACKAS_MONITOR_PORT=9100
	mkdir -p "$MACKAS_WORK/bitbake/bin"
	touch "$MACKAS_WORK/bitbake/bin/bitbake"
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-p 9100:9100"
	printf '%s\n' "$args" | grep -qF -- "-e MACKAS_MONITOR_PORT=9100"
	! printf '%s\n' "$args" | grep -qF -- "8801"
}

@test "runtime-args: MACKAS_MONITOR=1 finds bitbake regardless of the checkout's directory name" {
	# kas lets a project's kas.yml name the checkout anything; discovery must
	# not assume the literal name 'bitbake'.
	MACKAS_MONITOR=1
	mkdir -p "$MACKAS_WORK/some-custom-name/bin"
	touch "$MACKAS_WORK/some-custom-name/bin/bitbake"
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v $REPO_ROOT/mackas-uibridge/bitbake:/work/some-custom-name/bin/bitbake:ro"
}

@test "runtime-args: MACKAS_MONITOR=1 with no bitbake checkout yet is a silent no-op" {
	MACKAS_MONITOR=1
	# MACKAS_WORK exists (derive_paths created it in spirit, but not on disk
	# here) -- create it empty, matching "project not cloned yet".
	mkdir -p "$MACKAS_WORK"
	args="$(kas_runtime_args)"
	! printf '%s\n' "$args" | grep -q 'mackas-uibridge'
	! printf '%s\n' "$args" | grep -qE -- '(^| )-p '
}

@test "runtime-args: MACKAS_MONITOR=1 with MACKAS_WORK not existing yet is a silent no-op" {
	MACKAS_MONITOR=1
	rm -rf "$MACKAS_WORK"
	args="$(kas_runtime_args)"
	! printf '%s\n' "$args" | grep -q 'mackas-uibridge'
}

# ---------------------------------------------------------------------------
# NFS mirrors + whitespace. Not a corner case: an ordinary MACKAS_ROOT with a
# space in it -- "/Volumes/My Build Disk/oe" -- has the mirror paths derive
# from it, and kas-container word-splits --runtime-args, so turning NFS mirrors
# on produced "-v /Volumes/My", "Build", "Disk/oe/...", ... as separate
# arguments. setup_volumes already guarded MACKAS_VOLUME_NAME against exactly
# this; nothing guarded the mirror paths, which ride in the same string.
# ---------------------------------------------------------------------------

@test "nfs mirrors: a whitespace mirror path is refused, not word-split" {
	MACKAS_ROOT="/Volumes/My Build Disk/oe"
	MACKAS_USE_NFS_MIRRORS=1
	MACKAS_NFS_MOUNT=""
	MACKAS_SSTATE_MIRROR_PATH=""
	MACKAS_DL_MIRROR_PATH=""
	out="$( (derive_paths) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'whitespace'
	# It must point somewhere useful rather than just saying no.
	printf '%s\n' "$out" | grep -q 'next:'
	printf '%s\n' "$out" | grep -qF 'MACKAS_USE_HTTP_MIRRORS=1'
}

@test "nfs mirrors: an explicitly-set whitespace mirror path is refused too" {
	MACKAS_USE_NFS_MIRRORS=1
	MACKAS_SSTATE_MIRROR_PATH="/mnt/space here/sstate"
	MACKAS_DL_MIRROR_PATH="/mnt/ok/downloads"
	out="$( (derive_paths) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'whitespace'
}

@test "nfs mirrors: a space-free mirror path is accepted and mounted" {
	MACKAS_ROOT="/opt/oe"
	MACKAS_USE_NFS_MIRRORS=1
	MACKAS_NFS_MOUNT=""
	MACKAS_SSTATE_MIRROR_PATH=""
	MACKAS_DL_MIRROR_PATH=""
	derive_paths
	args="$(kas_runtime_args)"
	printf '%s\n' "$args" | grep -qF -- "-v /opt/oe/nfs/"
	printf '%s\n' "$args" | grep -qF -- ":/sstate-mirror:ro"
}

@test "nfs mirrors OFF: a spacey root is fine, because nothing is -v mounted" {
	# The guard must only fire for the NFS path. The default root has spaces
	# in it and mirrors default to off, so this is the normal case -- refusing
	# it would break every stock install.
	MACKAS_ROOT="/Volumes/My Build Disk/oe"
	MACKAS_USE_NFS_MIRRORS=0
	MACKAS_NFS_MOUNT=""
	MACKAS_SSTATE_MIRROR_PATH=""
	MACKAS_DL_MIRROR_PATH=""
	out="$( (derive_paths) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
	derive_paths
	args="$(kas_runtime_args)"
	# Assert ABSENT with `! ... | grep -q`; the -qv form passes vacuously on
	# multi-line output (it exits 0 as soon as one line lacks the pattern).
	! printf '%s\n' "$args" | grep -q 'sstate-mirror'
}

@test "http mirrors: a spacey root is fine, they need no -v mount" {
	MACKAS_ROOT="/Volumes/My Build Disk/oe"
	MACKAS_USE_NFS_MIRRORS=0
	MACKAS_USE_HTTP_MIRRORS=1
	MACKAS_NFS_MOUNT=""
	MACKAS_SSTATE_MIRROR_PATH=""
	MACKAS_DL_MIRROR_PATH=""
	out="$( (derive_paths) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MACKAS_BASE and the short link.
#
# derive_paths used to adopt MACKAS_SHORT_LINK whenever [ -L ] was true, with
# no check that it resolved to MACKAS_ROOT -- and [ -L ] is true for a DANGLING
# link. check_short_link/setup_short_link do validate it, but they only run for
# `check` and `setup`, while derive_paths runs first and for everything. So a
# leftover ~/oe -> /tmp/other-root silently redirected env.sh, gitconfig, the
# shim, the fragment and MACKAS_LOGS -- including clean's rm -rf "$MACKAS_LOGS".
# ---------------------------------------------------------------------------

@test "short link: a correct link IS adopted as MACKAS_BASE" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$MACKAS_ROOT" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_SHORT_LINK" ]
	[ "$MACKAS_LOGS" = "$MACKAS_SHORT_LINK/logs" ]
}

@test "short link: a target recorded with a trailing slash (an older mackas) is still adopted" {
	# ln -sfn "$MACKAS_ROOT/" ... bakes the trailing slash into the symlink's
	# OWN recorded target -- readlink returns it verbatim. A mackas from
	# before MACKAS_ROOT normalization existed could have created exactly
	# this. Comparing unnormalized would read as "does not resolve to
	# MACKAS_ROOT" even though it is the same directory.
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$MACKAS_ROOT/" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_SHORT_LINK" ]
	[ "$MACKAS_LOGS" = "$MACKAS_SHORT_LINK/logs" ]
}

@test "short link: a DANGLING link is not adopted" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$TESTDIR/does-not-exist" "$MACKAS_SHORT_LINK"
	[ -L "$MACKAS_SHORT_LINK" ]   # the old test that was not enough
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_ROOT" ]
}

@test "short link: a STALE link pointing at another root is not adopted" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT" "$TESTDIR/other-root"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$TESTDIR/other-root" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_ROOT" ]
	# The specific damage: clean's rm -rf target must never be the other tree.
	[ "$MACKAS_LOGS" = "$MACKAS_ROOT/logs" ]
	case "$MACKAS_LOGS" in
		*other-root*) echo "MACKAS_LOGS points into the stale link's tree" >&2; return 1 ;;
	esac
}

@test "short link: every derived path follows MACKAS_ROOT when the link is stale" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT" "$TESTDIR/other-root"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$TESTDIR/other-root" "$MACKAS_SHORT_LINK"
	derive_paths
	local p
	for p in "$MACKAS_ENV_SH" "$MACKAS_GITCONFIG" "$KAS_CONTAINER_BIN" \
	         "$SHIM_DIR" "$MACKAS_KAS_FRAGMENT_SRC" "$MACKAS_WORK" "$MACKAS_LOGS"; do
		case "$p" in
			"$MACKAS_ROOT"/*) ;;
			*) echo "derived path escaped MACKAS_ROOT: $p" >&2; return 1 ;;
		esac
	done
}

@test "short link: no link at all means MACKAS_BASE is MACKAS_ROOT" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/no-such-link"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_ROOT" ]
}

@test "short link: a link to a FILE rather than a directory is not adopted" {
	MACKAS_ROOT="$TESTDIR/realroot"
	mkdir -p "$MACKAS_ROOT"
	: > "$TESTDIR/afile"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$TESTDIR/afile" "$MACKAS_SHORT_LINK"
	derive_paths
	[ "$MACKAS_BASE" = "$MACKAS_ROOT" ]
}

# ---------------------------------------------------------------------------
# setup_short_link -- offering to FIX a mismatch/obstruction rather than just
# refusing and telling the user to `rm` it by hand. Found live: a renamed
# volume (or a new MACKAS_ROOT) leaves the short link pointing at the OLD
# root, and the old behaviour was a hard die every single time until the
# user removed it manually -- needless ceremony for what is almost always
# just "MACKAS_ROOT changed since this link was made."
# ---------------------------------------------------------------------------

@test "setup_short_link: offers to re-point a link at a DIFFERENT root, and does so on accept" {
	MACKAS_ROOT="$TESTDIR/newroot"
	mkdir -p "$MACKAS_ROOT"
	oldroot="$TESTDIR/oldroot"
	mkdir -p "$oldroot"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$oldroot" "$MACKAS_SHORT_LINK"
	ASSUME_YES=1
	setup_short_link >/dev/null 2>&1
	[ -L "$MACKAS_SHORT_LINK" ]
	[ "$(readlink "$MACKAS_SHORT_LINK")" = "$MACKAS_ROOT" ]
}

@test "setup_short_link: declining the re-point offer leaves the old link exactly as-is" {
	MACKAS_ROOT="$TESTDIR/newroot"
	mkdir -p "$MACKAS_ROOT"
	oldroot="$TESTDIR/oldroot"
	mkdir -p "$oldroot"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	ln -sfn "$oldroot" "$MACKAS_SHORT_LINK"
	ASSUME_YES=0
	# confirm() declines non-interactively (no -y, not a terminal).
	out="$( (setup_short_link) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'still points at'
	[ "$(readlink "$MACKAS_SHORT_LINK")" = "$oldroot" ]
}

@test "setup_short_link: offers to move a non-symlink obstruction aside, and does so on accept" {
	MACKAS_ROOT="$TESTDIR/newroot"
	mkdir -p "$MACKAS_ROOT"
	MACKAS_SHORT_LINK="$TESTDIR/oe"
	mkdir -p "$MACKAS_SHORT_LINK"
	: > "$MACKAS_SHORT_LINK/somefile"
	ASSUME_YES=1
	setup_short_link >/dev/null 2>&1
	[ -L "$MACKAS_SHORT_LINK" ]
	[ "$(readlink "$MACKAS_SHORT_LINK")" = "$MACKAS_ROOT" ]
	# The original directory's content survived, moved aside, not deleted.
	moved="$(find "$TESTDIR" -maxdepth 1 -name 'oe.bak.*' | head -1)"
	[ -n "$moved" ]
	[ -f "$moved/somefile" ]
}

# ---------------------------------------------------------------------------
# env.sh -- what it must NOT say. This is where bugs 1 and 2 lived.
# ---------------------------------------------------------------------------

write_env_sh() {
	mkdir -p "$MACKAS_BIN"
	setup_shim_and_env >/dev/null 2>&1
}

@test "env.sh: does NOT export KAS_BUILD_DIR (bug 1: kas bind-mounts it)" {
	write_env_sh
	[ -f "$MACKAS_ENV_SH" ]
	! grep -qE '^[[:space:]]*export[[:space:]]+KAS_BUILD_DIR=' "$MACKAS_ENV_SH"
}

@test "env.sh: does NOT export DL_DIR (bug 1)" {
	write_env_sh
	! grep -qE '^[[:space:]]*export[[:space:]]+DL_DIR=' "$MACKAS_ENV_SH"
}

@test "env.sh: does NOT export SSTATE_DIR (bug 1)" {
	write_env_sh
	! grep -qE '^[[:space:]]*export[[:space:]]+SSTATE_DIR=' "$MACKAS_ENV_SH"
}

@test "env.sh: does NOT export KAS_EXTRA_RUNTIME_ARGS (bug 2: it does nothing)" {
	# kas-container sets KAS_EXTRA_RUNTIME_ARGS="" before parsing arguments.
	# Exporting it is not merely useless, it reads as though the limits are
	# being applied when they are not.
	write_env_sh
	! grep -qE '^[[:space:]]*export[[:space:]]+KAS_EXTRA_RUNTIME_ARGS=' "$MACKAS_ENV_SH"
}

@test "env.sh: still puts the shim FIRST on PATH" {
	# The single most load-bearing line in the file: the real Docker CLI in
	# /usr/local/bin will happily answer kas' engine probe instead.
	#
	# Our value is single-quoted now (see the injection tests further down),
	# while $PATH stays a live reference: it must survive generation as text
	# and expand when env.sh is SOURCED.
	#
	# mackas's own checkout (SCRIPT_DIR) rides along after homebrew so a bare
	# 'mackas ...' works from any directory once env.sh is sourced -- still
	# behind the shim and homebrew, ahead of the user's own $PATH.
	write_env_sh
	grep -qF "export PATH='$SHIM_DIR':/opt/homebrew/bin:'$SCRIPT_DIR':\"\$PATH\"" "$MACKAS_ENV_SH"
}

@test "env.sh: still sets KAS_CONTAINER_ENGINE, BB_NUMBER_THREADS and PARALLEL_MAKE" {
	write_env_sh
	grep -qE '^export KAS_CONTAINER_ENGINE=docker$' "$MACKAS_ENV_SH"
	grep -qF "export BB_NUMBER_THREADS='6'" "$MACKAS_ENV_SH"
	grep -qF "export PARALLEL_MAKE='-j 6'" "$MACKAS_ENV_SH"
}

@test "env.sh: exports the runtime args and a kas-container wrapper that uses them" {
	# Without KAS_BUILD_DIR in the environment, a bare `kas-container` typed by
	# hand would build with no volumes and no limits at all. The wrapper is what
	# keeps that from being a footgun.
	write_env_sh
	grep -qF "export MACKAS_RUNTIME_ARGS='-c 6 -m 12g" "$MACKAS_ENV_SH"
	grep -qF 'kas-container() {' "$MACKAS_ENV_SH"
	grep -qF -- '--runtime-args "$MACKAS_RUNTIME_ARGS"' "$MACKAS_ENV_SH"
	# ...and the wrapper must blank the dir vars for the same reason env.sh
	# does not export them.
	grep -qF 'KAS_BUILD_DIR= DL_DIR= SSTATE_DIR=' "$MACKAS_ENV_SH"
	# ...and it prepends our bin dir so kas-container finds the GNU realpath shim.
	grep -qE 'env PATH=.+ KAS_BUILD_DIR= DL_DIR= SSTATE_DIR=' "$MACKAS_ENV_SH"
}

@test "env.sh: is valid bash 3.2" {
	write_env_sh
	/bin/bash -n "$MACKAS_ENV_SH"
}

@test "env.sh: pins the image WITH its tag and does not set KAS_IMAGE_VERSION" {
	# kas-container's set_container_image_var() returns early when
	# KAS_CONTAINER_IMAGE is set, so KAS_IMAGE_VERSION beside it is ignored and
	# a tagless name silently runs :latest instead of the pinned tag.
	write_env_sh
	grep -qF "export KAS_CONTAINER_IMAGE='ghcr.io/siemens/kas/kas:5.4'" "$MACKAS_ENV_SH"
	! grep -qE '^[[:space:]]*export[[:space:]]+KAS_IMAGE_VERSION=' "$MACKAS_ENV_SH"
}

# ---------------------------------------------------------------------------
# env.sh -- injection, and the plain correctness bug underneath it.
#
# The generator interpolated every path RAW between double quotes:
#
#     export PATH="$SHIM_DIR:/opt/homebrew/bin:$PATH"
#
# so a MACKAS_ROOT containing a double quote closed that string and everything
# after it became code -- executed by whoever sourced env.sh, in their own
# interactive shell. The same values also go into the kas fragment's YAML.
#
# Two defences, and both are tested here: values that cannot be quoted safely
# into shell AND yaml are refused up front (validate_settings), and the ones
# that are allowed are emitted single-quoted (shq).
#
# These tests SOURCE the generated file rather than grepping it. Grepping only
# proves the text looks right; sourcing is the thing that would actually run.
# ---------------------------------------------------------------------------

@test "settings: a double quote in MACKAS_ROOT is refused" {
	MACKAS_ROOT='/tmp/evil"; echo INJECTED-AT-SOURCE-TIME >&2; "/oe'
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'MACKAS_ROOT'
	# It has to say what to do about it, like every other failure here.
	printf '%s\n' "$out" | grep -q 'next:'
}

@test "settings: a backtick in MACKAS_ROOT is refused" {
	MACKAS_ROOT='/tmp/`touch /tmp/mackas-pwned`/oe'
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	[ ! -e /tmp/mackas-pwned ]
}

@test "settings: a newline in MACKAS_ROOT is refused (it breaks the YAML too)" {
	MACKAS_ROOT="$(printf '/tmp/a\necho INJECTED')"
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
}

@test "settings: a literal backslash in MACKAS_ROOT is refused with the actual fix" {
	# The classic mistake: MACKAS_ROOT="/a\ path" in a config file. Backslash
	# is not special inside double quotes, so it survives as a literal
	# character instead of escaping the space -- refuse it with guidance,
	# rather than silently building against a near-certainly-broken path.
	MACKAS_ROOT='/Volumes/2TB\ Samsung\ 970\ EVO\ Plus/Angstrom'
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'MACKAS_ROOT'
	printf '%s\n' "$out" | grep -qi 'backslash'
	printf '%s\n' "$out" | grep -q 'next:'
}

@test "settings: a double quote in the HTTP mirror URL is refused" {
	# This one lands inside a bitbake assignment inside a YAML block scalar,
	# where shell quoting cannot help it.
	MACKAS_HTTP_MIRROR_SSTATE='http://x/"; INHERIT += "evil'
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'MACKAS_HTTP_MIRROR_SSTATE'
}

@test "settings: spaces, \$ and apostrophes in MACKAS_ROOT are ALLOWED" {
	# A volume named "My Build Disk" has spaces, and /Users/o'brien is a name,
	# not an attack. Refusing these would be the fix eating the feature.
	MACKAS_ROOT="/Volumes/My Build Disk/o'brien \$dollar/oe"
	out="$( (validate_settings) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
}

@test "env.sh: a legitimate path with a space, a \$ and an apostrophe SOURCES correctly" {
	# The correctness half. All three are legal on APFS, all three broke the
	# raw-interpolation generator, and none of them may break it now.
	MACKAS_ROOT="$TESTDIR/we ird \$dollar and 'quote"
	mkdir -p "$MACKAS_ROOT"
	derive_paths
	write_env_sh
	[ -f "$MACKAS_ENV_SH" ]

	# Sourced in a clean shell, the value must arrive intact -- not expanded,
	# not truncated at the space, not mangled at the quote.
	got="$(/bin/bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$MACKAS_ROOT"' _ "$MACKAS_ENV_SH")"
	[ "$got" = "$MACKAS_ROOT" ]

	# ...and the shim must really be on PATH, which is what the file is for.
	got="$(/bin/bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$PATH"' _ "$MACKAS_ENV_SH")"
	case ":$got:" in
		*":$MACKAS_ROOT/bin:"*) ;;
		*) echo "shim dir not on PATH: $got" >&2; return 1 ;;
	esac
}

@test "env.sh: \$PATH stays a live reference and is not expanded at generation" {
	# The other side of the quoting: our values must NOT expand, but the
	# user's $PATH must. Baking the generating shell's PATH into the file
	# would be silent and would break every user but one.
	write_env_sh
	! grep -qF "export PATH='$SHIM_DIR:$PATH'" "$MACKAS_ENV_SH"
	grep -qF '"$PATH"' "$MACKAS_ENV_SH"

	# Prove it: a shell with a marker in PATH must still have it afterwards.
	got="$(PATH="/marker-dir-xyzzy:$PATH" /bin/bash -c '. "$1" >/dev/null 2>&1; printf "%s" "$PATH"' _ "$MACKAS_ENV_SH")"
	case ":$got:" in
		*":/marker-dir-xyzzy:"*) ;;
		*) echo "the sourcing shell's PATH was discarded: $got" >&2; return 1 ;;
	esac
}

@test "env.sh: the kas-container wrapper's \$@ and \$MACKAS_RUNTIME_ARGS survive generation" {
	# Same distinction inside the function body: the binary path is ours and
	# is quoted, while $@ and $MACKAS_RUNTIME_ARGS must expand at call time.
	write_env_sh
	grep -qF -- '--runtime-args "$MACKAS_RUNTIME_ARGS" "$@"' "$MACKAS_ENV_SH"
	grep -qF "'$KAS_CONTAINER_BIN'" "$MACKAS_ENV_SH"
}

@test "env.sh: generated from a path with an apostrophe is still valid bash" {
	# The '\'' escaping is easy to get subtly wrong, and a broken env.sh is a
	# syntax error in the user's interactive shell.
	MACKAS_ROOT="$TESTDIR/o'brien"
	mkdir -p "$MACKAS_ROOT"
	derive_paths
	write_env_sh
	/bin/bash -n "$MACKAS_ENV_SH"
	/bin/zsh -n "$MACKAS_ENV_SH"
}

@test "env.sh: does NOT export BB_HASHSERVE_DB_DIR (would re-bind-mount a host path via forward_dir)" {
	# kas-container has its OWN BB_HASHSERVE_DB_DIR forward that BIND-MOUNTS a
	# host directory (~line 636 of kas-container v5.4, same forward_dir()
	# mechanism as KAS_BUILD_DIR/DL_DIR/SSTATE_DIR). Exporting it here would
	# put the hash-equivalence database back on APFS over virtiofs -- the
	# exact bug the ext4 volumes exist to avoid. It is set inside the
	# generated kas fragment's local.conf instead; see volumes.bats' fragment
	# tests.
	write_env_sh
	! grep -qE '^[[:space:]]*export[[:space:]]+BB_HASHSERVE_DB_DIR=' "$MACKAS_ENV_SH"
}

# ---------------------------------------------------------------------------
# env.sh -- the kas-container wrapper auto-appending macos-local.yml
#
# A bare, hand-typed 'kas-container shell <files>' (even through the wrapper
# function, which only supplies --runtime-args) never composed the generated
# fragment onto <files> -- only compose_kas_files() did that, and only
# mackas's own subcommands call it. Reported live: bitbake's own
# hash-equivalence warning at parse time, no other symptom, traced back to a
# hand-typed <files> list that never carried macos-local.yml.
# ---------------------------------------------------------------------------

# fake_kas_container -- installs a fake at KAS_CONTAINER_BIN that just prints
# its argv, one per line, so a test can inspect exactly what the wrapper
# passed through.
fake_kas_container() {
	mkdir -p "$(dirname "$KAS_CONTAINER_BIN")"
	cat > "$KAS_CONTAINER_BIN" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@"
FAKE
	chmod +x "$KAS_CONTAINER_BIN"
}

# with_project_fragment -- a configured project with the fragment already
# installed, the state 'setup' leaves behind.
with_project_fragment() {
	MACKAS_PROJECT_DIR="meta-angstrom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/kas"
	touch "$MACKAS_KAS_FRAGMENT_REPO"
}

@test "kas-container wrapper: appends macos-local.yml when run from work/ (the documented cwd)" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'shell'
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml'
}

@test "kas-container wrapper: appends macos-local.yml when run from inside the project checkout" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_PROJECT" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'kas/base.yml:kas/macos-local.yml'
}

@test "kas-container wrapper: extra kas args after <files> survive the append" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell meta-angstrom/kas/base.yml -c "bitbake foo"' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml'
	printf '%s\n' "$out" | grep -qxF -- '-c'
	printf '%s\n' "$out" | grep -qxF 'bitbake foo'
}

@test "kas-container wrapper: does not double up a <files> list that already names macos-local.yml" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell meta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml' _ "$MACKAS_ENV_SH")"
	[ "$(printf '%s\n' "$out" | grep -c 'macos-local.yml')" -eq 1 ]
}

@test "kas-container wrapper: MACKAS_KAS_AUTO_FRAGMENT=0 disables the auto-append" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; MACKAS_KAS_AUTO_FRAGMENT=0 kas-container shell meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml'
	! printf '%s\n' "$out" | grep -q 'macos-local.yml'
}

@test "kas-container wrapper: no auto-append when no project is configured (fragment not installed)" {
	# MACKAS_PROJECT_DIR is empty (lib_setup's default): MACKAS_KAS_FRAGMENT_REPO
	# names a file that does not exist, so the wrapper has nothing to append.
	write_env_sh
	fake_kas_container
	mkdir -p "$MACKAS_WORK"
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell some.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'some.yml'
	! printf '%s\n' "$out" | grep -q 'macos-local.yml'
}

@test "kas-container wrapper: a flag right after the subcommand is left alone (no <files> to append to)" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container --help' _ "$MACKAS_ENV_SH")"
	! printf '%s\n' "$out" | grep -q 'macos-local.yml'
}

@test "kas-container wrapper: a boolean flag (-k) between the subcommand and <files> still finds <files>" {
	# Reported live: 'kas-container shell -k <files>' -- exactly what
	# bitbake_getvar() itself passes -- put <files> at \$3, not \$2. kas's own
	# config argument is nargs='?' with options allowed before it (confirmed
	# against kas 5.4 source), so this is a real, common shape, not an edge
	# case.
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell -k meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'shell'
	printf '%s\n' "$out" | grep -qxF -- '-k'
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml:meta-angstrom/kas/macos-local.yml'
}

@test "kas-container wrapper: multiple recognized boolean flags before <files> all survive, in order" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container build --force-checkout -k meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	tail="$(printf '%s\n' "$out" | tail -4)"
	[ "$tail" = "$(printf 'build\n--force-checkout\n-k\nmeta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml')" ]
}

@test "kas-container wrapper: --skip STEP (a value-taking flag) before <files> still finds <files>" {
	# --skip STEP is a real kas option (kas/libkas.py setup_parser_common_args)
	# that takes a separate value -- naively treating that value as <files>
	# would splice the fragment into the wrong token, so the wrapper consumes
	# the flag AND its value as one unit before continuing to scan.
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container build --skip repos_checkout meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF -- '--skip'
	printf '%s\n' "$out" | grep -qxF 'repos_checkout'
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml'
}

@test "kas-container wrapper: the exact reported case -- multiple --skip STEP pairs (the -k alternative) before <files>" {
	# The real-world sequence recommended as a repo-state-preserving
	# alternative to -k (README): every step -k bundles, skipped individually,
	# EXCEPT write_bbconfig -- so local.conf regenerates without touching any
	# checkout. Confirmed live to have silently failed to auto-append before
	# this fix (each --skip's value token was mistaken for <files>, so the
	# wrapper backed off every time).
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container shell --skip setup_dir --skip finish_setup_repos --skip repos_checkout --skip repos_apply_patches meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml:meta-angstrom/kas/macos-local.yml'
}

@test "kas-container wrapper: --skip=value (single-token form) before <files> still finds <files>" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container build --skip=repos_checkout meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF -- '--skip=repos_checkout'
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml:meta-angstrom/kas/macos-local.yml'
}

@test "kas-container wrapper: a truly unrecognized flag before <files> backs off untouched" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && /bin/bash -c '. "$1" >/dev/null 2>&1; kas-container build --totally-unknown-flag meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	printf '%s\n' "$out" | grep -qxF 'meta-angstrom/kas/base.yml'
	! printf '%s\n' "$out" | grep -q 'macos-local.yml'
}

@test "env.sh: valid bash 3.2 and zsh with a project and the auto-fragment wrapper generated" {
	with_project_fragment
	write_env_sh
	/bin/bash -n "$MACKAS_ENV_SH"
	/bin/zsh -n "$MACKAS_ENV_SH"
}

# ---------------------------------------------------------------------------
# env.sh -- the wrapper deriving MACKAS_PROJECT_DIR/MACKAS_KAS_CONFIG
#
# Driving kas by hand sets neither, so bitbake_getvar() refuses outright and
# everything built on it (retrieve, buildstats analyze's SVG rendering) either
# fails or silently falls back to OE-core default paths a distro has
# redefined. Hit repeatedly live. The file list already names the checkout, so
# there is nothing to ask the user for -- derive it and export into THIS shell.
# ---------------------------------------------------------------------------

# derived VAR ARGS... -- run the wrapper in a clean child shell from CWD_VAR
# and print one exported variable's value afterwards.
derived() {
	local var="$1" cwd="$2"; shift 2
	(cd "$cwd" && /bin/bash -c '
		. "$1" >/dev/null 2>&1
		var="$2"; shift 2
		kas-container "$@" >/dev/null 2>&1
		eval "printf %s \"\${$var:-}\""
	' _ "$MACKAS_ENV_SH" "$var" "$@")
}

@test "derive: from work/, a single-layer chain sets PROJECT_DIR and a checkout-relative KAS_CONFIG" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	[ "$(derived MACKAS_PROJECT_DIR "$MACKAS_WORK" shell meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml)" = "meta-angstrom" ]
	# The leading checkout component is stripped from EVERY entry: that is the
	# form compose_kas_files() expects, because run_kas() cd's into the checkout.
	[ "$(derived MACKAS_KAS_CONFIG "$MACKAS_WORK" shell meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/beaglebone.yml)" = "kas/angstrom.yml:kas/beaglebone.yml" ]
}

@test "derive: the appended macos-local.yml never lands in the derived KAS_CONFIG" {
	# compose_kas_files() appends the fragment itself; a doubled entry is a kas
	# parse error, so derivation has to happen BEFORE the auto-append.
	with_project_fragment
	write_env_sh
	fake_kas_container
	got="$(derived MACKAS_KAS_CONFIG "$MACKAS_WORK" shell meta-angstrom/kas/base.yml)"
	[ "$got" = "kas/base.yml" ]
}

@test "derive: works from inside the checkout, where entries are already relative" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	[ "$(derived MACKAS_PROJECT_DIR "$MACKAS_PROJECT" shell kas/base.yml)" = "meta-angstrom" ]
	[ "$(derived MACKAS_KAS_CONFIG "$MACKAS_PROJECT" shell kas/base.yml)" = "kas/base.yml" ]
}

@test "derive: a chain spanning SIBLING layers derives NOTHING, rather than something that resolves wrong" {
	# mackas commands cd INTO the checkout, so a sibling layer would sit
	# outside the /repo mount -- there is no checkout-relative form of
	# meta-ti/... when the checkout is meta-angstrom. Deriving half of it
	# would produce a config that parses and then resolves to the wrong tree.
	with_project_fragment
	mkdir -p "$MACKAS_WORK/meta-ti/kas"
	write_env_sh
	fake_kas_container
	[ -z "$(derived MACKAS_PROJECT_DIR "$MACKAS_WORK" shell meta-angstrom/kas/a.yml:meta-ti/kas/machine.yml)" ]
	[ -z "$(derived MACKAS_KAS_CONFIG "$MACKAS_WORK" shell meta-angstrom/kas/a.yml:meta-ti/kas/machine.yml)" ]
}

@test "derive: still fires when NO project is configured (the case it exists for)" {
	# MACKAS_PROJECT_DIR empty => no fragment installed => the auto-append is
	# skipped. Derivation must NOT be skipped with it: this is precisely the
	# state that made bitbake_getvar refuse.
	derive_paths
	mkdir -p "$MACKAS_WORK/meta-angstrom/kas"
	write_env_sh
	fake_kas_container
	[ "$(derived MACKAS_PROJECT_DIR "$MACKAS_WORK" shell meta-angstrom/kas/base.yml)" = "meta-angstrom" ]
}

@test "derive: never overrides a value already set in the environment" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	got="$(cd "$MACKAS_WORK" && MACKAS_PROJECT_DIR=mine MACKAS_KAS_CONFIG=kas/mine.yml /bin/bash -c '
		. "$1" >/dev/null 2>&1
		kas-container shell meta-angstrom/kas/base.yml >/dev/null 2>&1
		printf "%s|%s" "$MACKAS_PROJECT_DIR" "$MACKAS_KAS_CONFIG"' _ "$MACKAS_ENV_SH")"
	[ "$got" = "mine|kas/mine.yml" ]
}

@test "derive: MACKAS_KAS_AUTO_PROJECT=0 set BEFORE sourcing env.sh disables it" {
	# env.sh must not clobber a value the shell already exported -- the ':-'
	# guard, same shape GITCONFIG_FILE already uses in that file.
	with_project_fragment
	write_env_sh
	fake_kas_container
	got="$(cd "$MACKAS_WORK" && MACKAS_KAS_AUTO_PROJECT=0 /bin/bash -c '
		. "$1" >/dev/null 2>&1
		kas-container shell meta-angstrom/kas/base.yml >/dev/null 2>&1
		printf "%s" "${MACKAS_PROJECT_DIR:-}"' _ "$MACKAS_ENV_SH")"
	[ -z "$got" ]
}

@test "derive: MACKAS_KAS_AUTO_FRAGMENT=0 set BEFORE sourcing env.sh disables the append too" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	out="$(cd "$MACKAS_WORK" && MACKAS_KAS_AUTO_FRAGMENT=0 /bin/bash -c '
		. "$1" >/dev/null 2>&1
		kas-container shell meta-angstrom/kas/base.yml' _ "$MACKAS_ENV_SH")"
	! printf '%s\n' "$out" | grep -q 'macos-local.yml'
}

@test "derive: says what it did, once per shell, not on every call" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	err="$(cd "$MACKAS_WORK" && /bin/bash -c '
		. "$1" >/dev/null 2>&1
		kas-container shell meta-angstrom/kas/base.yml >/dev/null
		kas-container shell meta-angstrom/kas/base.yml >/dev/null
		kas-container shell meta-angstrom/kas/base.yml >/dev/null' _ "$MACKAS_ENV_SH" 2>&1 >/dev/null)"
	[ "$(printf '%s\n' "$err" | grep -c 'derived MACKAS_PROJECT_DIR=meta-angstrom')" -eq 1 ]
}

@test "derive: a non-kas cwd (neither work/ nor a checkout under it) derives nothing" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	mkdir -p "$TESTDIR/elsewhere"
	[ -z "$(derived MACKAS_PROJECT_DIR "$TESTDIR/elsewhere" shell meta-angstrom/kas/base.yml)" ]
}

@test "derive: zsh sourcing env.sh derives the same values as bash" {
	with_project_fragment
	write_env_sh
	fake_kas_container
	got="$(cd "$MACKAS_WORK" && /bin/zsh -c '
		. "$1" >/dev/null 2>&1
		kas-container shell meta-angstrom/kas/angstrom.yml >/dev/null 2>&1
		printf "%s|%s" "$MACKAS_PROJECT_DIR" "$MACKAS_KAS_CONFIG"' _ "$MACKAS_ENV_SH")"
	[ "$got" = "meta-angstrom|kas/angstrom.yml" ]
}

# ---------------------------------------------------------------------------
# gitconfig -- the git "dubious ownership" workaround (THE blocker)
# ---------------------------------------------------------------------------

write_gitconfig() {
	setup_gitconfig >/dev/null 2>&1
}

@test "gitconfig: setup writes safe.directory = * under [safe]" {
	unset GITCONFIG_FILE
	write_gitconfig
	[ -f "$MACKAS_GITCONFIG" ]
	grep -qxF '[safe]' "$MACKAS_GITCONFIG"
	grep -qE '^[[:space:]]*directory[[:space:]]*=[[:space:]]*\*[[:space:]]*$' "$MACKAS_GITCONFIG"
}

@test "gitconfig: setup is idempotent (re-running does not error or duplicate)" {
	unset GITCONFIG_FILE
	write_gitconfig
	write_gitconfig
	[ "$(grep -c '^\[safe\]$' "$MACKAS_GITCONFIG")" = "1" ]
}

@test "gitconfig: a GITCONFIG_FILE already set in the environment is NEVER overwritten" {
	local mine="$TESTDIR/mine.gitconfig"
	printf '[user]\n\tname = someone\n' > "$mine"
	GITCONFIG_FILE="$mine" setup_gitconfig >/dev/null 2>&1
	# Untouched: still exactly what we wrote, no [safe] section added.
	[ "$(cat "$mine")" = "$(printf '[user]\n\tname = someone\n')" ]
	! grep -q '\[safe\]' "$mine"
	# And mackas' own generated one must not have been created either --
	# the user's file is authoritative, full stop.
	[ ! -e "$MACKAS_GITCONFIG" ]
}

@test "gitconfig: setup does not fail or warn when the user's own GITCONFIG_FILE already has safe.directory" {
	local mine="$TESTDIR/mine.gitconfig"
	printf '[safe]\n\tdirectory = *\n' > "$mine"
	out="$(GITCONFIG_FILE="$mine" setup_gitconfig 2>&1)"
	printf '%s\n' "$out" | grep -qi 'already'
	! printf '%s\n' "$out" | grep -qi 'warn'
}

@test "gitconfig: accepting the offer appends safe.directory to an incomplete GITCONFIG_FILE" {
	local mine="$TESTDIR/mine.gitconfig"
	printf '[user]\n\tname = someone\n' > "$mine"
	ASSUME_YES=1
	out="$(GITCONFIG_FILE="$mine" setup_gitconfig 2>&1)"
	printf '%s\n' "$out" | grep -qi 'appended'
	# The user's own content survives, untouched, alongside the addition.
	grep -qF 'name = someone' "$mine"
	grep -qxF '[safe]' "$mine"
	grep -qE '^[[:space:]]*directory[[:space:]]*=[[:space:]]*\*[[:space:]]*$' "$mine"
}

@test "gitconfig: declining the offer leaves an incomplete GITCONFIG_FILE exactly as-is" {
	local mine="$TESTDIR/mine.gitconfig"
	printf '[user]\n\tname = someone\n' > "$mine"
	ASSUME_YES=0
	out="$(GITCONFIG_FILE="$mine" setup_gitconfig 2>&1)"
	[ "$(cat "$mine")" = "$(printf '[user]\n\tname = someone\n')" ]
	printf '%s\n' "$out" | grep -qi 'by hand'
}

@test "gitconfig: accepting the offer creates a GITCONFIG_FILE that names a path with nothing there yet" {
	local mine="$TESTDIR/does-not-exist-yet/mine.gitconfig"
	ASSUME_YES=1
	out="$(GITCONFIG_FILE="$mine" setup_gitconfig 2>&1)"
	[ -f "$mine" ]
	grep -qxF '[safe]' "$mine"
	printf '%s\n' "$out" | grep -qi "wrote $mine"
}

@test "gitconfig: declining to create a missing GITCONFIG_FILE leaves nothing on disk" {
	local mine="$TESTDIR/does-not-exist-yet/mine.gitconfig"
	ASSUME_YES=0
	GITCONFIG_FILE="$mine" setup_gitconfig >/dev/null 2>&1
	[ ! -e "$mine" ]
}

@test "run_kas: refuses before ever reaching kas-container when the resolved gitconfig is missing" {
	local okkas="$TESTDIR/okkas"
	printf '#!/bin/bash\ntouch %s/KAS_RAN\nexit 0\n' "$TESTDIR" > "$okkas"; chmod +x "$okkas"
	MACKAS_PROJECT="$TESTDIR"; MACKAS_WORK="$TESTDIR"; SHIM_DIR="$TESTDIR"
	KAS_CONTAINER_BIN="$okkas"; KAS_IMAGE="img"
	MACKAS_GITCONFIG="$TESTDIR/no-such-gitconfig"; GITCONFIG_FILE=""
	kas_runtime_args() { echo "-c 2"; }
	out="$( (run_kas "" build foo) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'missing or incomplete'
	[ ! -e "$TESTDIR/KAS_RAN" ]
}

@test "run_kas: refuses when the resolved gitconfig exists but lacks safe.directory" {
	local badconf="$TESTDIR/incomplete.gitconfig"
	printf '[user]\n\tname = someone\n' > "$badconf"
	local okkas="$TESTDIR/okkas"
	printf '#!/bin/bash\ntouch %s/KAS_RAN\nexit 0\n' "$TESTDIR" > "$okkas"; chmod +x "$okkas"
	MACKAS_PROJECT="$TESTDIR"; MACKAS_WORK="$TESTDIR"; SHIM_DIR="$TESTDIR"
	KAS_CONTAINER_BIN="$okkas"; KAS_IMAGE="img"
	MACKAS_GITCONFIG="$badconf"; GITCONFIG_FILE=""
	kas_runtime_args() { echo "-c 2"; }
	out="$( (run_kas "" build foo) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'missing or incomplete'
	[ ! -e "$TESTDIR/KAS_RAN" ]
}

@test "gitconfig: check_gitconfig reports missing vs present without writing anything" {
	# check_gitconfig() called directly (function-level, MACKAS_LIB_ONLY=1),
	# NOT via 'mackas check': cmd_check() also runs check_container_runtime(),
	# which boots a real throwaway container against the actual Apple
	# container runtime -- exactly the real-infra dependency this suite must
	# not have (see run-tests.sh's header comment). This still proves
	# check_gitconfig() is wired up and side-effect-free on its own.
	unset GITCONFIG_FILE
	out="$(check_gitconfig 2>&1)"
	printf '%s\n' "$out" | grep -qi "dubious ownership"
	printf '%s\n' "$out" | grep -qF "gitconfig not written yet -> $MACKAS_GITCONFIG"
	[ ! -e "$MACKAS_GITCONFIG" ]

	write_gitconfig
	out="$(check_gitconfig 2>&1)"
	printf '%s\n' "$out" | grep -qF "gitconfig present: $MACKAS_GITCONFIG (safe.directory = *)"
}

# ---------------------------------------------------------------------------
# The kas fragment's disk monitor
# ---------------------------------------------------------------------------

@test "fragment: BB_DISKMON_DIRS HALTs on all three volumes" {
	# The volume caps protect the SSD (and Time Machine's free space); this
	# protects the build from a full volume, which is a different failure.
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	printf '%s\n' "$out" | grep -q 'BB_DISKMON_DIRS'
	printf '%s\n' "$out" | grep -qF 'HALT,${TMPDIR},2G,100K'
	printf '%s\n' "$out" | grep -qF 'HALT,${DL_DIR},2G,100K'
	printf '%s\n' "$out" | grep -qF 'HALT,${SSTATE_DIR},2G,100K'
}

@test "fragment: the diskmon stanza sits inside local_conf_header" {
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	printf '%s\n' "$out" | grep -q '^  macos-diskmon: |$'
	printf '%s\n' "$out" | grep -q '^    BB_DISKMON_DIRS '
}

@test "fragment: BB_DISKMON_DIRS is a well-formed multi-line shell continuation on disk (regression: shipped mangled)" {
	# A real bug that shipped past a green suite: an unquoted heredoc splices
	# away a literal "\" immediately before a real newline -- even one
	# produced by unescaping a typed "\\" -- so the naive way to write this
	# collapsed the whole value onto ONE line: a single "\" followed by a run
	# of spaces where each newline used to be. grep -F alone does not catch
	# this, because every substring it looks for still "appears" -- just
	# concatenated onto the wrong line. Assert each physical line EXACTLY
	# (grep -x), which a collapsed single line cannot satisfy no matter how
	# the substrings are arranged within it.
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	printf '%s\n' "$out" | grep -qxF '    BB_DISKMON_DIRS ??= "\'
	printf '%s\n' "$out" | grep -qxF '      HALT,${TMPDIR},2G,100K \'
	printf '%s\n' "$out" | grep -qxF '      HALT,${DL_DIR},2G,100K \'
	printf '%s\n' "$out" | grep -qxF '      HALT,${SSTATE_DIR},2G,100K"'
	# And the whole thing must NOT be squeezed onto one line: that line would
	# contain both 'BB_DISKMON_DIRS' and the LAST HALT clause together, which
	# never happens in the well-formed, four-line form asserted above.
	! printf '%s\n' "$out" | grep -qF 'BB_DISKMON_DIRS ??= "        HALT,'
}

@test "fragment: \${TMPDIR}/\${DL_DIR}/\${SSTATE_DIR} reach the HALT lines LITERALLY, never shell-expanded" {
	# macOS always has a real $TMPDIR in the environment (something under
	# /var/folders/.../T/), so if the generator ever let bash expand it
	# instead of keeping it a literal bitbake variable reference, this would
	# silently substitute the invoking user's own temp dir into the fragment
	# instead of failing loudly.
	#
	# Scoped to the HALT lines specifically (not "the whole file"): the
	# fragment's own header comment legitimately contains
	# MACKAS_KAS_FRAGMENT_SRC, a real host path that -- in a test running
	# under a temp MACKAS_ROOT -- usually sits under the real $TMPDIR too, so
	# a whole-file check would false-positive on that unrelated comment.
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	halt_lines="$(printf '%s\n' "$out" | grep 'HALT,')"
	printf '%s\n' "$halt_lines" | grep -qF '${TMPDIR}'
	printf '%s\n' "$halt_lines" | grep -qF '${DL_DIR}'
	printf '%s\n' "$halt_lines" | grep -qF '${SSTATE_DIR}'
	if [ -n "${TMPDIR:-}" ]; then
		! printf '%s\n' "$halt_lines" | grep -qF "$TMPDIR"
	fi
}

@test "fragment: sets BB_HASHSERVE_DB_DIR to the shared sstate volume, not the per-build TMPDIR" {
	# The warning bitbake actually emitted on a real successful parse: the
	# hash-equivalence database defaults into the per-build /build volume,
	# which 'mackas clean' throws away -- discarding sstate reuse on every
	# clean, not just TMPDIR, unless this is pointed at the volume that
	# survives a clean.
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	printf '%s\n' "$out" | grep -qxF '    BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"'
}

@test "fragment: the hashserve stanza sits inside local_conf_header, alongside diskmon" {
	setup_kas_fragment >/dev/null
	out="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"
	printf '%s\n' "$out" | grep -q '^  macos-hashserve: |$'
}

# ---------------------------------------------------------------------------
# Sizes are real settings
# ---------------------------------------------------------------------------

@test "sizes: the three volume sizes are settings and total the approved 200G" {
	is_setting_name MACKAS_VOLUME_SIZE_TMP
	is_setting_name MACKAS_VOLUME_SIZE_DL
	is_setting_name MACKAS_VOLUME_SIZE_SSTATE
	[ "$(total_volume_gb)" = "200" ]
}

@test "sizes: total_volume_gb follows the settings" {
	MACKAS_VOLUME_SIZE_TMP=10G
	MACKAS_VOLUME_SIZE_DL=5G
	MACKAS_VOLUME_SIZE_SSTATE=1G
	[ "$(total_volume_gb)" = "16" ]
}

# ---------------------------------------------------------------------------
# volume_in_use must fail CLOSED
#
# `buildstats` attaches the TMPDIR volume to copy files out, and refuses if
# volume_in_use says a build still holds it. If the query that answers that
# question FAILS, the old code read the failure as "not in use" (fail OPEN)
# and let the attach proceed -- exactly the second-attach the guard exists to
# prevent. On any query failure it must instead report the volume as in use.
# ---------------------------------------------------------------------------

@test "volume_in_use: fails CLOSED when 'container ls' errors" {
	# Runtime is up, but listing the running containers fails.
	container() {
		case "${1:-}" in
			system)  echo "status running"; return 0 ;;
			ls)      return 1 ;;
			*)       return 0 ;;
		esac
	}
	# A failing query must read as in-use (return 0), not free.
	if volume_in_use oe-build-tmp; then :; else
		printf 'volume_in_use returned "not in use" on a failing ls (fail-OPEN)\n' >&2
		return 1
	fi
}

@test "volume_in_use: fails CLOSED when 'container inspect' errors" {
	container() {
		case "${1:-}" in
			system)  echo "status running"; return 0 ;;
			ls)      printf 'ID\nabc123\n'; return 0 ;;
			inspect) return 1 ;;
			*)       return 0 ;;
		esac
	}
	if volume_in_use oe-build-tmp; then :; else
		printf 'volume_in_use returned "not in use" on a failing inspect (fail-OPEN)\n' >&2
		return 1
	fi
}

@test "volume_in_use: reports NOT in use when the runtime answers and nothing holds it" {
	# The fail-closed change must not swing the other way and jam on every call.
	container() {
		case "${1:-}" in
			system)  echo "status running"; return 0 ;;
			ls)      printf 'ID\n'; return 0 ;;
			*)       return 0 ;;
		esac
	}
	if volume_in_use oe-build-tmp; then
		printf 'volume_in_use claimed in-use with an empty, successful listing\n' >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# volume_in_use must match the MOUNT NAME, not a bare substring of the JSON.
#
# It used to `grep -qF "$name"` over the whole `container inspect` output, so a
# volume whose name appeared ANYWHERE -- most damningly inside the running
# container's image reference -- read as "in use". A volume literally named
# "kas" matched ghcr.io/siemens/kas/kas:5.4 in every running kas container, so
# `buildstats` refused to attach a volume nothing actually held. The query is
# now anchored to the mount block's  "name" : "<volume>"  key.
# ---------------------------------------------------------------------------

# A running container whose IMAGE reference contains "kas", but whose only
# mounted volume is oe-build-tmp. Shared by the two tests below.
in_use_inspect_double() {
	container() {
		case "${1:-}" in
			system) echo "status running"; return 0 ;;
			ls)     printf 'ID\nabc123\n'; return 0 ;;
			inspect)
				cat <<'JSON'
{
  "configuration" : {
    "image" : { "reference" : "ghcr.io/siemens/kas/kas:5.4" }
  },
  "mounts" : [
    { "type" : "volume", "source" : "oe-build-tmp", "name" : "oe-build-tmp", "destination" : "/build" }
  ]
}
JSON
				return 0 ;;
			*) return 0 ;;
		esac
	}
}

@test "volume_in_use: a name that is only a substring of a running image is NOT in use" {
	in_use_inspect_double
	# 'kas' is in the image reference but is not a mounted volume, so a volume
	# named 'kas' must read as free. The old grep -qF matched the image and
	# reported it in use.
	assert_fails volume_in_use kas
}

@test "volume_in_use: a volume that IS mounted reads as in use" {
	# The anchored match must still fire for the real mount, or the guard would
	# swing the other way and never protect anything.
	in_use_inspect_double
	volume_in_use oe-build-tmp
}

# ---------------------------------------------------------------------------
# auto_fstrim -- MACKAS_FSTRIM_AUTO reclaims the images around every kas run.
# Unit-tested with volume_fstrim_one / volume_exists replaced by doubles, so
# no container ever runs.
# ---------------------------------------------------------------------------

# Redefine the two helpers auto_fstrim leans on. CALLS records each fstrim.
auto_fstrim_doubles() {
	CALLS="$TESTDIR/fstrim.calls"; : > "$CALLS"
	MACKAS_VOL_TMP="v-tmp"; MACKAS_VOL_DL="v-dl"; MACKAS_VOL_SSTATE="v-sstate"
	volume_exists() { return 0; }                       # all three exist
	volume_fstrim_one() { printf '%s\n' "$1" >> "$CALLS"; return "${MOCK_RC:-0}"; }
}

@test "auto_fstrim: default-on trims all three volumes, before and after" {
	auto_fstrim_doubles
	auto_fstrim before "" >/dev/null
	auto_fstrim after "" >/dev/null
	# 3 volumes x 2 phases = 6 trims, and each volume by name.
	[ "$(grep -c . "$CALLS")" -eq 6 ]
	[ "$(grep -c '^v-tmp$' "$CALLS")" -eq 2 ]
	[ "$(grep -c '^v-sstate$' "$CALLS")" -eq 2 ]
}

@test "auto_fstrim: MACKAS_FSTRIM_AUTO=0 disables it entirely" {
	auto_fstrim_doubles
	MACKAS_FSTRIM_AUTO=0
	auto_fstrim before "" >/dev/null
	[ ! -s "$CALLS" ]
}

@test "auto_fstrim: every trim is guarded so a failure never fails the build" {
	# The non-fatal guard is a `set -e` property, and bats disables set -e in
	# tests, so it cannot be triggered behaviourally here (a masked `|| true`
	# stays green). Pin it at the source instead, the way the suite pins other
	# set -e-sensitive lines: BOTH branches -- logged and console -- must wrap
	# the trim in `|| true` so a failing fstrim can never abort a running build.
	grep -qF 'volume_fstrim_one "$v" 1 >>"$log" 2>&1 || true' "$MACKAS"
	grep -qF 'volume_fstrim_one "$v" 1 || true' "$MACKAS"
	# Functionally: with every trim failing, it still attempts all three.
	auto_fstrim_doubles
	MOCK_RC=1
	auto_fstrim before "" >/dev/null 2>&1 || true
	[ "$(grep -c . "$CALLS")" -eq 3 ]
}

@test "auto_fstrim: skips a volume that does not exist yet" {
	auto_fstrim_doubles
	volume_exists() { [ "$1" != "v-dl" ]; }   # dl not created yet
	auto_fstrim before "" >/dev/null
	[ "$(grep -c '^v-dl$' "$CALLS")" -eq 0 ]
	[ "$(grep -c '^v-tmp$' "$CALLS")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# clear_buildstats_before_build -- MACKAS_BUILDSTATS_ACCUMULATE gates clearing
# tmp/buildstats before every kas run (buildstats.bbclass never resets it
# itself -- see check_buildstats_accumulation for the same symptom caught
# after the fact). Unit-tested with volume_exists/container replaced by
# doubles, so no container ever runs.
# ---------------------------------------------------------------------------

clear_buildstats_doubles() {
	CALLS="$TESTDIR/clearbs.calls"; : > "$CALLS"
	MACKAS_VOL_TMP="v-tmp"
	volume_exists() { return 0; }
	container() { printf '%s\n' "$*" >> "$CALLS"; return "${MOCK_RC:-0}"; }
}

@test "clear_buildstats_before_build: default on -- clears tmp/buildstats before a build" {
	clear_buildstats_doubles
	clear_buildstats_before_build ""
	[ "$(grep -c . "$CALLS")" -eq 1 ]
	grep -qF 'rm -rf /build/tmp/buildstats' "$CALLS"
}

@test "clear_buildstats_before_build: MACKAS_BUILDSTATS_ACCUMULATE=1 disables it entirely" {
	clear_buildstats_doubles
	MACKAS_BUILDSTATS_ACCUMULATE=1
	clear_buildstats_before_build ""
	[ ! -s "$CALLS" ]
}

@test "clear_buildstats_before_build: skips when the TMPDIR volume does not exist yet" {
	clear_buildstats_doubles
	volume_exists() { return 1; }
	clear_buildstats_before_build ""
	[ ! -s "$CALLS" ]
}

@test "clear_buildstats_before_build: a failure is swallowed, never fails the build" {
	# Pin the `|| true` at the source (same reasoning as auto_fstrim's own
	# guard) -- bats disables set -e, so a masked failure cannot be triggered
	# behaviourally here.
	grep -qF 'rm -rf /build/tmp/buildstats >>"$log" 2>&1 || true' "$MACKAS"
	grep -qF 'rm -rf /build/tmp/buildstats || true' "$MACKAS"
	clear_buildstats_doubles
	MOCK_RC=1
	clear_buildstats_before_build ""
}

@test "run_kas: captures kas's exit in a tested context so the after-trim is reached" {
	# `cmd_shell` runs run_kas bare under `set -e`. A bare `( _kas_exec ); rc=$?`
	# lets errexit abort run_kas the instant kas exits non-zero -- before rc is
	# read AND before the after-trim -- so a failed `shell`/`build` would skip
	# the after-trim. The `|| rc=$?` form keeps errexit from firing. This is a
	# `set -e` property that bats' harness cannot trigger behaviourally (the
	# outer tested context disables errexit throughout the call), so pin the
	# idiom at the source, the way the suite pins the auto_fstrim `|| true`s.
	grep -qF '( _kas_exec "$@" ) || rc=$?' "$MACKAS"
	grep -qF '( _kas_exec "$@" ) 2>&1 | tee -a "$log" || rc=$?'  "$MACKAS"
	! grep -qF '( _kas_exec "$@" ); rc=$?' "$MACKAS"

	# And behaviourally, the happy path: both trims run and rc is 0.
	local okkas="$TESTDIR/okkas"
	printf '#!/bin/bash\nexit 0\n' > "$okkas"; chmod +x "$okkas"
	printf '[safe]\n\tdirectory = *\n' > "$TESTDIR/gitconfig"
	MACKAS_PROJECT="$TESTDIR"; MACKAS_WORK="$TESTDIR"; SHIM_DIR="$TESTDIR"
	KAS_CONTAINER_BIN="$okkas"; KAS_IMAGE="img"; MACKAS_GITCONFIG="$TESTDIR/gitconfig"; GITCONFIG_FILE=""
	PHASES="$TESTDIR/phases"; : > "$PHASES"
	auto_fstrim() { echo "$1" >> "$PHASES"; }
	kas_runtime_args() { echo "-c 2"; }
	rc=0; run_kas "" build foo >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ]
	[ "$(tr '\n' ' ' < "$PHASES")" = "before after " ]
}

# ---------------------------------------------------------------------------
# setup_relocate_volumes forward path. The destroy-side inverse is pinned in
# volumes_cmd.bats (A1); this pins the setup-side move -- specifically that a
# per-volume symlink a prior `volume move` left in the container volumes dir is
# preserved AS a symlink when setup rsyncs the dir onto MACKAS_ROOT. rsync -a
# implies -l (copy links as links); without it the symlink would be
# dereferenced and the moved volume clobbered -- move and setup would fight.
# ---------------------------------------------------------------------------

@test "setup relocate: the forward move preserves a per-volume symlink" {
	src="$TESTDIR/cvd"
	dest_root="$TESTDIR/relroot"
	CONTAINER_VOLUMES_DIR="$src"
	MACKAS_ROOT="$dest_root"
	MACKAS_RELOCATE_VOLUMES=1
	ASSUME_YES=1
	DRY_RUN=0

	# A normal volume dir, plus a per-volume symlink pointing off elsewhere,
	# exactly as `volume move oe-build-dl <dir>` leaves behind.
	mkdir -p "$src/oe-build-tmp"; : > "$src/oe-build-tmp/volume.img"
	mkdir -p "$TESTDIR/elsewhere/oe-build-dl"; : > "$TESTDIR/elsewhere/oe-build-dl/volume.img"
	ln -s "$TESTDIR/elsewhere/oe-build-dl" "$src/oe-build-dl"

	setup_relocate_volumes >/dev/null 2>&1

	# The volumes dir is now a symlink onto MACKAS_ROOT/container-volumes.
	[ -L "$src" ]
	[ "$(readlink "$src")" = "$dest_root/container-volumes" ]
	# The normal volume's image travelled.
	[ -f "$dest_root/container-volumes/oe-build-tmp/volume.img" ]
	# The per-volume symlink is preserved AS A SYMLINK, still pointing off-tree,
	# NOT dereferenced into a copied directory.
	[ -L "$dest_root/container-volumes/oe-build-dl" ]
	[ "$(readlink "$dest_root/container-volumes/oe-build-dl")" = "$TESTDIR/elsewhere/oe-build-dl" ]
}

@test "setup relocate: a symlink to a DIFFERENT root's volumes is not silently treated as done" {
	# Apple's container has exactly ONE volumes directory for the whole
	# machine, not one per MACKAS_ROOT. A symlink left over from an earlier
	# setup against a DIFFERENT root used to be treated as "already a
	# symlink -> skip" with no comparison at all -- every volume this run
	# then created/used would silently live on that OTHER disk.
	other_root="$TESTDIR/other-root"
	this_root="$TESTDIR/this-root"
	link="$TESTDIR/cvd3"
	mkdir -p "$other_root/container-volumes/oe-build-tmp"
	: > "$other_root/container-volumes/oe-build-tmp/volume.img"
	ln -s "$other_root/container-volumes" "$link"

	CONTAINER_VOLUMES_DIR="$link"
	MACKAS_ROOT="$this_root"
	MACKAS_RELOCATE_VOLUMES=1
	ASSUME_YES=1
	DRY_RUN=0

	setup_relocate_volumes >/dev/null 2>&1

	# Re-pointed at THIS root's own container-volumes, not left alone.
	[ -L "$link" ]
	[ "$(readlink "$link")" = "$this_root/container-volumes" ]
	# The volume that lived at the old location travelled to the new one.
	[ -f "$this_root/container-volumes/oe-build-tmp/volume.img" ]
}

@test "setup relocate: declining to move a mismatched symlink leaves it exactly as-is" {
	other_root="$TESTDIR/other-root2"
	this_root="$TESTDIR/this-root2"
	link="$TESTDIR/cvd4"
	mkdir -p "$other_root/container-volumes/oe-build-tmp"
	: > "$other_root/container-volumes/oe-build-tmp/volume.img"
	ln -s "$other_root/container-volumes" "$link"

	CONTAINER_VOLUMES_DIR="$link"
	MACKAS_ROOT="$this_root"
	MACKAS_RELOCATE_VOLUMES=1
	ASSUME_YES=0
	DRY_RUN=0

	# confirm() declines non-interactively (no -y, not a terminal) -- exactly
	# the same "declining" path used everywhere else in the CLI.
	setup_relocate_volumes >/dev/null 2>&1

	[ -L "$link" ]
	[ "$(readlink "$link")" = "$other_root/container-volumes" ]
	[ ! -e "$this_root/container-volumes" ]
	[ -f "$other_root/container-volumes/oe-build-tmp/volume.img" ]
}

@test "setup relocate: a symlink target that no longer exists (a renamed volume) is just re-pointed, nothing to copy" {
	# The real-world case: the disk/volume got renamed. The data never moved
	# -- it is already sitting at $dest, reachable under the NEW MACKAS_ROOT
	# -- only the relocation symlink is stale. There is nothing to rsync;
	# this must not claim there is, and must not fail trying to read a
	# directory that no longer exists.
	this_root="$TESTDIR/renamed-root"
	link="$TESTDIR/cvd5"
	mkdir -p "$this_root/container-volumes/oe-build-tmp"
	: > "$this_root/container-volumes/oe-build-tmp/volume.img"
	ln -s "$TESTDIR/this-root-before-the-rename/container-volumes" "$link"

	CONTAINER_VOLUMES_DIR="$link"
	MACKAS_ROOT="$this_root"
	MACKAS_RELOCATE_VOLUMES=1
	ASSUME_YES=1
	DRY_RUN=0

	setup_relocate_volumes >/dev/null 2>&1

	[ -L "$link" ]
	[ "$(readlink "$link")" = "$this_root/container-volumes" ]
	# The pre-existing data (never touched, since nothing needed copying) is
	# still there, reachable through the freshly re-pointed symlink.
	[ -f "$this_root/container-volumes/oe-build-tmp/volume.img" ]
}

@test "setup relocate: with RELOCATE=0 it leaves the volumes dir untouched" {
	src="$TESTDIR/cvd2"
	CONTAINER_VOLUMES_DIR="$src"
	MACKAS_ROOT="$TESTDIR/relroot2"
	MACKAS_RELOCATE_VOLUMES=0
	ASSUME_YES=1
	DRY_RUN=0
	mkdir -p "$src/oe-build-tmp"; : > "$src/oe-build-tmp/volume.img"
	setup_relocate_volumes >/dev/null 2>&1
	# Untouched: still a plain directory, no symlink, nothing moved.
	[ -d "$src" ] && [ ! -L "$src" ]
	[ -f "$src/oe-build-tmp/volume.img" ]
	[ ! -e "$TESTDIR/relroot2/container-volumes" ]
}

# ---------------------------------------------------------------------------
# setup_kas_fragment install-into-checkout. The e2e test pins the happy path;
# these pin the edges: kas/ is created when the project ships none, the
# .git/info/exclude entry is added exactly once across repeated runs (the
# grep -qxF idempotence guard), and an un-cloned project warns rather than
# installing into thin air. kas only mounts files under the repo dir, so a
# silent install failure here breaks smoketest at a distance.
# ---------------------------------------------------------------------------

@test "setup_kas_fragment: creates kas/, installs the fragment, excludes it once" {
	mkdir -p "$MACKAS_PROJECT/.git/info"
	: > "$MACKAS_PROJECT/.git/info/exclude"
	[ ! -d "$MACKAS_PROJECT/kas" ]              # project ships no kas/ dir

	setup_kas_fragment >/dev/null 2>&1
	setup_kas_fragment >/dev/null 2>&1          # run twice -- must stay idempotent

	# Installed at kas/macos-local.yml under the checkout.
	[ -f "$MACKAS_KAS_FRAGMENT_REPO" ]
	[ "$(basename "$MACKAS_KAS_FRAGMENT_REPO")" = "macos-local.yml" ]
	# Exactly one exclude entry despite two runs.
	[ "$(grep -c '^kas/macos-local.yml$' "$MACKAS_PROJECT/.git/info/exclude")" -eq 1 ]
}

@test "setup_kas_fragment: warns when the project is not cloned yet" {
	rm -rf "$MACKAS_PROJECT"                    # no .git -> not a checkout
	out="$( (setup_kas_fragment) 2>&1 )" && rc=0 || rc=$?
	printf '%s\n' "$out" | grep -qi 'not cloned'
	# It must NOT have created a stray fragment under a non-existent checkout.
	[ ! -e "$MACKAS_KAS_FRAGMENT_REPO" ]
}
