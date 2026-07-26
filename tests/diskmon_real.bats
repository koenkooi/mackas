#!/usr/bin/env bats
#
# OPT-IN test that BB_DISKMON_DIRS' HALT action ACTUALLY FIRES -- the one
# safety backstop in mackas that had never been observed working.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKIPPED BY DEFAULT, exactly like real_runtime.bats and
# volume_resize_real.bats.
#
# WHAT WAS UNPROVEN
# -----------------
# `mackas setup` writes a kas fragment containing
#
#     BB_DISKMON_DIRS ??= "\
#       HALT,${TMPDIR},2G,100K \
#       HALT,${DL_DIR},2G,100K \
#       HALT,${SSTATE_DIR},2G,100K"
#
# tests/volumes.bats pins the exact bytes of that value on disk, and a real
# bitbake has been seen to ACCEPT it. Nothing had ever seen it FIRE. It guards
# the failure the whole three-volume design exists to prevent, so "the syntax
# parses" is not enough.
#
# It fires. What this suite observed, on a 3G volume filled 16 MiB at a time:
#
#   FILLER: round=12 avail=2147348480 inodes=196562
#   WARNING: The free space of /vol/tmp (/dev/vdc) is running low (1.984GB left)
#   WARNING: The free space of /vol/downloads (/dev/vdc) is running low (...)
#   WARNING: The free space of /vol/sstate (/dev/vdc) is running low (...)
#   ERROR: Immediately halt since the disk space monitor action is "HALT"!
#   NOTE: Sending SIGTERM to remaining 1 tasks
#   Summary: There were 3 ERROR messages, returning a non-zero exit code.
#
# 2147348480 is 135168 bytes under 2 GiB: it halted on the first heartbeat
# after the crossing, on all three monitored directories, and killed the
# running task. The inode arm halts the same way at "98.194K left".
#
# WHY IT NEEDS A RUNNING BUILD (read from bitbake 2.18 source, not assumed)
# ------------------------------------------------------------------------
# lib/bb/runqueue.py:1592 registers the monitor as a HeartbeatEvent handler
# and guards it with the runqueue state:
#
#     bb.event.register(self.dm_event_handler_name,
#                       lambda x, y: self.dm.check(self)
#                           if self.state in [RunQueueState.RUNNING,
#                                             RunQueueState.CLEAN_UP] else False,
#                       ('bb.event.HeartbeatEvent',), data=self.cfgData)
#
# and lib/bb/server/process.py fires HeartbeatEvent every BB_HEARTBEAT_EVENT
# seconds (default 1). So the check happens only while TASKS ARE EXECUTING --
# never at parse time, never from `bitbake -p`, never from a config dump. Any
# test of this therefore has to drive a real runqueue.
#
# lib/bb/monitordisk.py:205-231 is the check itself:
#
#     st = os.statvfs(path)
#     freeSpace = st.f_bavail * st.f_frsize
#     if minSpace and freeSpace < minSpace:
#         ... elif action == "HALT" and not self.checked[k]:
#                 logger.error('Immediately halt since the disk space monitor
#                               action is "HALT"!')
#                 rq.finish_runqueue(True)
#
# with the same shape again for st.f_favail against minInode. The numbers are
# REMAINING FREE space/inodes, not used, and `2G`/`100K` are parsed by
# convertGMK() as 2*1024^3 bytes and 100*1024 inodes.
#
# THE CONSTRUCTION
# ----------------
# A full build is hours, so this does not run one. It runs REAL bitbake (the
# checkout mackas already fetched -- same code, same version) against a
# ~30-line throwaway metadata tree, inside the kas image, with TMPDIR/DL_DIR/
# SSTATE_DIR pointed at a small throwaway zztest-* ext4 volume and with the
# BB_DISKMON_DIRS value LIFTED VERBATIM from mackas' own generator. One
# recipe, one long-running task, whose whole job is to consume the resource
# the monitor watches while the runqueue is RUNNING. The volume is pre-loaded
# with a fallocate'd reservation so only a couple of hundred MB has to be
# written for real.
#
# WHAT THIS PROVES / DOES NOT PROVE
# ---------------------------------
#   PROVES: the exact string mackas generates is understood by bitbake 2.18's
#   disk monitor as three HALT rules at 2 GiB / 100 K; that crossing the free
#   SPACE threshold during a running build halts it; that crossing the free
#   INODE threshold does too; and that the halt is attributable (the build
#   does not merely fail).
#
#   DOES NOT PROVE: anything about a real OE build's timing -- an OE task can
#   write far faster than the 1 s heartbeat, so a single task could still blow
#   through the 2 GiB margin between two checks. The margin, not the
#   mechanism, is what this suite cannot size. It also runs bitbake standalone
#   rather than under kas, so it says nothing about the fragment being COMPOSED
#   into a build (tests/volumes.bats and the smoketest ladder cover that half).
#
#   MACKAS_REAL_RUNTIME=1 bats tests/diskmon_real.bats
#
# HOST-SPECIFIC INPUTS -- all from the environment, none hardcoded:
#   MACKAS_REAL_BITBAKE_DIR  a bitbake checkout on the host, mounted read-only
#                            into the container. Default:
#                            ${MACKAS_ROOT:-$HOME/oe}/work/bitbake -- where
#                            kas puts it under a mackas root.
#   MACKAS_REAL_DISKMON_SIZE size of the throwaway volume. Default 3G. Must be
#                            comfortably larger than the space threshold in
#                            the generated value, or the tests skip.
#   MACKAS_RT_IMAGE          override the kas image (default: derived from
#                            mackas' pinned KAS_CONTAINER_VERSION).
#
# COST: roughly a minute of runtime and ~200 MB of transient host disk for the
# space test, plus ~1 minute for the inode test (~100k empty files, near-zero
# bytes). Both are swept in teardown().
#
# SAFETY (dev-Mac only, enforced here, same rules as the other _real suites):
#   * Runs only when MACKAS_REAL_RUNTIME=1 AND the runtime is up.
#   * REFUSES while any container holds an oe-build-* volume (one-VM rule).
#   * Only ever creates/attaches/removes volumes named zztest-*.
#   * The bitbake checkout is mounted :ro and PYTHONDONTWRITEBYTECODE=1, so a
#     run cannot write into the user's checkout.
#   * teardown() sweeps every zztest-* volume AND any container still holding
#     one, after each test, pass or fail.

bats_require_minimum_version 1.5.0

load helpers

VOLS_DIR="$HOME/Library/Application Support/com.apple.container/volumes"

# ---------------------------------------------------------------------------
# Runtime plumbing -- same shape as real_runtime.bats / volume_resize_real.bats.
# Duplicated on purpose: each opt-in suite carries its own guards so none of
# them can be defanged by an edit somewhere else.
# ---------------------------------------------------------------------------

rt_image() {
	if [ -n "${MACKAS_RT_IMAGE:-}" ]; then
		printf '%s' "$MACKAS_RT_IMAGE"
		return
	fi
	local ver
	ver="$(sed -n 's/^KAS_CONTAINER_VERSION="\([^"]*\)".*/\1/p' "$MACKAS" | head -1)"
	printf 'ghcr.io/siemens/kas/kas:%s' "$ver"
}

container_running() {
	container system status >/dev/null 2>&1 || return 1
	container system status 2>/dev/null \
		| awk '$1=="status" {print $2}' | grep -q '^running$'
}

# Fail CLOSED: anything we cannot determine counts as "in use".
oe_build_in_use() {
	container_running || return 1
	local listing ids id detail
	listing="$(container ls 2>/dev/null)" || return 0
	ids="$(printf '%s\n' "$listing" | awk 'NR>1 {print $1}')"
	for id in $ids; do
		[ -n "$id" ] || continue
		detail="$(container inspect "$id" 2>/dev/null)" || return 0
		if printf '%s\n' "$detail" \
			| grep -qE '"name"[[:space:]]*:[[:space:]]*"oe-build'; then
			return 0
		fi
	done
	return 1
}

rm_vol() {
	container volume rm "$1" >/dev/null 2>&1 \
		|| container volume delete "$1" >/dev/null 2>&1 || true
}

# Kill and remove any container still holding a zztest-* volume. A bitbake run
# here can be minutes long; an interrupted bats (^C, timeout) would otherwise
# strand the container holding an ext4 volume, which blocks later container
# creation and looks nothing like test fallout.
sweep_zztest_containers() {
	local listing ids id detail
	listing="$(container ls -a 2>/dev/null)" || return 0
	ids="$(printf '%s\n' "$listing" | awk 'NR>1 {print $1}')"
	for id in $ids; do
		[ -n "$id" ] || continue
		detail="$(container inspect "$id" 2>/dev/null)" || continue
		printf '%s\n' "$detail" \
			| grep -qE '"name"[[:space:]]*:[[:space:]]*"zztest-' || continue
		container kill "$id" >/dev/null 2>&1 || true
		container rm "$id" >/dev/null 2>&1 || true
	done
}

sweep_zztest() {
	local v
	container volume ls 2>/dev/null | awk 'NR>1 {print $1}' \
		| grep '^zztest-' | while IFS= read -r v; do
			[ -n "$v" ] && rm_vol "$v"
		done
	local l
	for l in "$VOLS_DIR"/zztest-*; do
		[ -e "$l" ] || [ -L "$l" ] || continue
		rm -rf "$l"
	done
}

# ---------------------------------------------------------------------------
# The value under test, taken from mackas rather than retyped
# ---------------------------------------------------------------------------

# The generated BB_DISKMON_DIRS stanza, dedented so it is a valid standalone
# bitbake .conf assignment. Generated by mackas' own setup_kas_fragment(), so
# a change to the action or the thresholds changes what these tests assert --
# there is no second copy of "2G" in this file.
generated_diskmon_block() {
	(
		MACKAS_LIB_ONLY=1
		export MACKAS_LIB_ONLY
		# shellcheck disable=SC1090
		. "$MACKAS"
		SCRIPT_DIR="$REPO_ROOT"
		setup_colors
		set_defaults
		MACKAS_ROOT="$1"
		MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
		derive_paths
		DRY_RUN=0
		setup_kas_fragment >/dev/null 2>&1 || exit 1
		# From the BB_DISKMON_DIRS line to the first line NOT ending in a
		# backslash continuation, with the YAML block indent stripped.
		awk '/BB_DISKMON_DIRS/ {f=1}
		     f {sub(/^[ \t]+/, ""); print; if ($0 !~ /\\$/) exit}' \
			"$MACKAS_KAS_FRAGMENT_SRC"
	)
}

# Field N (3 = space, 4 = inode) of the block's ${TMPDIR} clause, e.g. "2G".
diskmon_field() {
	printf '%s\n' "$1" | tr ' ' '\n' \
		| grep -F 'HALT,${TMPDIR},' | head -1 | cut -d, -f"$2"
}

# bitbake's convertGMK(), in shell: G/M/K are 1024-based, no suffix is bytes.
gmk_to_bytes() {
	local v="$1" n u
	n="${v%[gGmMkK]}"
	u="${v#"$n"}"
	case "$u" in
	g | G) printf '%s' "$((n * 1024 * 1024 * 1024))" ;;
	m | M) printf '%s' "$((n * 1024 * 1024))" ;;
	k | K) printf '%s' "$((n * 1024))" ;;
	*) printf '%s' "$v" ;;
	esac
}

# ---------------------------------------------------------------------------
# The throwaway bitbake metadata
# ---------------------------------------------------------------------------

# Write a complete, minimal bitbake metadata tree plus the in-container driver
# into $1 (a host directory, mounted read-only at /harness).
#
#   $1 harness dir      $2 the BB_DISKMON_DIRS block
#   $3 fill mode: space | inode | none
#   $4 floor: stop filling once free space (bytes) / free inodes falls to this
write_harness() {
	local dir="$1" block="$2" mode="$3" floor="$4"
	mkdir -p "$dir/meta/conf" "$dir/meta/classes" "$dir/meta/recipes"

	# bitbake inherits base.bbclass into every recipe unconditionally (see
	# lib/bb/parse/parse_py/BBHandler.py inherit()); with no such file the
	# whole configuration fails to parse. It does not have to CONTAIN
	# anything -- everything this test needs lives in the recipe.
	cat >"$dir/meta/classes/base.bbclass" <<-'BASE'
		# Deliberately empty. bitbake auto-inherits classes/base.bbclass for
		# every recipe, so the file must exist; nothing here needs it to do
		# anything.
	BASE

	# Deliberately tiny: no OE, no layers, no bblayers.conf. Everything the
	# recipe needs is here, so nothing about this test depends on OE metadata.
	cat >"$dir/meta/conf/bitbake.conf" <<-'CONF'
		# Throwaway config for the mackas BB_DISKMON_DIRS HALT test.
		VOLROOT = "/vol"
		TMPDIR = "${VOLROOT}/tmp"
		DL_DIR = "${VOLROOT}/downloads"
		SSTATE_DIR = "${VOLROOT}/sstate"

		CACHE = "${TMPDIR}/cache"
		STAMP = "${TMPDIR}/stamps/${PN}"
		STAMPCLEAN = "${TMPDIR}/stamps/${PN}-*"
		T = "${TMPDIR}/work/${PN}/temp"
		WORKDIR = "${TMPDIR}/work/${PN}"
		B = "${TMPDIR}/work/${PN}"

		THISDIR = "${@os.path.dirname(d.getVar('FILE'))}"
		COREBASE := "${@os.path.normpath(os.path.dirname(d.getVar('FILE')+'/../../'))}"
		BBFILES = "${COREBASE}/recipes/*.bb"
		PROVIDES = "${PN}"
		PN = "${@bb.parse.vars_from_file(d.getVar('FILE', False),d)[0]}"
		PF = "${PN}"
		export PATH

		# One task at a time and a 1 s heartbeat: the fastest the monitor can
		# possibly be polled, which is exactly what runqueue.py registers it on.
		BB_NUMBER_THREADS = "1"
		BB_HEARTBEAT_EVENT = "1"
		BB_BASEHASH_IGNORE_VARS = "TMPDIR TOPDIR VOLROOT FILE BB_CURRENTTASK BB_CURRENT_MC"
	CONF

	# The generated value, verbatim. printf '%s' so the backslashes and the
	# literal ${TMPDIR} reach the file untouched.
	printf '\n%s\n' "$block" >>"$dir/meta/conf/bitbake.conf"

	cat >>"$dir/meta/conf/bitbake.conf" <<-CONF

		FILL_MODE = "$mode"
		FILL_FLOOR = "$floor"
	CONF

	# One recipe, both tasks inline -- no bbclass, so nothing here depends on
	# bitbake's own test metadata or on an implicit base.bbclass inherit.
	cat >"$dir/meta/recipes/filler.bb" <<-'RECIPE'
		# The task the disk monitor has to interrupt. It consumes the resource
		# under test in small rounds with a sleep between them, so the 1 s
		# heartbeat gets many chances to see the threshold crossed WHILE the
		# runqueue is RUNNING -- the only state monitordisk.check() runs in.
		FILL_CHUNK ?= "16777216"
		FILL_FILES ?= "4000"
		FILL_TIMEOUT ?= "600"
		FILL_HOLD ?= "25"

		python do_fill() {
		    import os, time

		    path = d.getVar("TMPDIR")
		    mode = d.getVar("FILL_MODE")
		    floor = int(d.getVar("FILL_FLOOR"))
		    chunk = int(d.getVar("FILL_CHUNK"))
		    nfiles = int(d.getVar("FILL_FILES"))
		    deadline = time.time() + float(d.getVar("FILL_TIMEOUT"))
		    bb.utils.mkdirhier(path)

		    # Non-zero bytes: a run of zeros could in principle be optimised
		    # into a hole and never consume a block.
		    buf = b"\xa5" * chunk
		    rounds = 0
		    while mode != "none" and time.time() < deadline:
		        st = os.statvfs(path)
		        avail = st.f_bavail * st.f_frsize
		        inodes = st.f_favail
		        bb.plain("FILLER: round=%d avail=%d inodes=%d" % (rounds, avail, inodes))
		        if mode == "space":
		            if avail <= floor:
		                break
		            with open(os.path.join(path, "fill.%04d" % rounds), "wb") as f:
		                f.write(buf)
		                f.flush()
		                os.fsync(f.fileno())
		        else:
		            if inodes <= floor:
		                break
		            sub = os.path.join(path, "inodes.%04d" % rounds)
		            os.makedirs(sub, exist_ok=True)
		            for j in range(nfiles):
		                fd = os.open(os.path.join(sub, "f%06d" % j),
		                             os.O_CREAT | os.O_WRONLY, 0o600)
		                os.close(fd)
		        rounds += 1
		        time.sleep(0.4)

		    bb.plain("FILLER: stopped after %d rounds" % rounds)
		    # Stay in the runqueue a while longer. If HALT works, the worker is
		    # killed during this sleep and HOLD-EXPIRED never prints; if it does
		    # not, the build goes on to succeed and the test says so.
		    time.sleep(float(d.getVar("FILL_HOLD")))
		    bb.plain("FILLER: HOLD-EXPIRED")
		}

		python do_build() {
		    bb.plain("FILLER: BUILD-COMPLETED")
		}

		do_fill[nostamp] = "1"
		do_build[nostamp] = "1"
		# Without this, bitbake-worker unshares a network namespace before
		# every task (bin/bitbake-worker, bb.utils.disable_network). That is
		# an unrelated moving part, and a failure in it kills the task with no
		# log at all -- which would look exactly like the halt this suite is
		# trying to observe. Opt out; nothing here touches the network.
		do_fill[network] = "1"
		do_build[network] = "1"
		addtask fill
		addtask build after do_fill
	RECIPE

	# The in-container driver. Prints machine-readable markers so the bats side
	# never has to parse bitbake's progress output.
	cat >"$dir/run.sh" <<-'RUNSH'
		#!/bin/sh
		# Runs INSIDE the container. /vol is the throwaway ext4 volume,
		# /bitbake the host checkout (read-only), /harness this tree (read-only).
		set -u
		export HOME=/vol/home
		export PATH="/bitbake/bin:$PATH"
		export PYTHONPATH=/bitbake/lib
		export PYTHONDONTWRITEBYTECODE=1
		export BBPATH=/harness/meta
		mkdir -p /vol/build /vol/home /vol/tmp

		python3 - <<'PY'
		import os, sys
		st = os.statvfs("/vol/tmp")
		avail = st.f_bavail * st.f_frsize
		print("PRE: avail=%d inodes=%d total=%d" %
		      (avail, st.f_favail, st.f_blocks * st.f_frsize))

		need_space = int(os.environ["DM_MIN_SPACE"])
		need_inode = int(os.environ["DM_MIN_INODE"])
		# Refuse to pretend: if the volume starts BELOW a threshold the monitor
		# would fire on the first heartbeat for a reason that has nothing to do
		# with what the test is driving, so the result would be unattributable.
		if avail <= need_space:
		    print("HARNESS-SKIP: volume free space %d is already under the %d threshold"
		          % (avail, need_space))
		    sys.exit(3)
		if st.f_favail <= need_inode:
		    print("HARNESS-SKIP: volume free inodes %d is already under the %d threshold"
		          % (st.f_favail, need_inode))
		    sys.exit(3)

		# Reserve most of the headroom with fallocate rather than by writing:
		# ext4 counts the blocks as used (so f_bavail drops, which is what the
		# monitor reads) while the sparse host image stays small. This is what
		# keeps the test cheap.
		reserve = int(os.environ.get("DM_RESERVE_TO", "0"))
		if reserve > 0 and avail > reserve:
		    n = avail - reserve
		    fd = os.open("/vol/reserve.img", os.O_CREAT | os.O_WRONLY, 0o600)
		    try:
		        os.posix_fallocate(fd, 0, n)
		    finally:
		        os.close(fd)
		    st = os.statvfs("/vol/tmp")
		    print("RESERVED: %d bytes, avail now %d" % (n, st.f_bavail * st.f_frsize))
		PY
		rc=$?
		if [ "$rc" -ne 0 ]; then
			echo "SETUP_RC=$rc"
			exit "$rc"
		fi

		cd /vol/build || exit 1
		python3 /bitbake/bin/bitbake filler
		rc=$?
		echo "BITBAKE_RC=$rc"
		exit "$rc"
	RUNSH
}

# ---------------------------------------------------------------------------
# Driving one run
# ---------------------------------------------------------------------------

VOL_NAME="zztest-diskmon"

make_vol() {
	container volume create -s "${MACKAS_REAL_DISKMON_SIZE:-3G}" "$1" >/dev/null
}

# run_diskmon MODE FLOOR RESERVE_TO -- one container, one bitbake run.
# Sets $output/$status via bats' `run`.
run_diskmon() {
	local mode="$1" floor="$2" reserve="$3"
	local block; block="$(generated_diskmon_block "$TESTROOT")"
	[ -n "$block" ] || {
		printf 'could not generate the kas fragment to lift BB_DISKMON_DIRS from\n' >&2
		return 1
	}
	write_harness "$HARNESS" "$block" "$mode" "$floor"

	make_vol "$VOL_NAME"
	run container run --rm -u 0:0 -c 2 -m 2g \
		--name "$VOL_NAME-run" \
		-e "DM_MIN_SPACE=$MIN_SPACE" \
		-e "DM_MIN_INODE=$MIN_INODE" \
		-e "DM_RESERVE_TO=$reserve" \
		-v "$VOL_NAME:/vol" \
		-v "$BITBAKE_DIR:/bitbake:ro" \
		-v "$HARNESS:/harness:ro" \
		"$(rt_image)" sh /harness/run.sh
}

# The two log lines bitbake prints, from lib/bb/monitordisk.py.
HALT_LINE='Immediately halt since the disk space monitor action is "HALT"!'

has() { printf '%s\n' "$output" | grep -qF "$1"; }
hasnt() { ! printf '%s\n' "$output" | grep -qF "$1"; }

# ---------------------------------------------------------------------------

setup() {
	if [ "${MACKAS_REAL_RUNTIME:-}" != "1" ]; then
		skip "opt-in: set MACKAS_REAL_RUNTIME=1 (dev-Mac only, non-hermetic, never CI)"
	fi

	BITBAKE_DIR="${MACKAS_REAL_BITBAKE_DIR:-${MACKAS_ROOT:-$HOME/oe}/work/bitbake}"
	if [ ! -x "$BITBAKE_DIR/bin/bitbake" ]; then
		skip "no bitbake checkout at $BITBAKE_DIR (set MACKAS_REAL_BITBAKE_DIR)"
	fi
	# Resolve it: a mackas root is very often a symlink onto the build drive,
	# and a -v mount source has to be the real path.
	BITBAKE_DIR="$(cd -- "$BITBAKE_DIR" && pwd -P)"

	TESTROOT="$(make_tmpdir)"
	HARNESS="$(make_tmpdir)"

	# Thresholds come from the generated value, never from a constant here.
	local block
	block="$(generated_diskmon_block "$TESTROOT")" || true
	[ -n "$block" ] || skip "could not generate the kas fragment (setup_kas_fragment failed)"
	MIN_SPACE="$(gmk_to_bytes "$(diskmon_field "$block" 3)")"
	MIN_INODE="$(gmk_to_bytes "$(diskmon_field "$block" 4)")"
	[ "${MIN_SPACE:-0}" -gt 0 ] || skip "could not read the space threshold out of the generated value"
	[ "${MIN_INODE:-0}" -gt 0 ] || skip "could not read the inode threshold out of the generated value"
}

# The runtime guards, for the tests that actually start a container. Kept out
# of setup() so the pure-parse test still runs with the runtime stopped.
need_runtime() {
	if ! container_running; then
		skip "Apple container runtime is not running (container system start)"
	fi
	if oe_build_in_use; then
		skip "REFUSING: an oe-build-* volume is attached to a running container (one-VM rule)"
	fi
	sweep_zztest_containers
	sweep_zztest
}

teardown() {
	[ "${MACKAS_REAL_RUNTIME:-}" = "1" ] || return 0
	if container_running; then
		sweep_zztest_containers
		sweep_zztest
	fi
	[ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"
	[ -n "${HARNESS:-}" ] && rm -rf "$HARNESS"
	return 0
}

# ---------------------------------------------------------------------------
# 1. No container needed: does bitbake's own parser understand the value?
# ---------------------------------------------------------------------------

@test "diskmon: bitbake's own getDiskData accepts the generated value as three HALT rules" {
	# The cheap half of the proof, and the only part that would still be
	# affordable if the container half ever became impossible: feed the exact
	# generated string to bb.monitordisk.getDiskData() -- the real parser, from
	# the real checkout -- and assert the action and BOTH thresholds it derives.
	# It cannot show HALT firing; it can show that nothing about the string is
	# quietly rejected (getDiskData returns None and only LOGS on a bad value,
	# so a typo would disable the monitor silently).
	local block; block="$(generated_diskmon_block "$TESTROOT")"
	[ -n "$block" ]

	# Substitute real, existing directories for the three bitbake variables.
	# getDiskData() does not statvfs anything -- that is check()'s job -- but it
	# DOES realpath() each path and mkdirhier() a missing one, so give it real
	# throwaway directories rather than let it create surprises.
	mkdir -p "$TESTROOT/tmp" "$TESTROOT/dl" "$TESTROOT/sstate"
	local value
	value="$(printf '%s\n' "$block" \
		| sed -e 's/^BB_DISKMON_DIRS ??= "//' -e 's/"$//' -e 's/\\$//' \
		| tr '\n' ' ')"
	value="${value//\$\{TMPDIR\}/$TESTROOT/tmp}"
	value="${value//\$\{DL_DIR\}/$TESTROOT/dl}"
	value="${value//\$\{SSTATE_DIR\}/$TESTROOT/sstate}"

	run python3 - "$BITBAKE_DIR" "$value" "$MIN_SPACE" "$MIN_INODE" <<-'PY'
		import sys
		sys.path.insert(0, sys.argv[1] + "/lib")
		import bb.monitordisk as md

		value, want_space, want_inode = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
		dd = md.getDiskData(value)
		if dd is None:
		    print("REJECTED: getDiskData returned None for %r" % value)
		    sys.exit(1)
		print("ENTRIES=%d" % len(dd))
		for (path, action), (dev, minspace, mininode) in sorted(dd.items()):
		    print("RULE %s %s space=%s inode=%s" % (action, path, minspace, mininode))
		    assert action == "HALT", "action is %r, not HALT" % action
		    assert minspace == want_space, "space %r != %r" % (minspace, want_space)
		    assert mininode == want_inode, "inode %r != %r" % (mininode, want_inode)
		assert len(dd) == 3, "expected 3 monitored dirs, got %d" % len(dd)
		print("OK")
	PY
	if [ "$status" -ne 0 ]; then
		printf 'bitbake rejected or mis-parsed the generated value:\n%s\n' "$output" >&2
		return 1
	fi
	has "ENTRIES=3"
	has "OK"
	# And the actions really are the modern spelling: ABORT is accepted by
	# bitbake 2.18 but only with a deprecation warning, so it must not appear.
	hasnt "ABORT"
}

# ---------------------------------------------------------------------------
# 2. The control. Without it, test 3 could "pass" on any unrelated failure.
# ---------------------------------------------------------------------------

@test "diskmon: real bitbake runs to completion on the volume with space to spare" {
	need_runtime
	# Same volume, same config, same recipe -- only the filling is disabled.
	# This is what makes a HALT in the next two tests attributable: it shows
	# the harness produces a WORKING bitbake run, so a halted one is the
	# monitor's doing and not a broken fixture.
	run_diskmon none 0 0
	if [ "$status" -ne 0 ]; then
		printf 'control run failed (rc=%s):\n%s\n' "$status" "$output" >&2
		return 1
	fi
	has "PRE: avail="
	has "FILLER: BUILD-COMPLETED"
	has "BITBAKE_RC=0"
	hasnt "$HALT_LINE"
}

# ---------------------------------------------------------------------------
# 3. The headline: free SPACE crosses the threshold mid-build.
# ---------------------------------------------------------------------------

@test "diskmon: HALT fires when free space crosses the threshold during a build" {
	need_runtime
	# Reserve down to threshold + 192 MiB with fallocate, then let the recipe
	# write 16 MiB at a time with a 0.4 s pause. The crossing therefore happens
	# a dozen heartbeats into a RUNNING runqueue, which is the situation
	# monitordisk.check() is registered for.
	local reserve_to=$((MIN_SPACE + 192 * 1024 * 1024))
	local floor=$((MIN_SPACE - 128 * 1024 * 1024))
	run_diskmon space "$floor" "$reserve_to"

	if printf '%s\n' "$output" | grep -q 'HARNESS-SKIP:'; then
		skip "$(printf '%s\n' "$output" | grep 'HARNESS-SKIP:' | head -1)"
	fi

	# The build must have really started and really been filling.
	has "RESERVED:"
	has "FILLER: round=0"

	# The monitor's own two lines, verbatim from lib/bb/monitordisk.py.
	if ! printf '%s\n' "$output" | grep -qF "$HALT_LINE"; then
		printf 'HALT never fired. Full run output:\n%s\n' "$output" >&2
		return 1
	fi
	# It halted for SPACE, not for inodes -- the HALT line itself is identical
	# for both arms, so the preceding warning is what attributes it.
	has "The free space of /vol/tmp"
	hasnt "The free inode of"

	# And it really cut the build short. The verdict is bitbake's own exit
	# code as seen INSIDE the guest, not the `container run` exit status:
	# whether Apple's runtime propagates a workload exit code is a separate
	# question this test has no business depending on.
	hasnt "FILLER: HOLD-EXPIRED"
	hasnt "FILLER: BUILD-COMPLETED"
	has "BITBAKE_RC="
	hasnt "BITBAKE_RC=0"
}

# ---------------------------------------------------------------------------
# 4. The other arm: free INODES cross the threshold mid-build.
# ---------------------------------------------------------------------------

@test "diskmon: HALT fires when free inodes cross the threshold during a build" {
	need_runtime
	# ext4 fixes its inode count at mkfs time (~1 per 16 KiB), so a few tens of
	# thousands of empty files walk a small volume down past 100 K free while
	# consuming almost no bytes -- which is exactly the failure the inode half
	# of the value exists for, and the one a space-only test would miss.
	local floor=$((MIN_INODE - 4096))
	run_diskmon inode "$floor" 0

	if printf '%s\n' "$output" | grep -q 'HARNESS-SKIP:'; then
		skip "$(printf '%s\n' "$output" | grep 'HARNESS-SKIP:' | head -1)"
	fi

	has "FILLER: round=0"
	if ! printf '%s\n' "$output" | grep -qF "$HALT_LINE"; then
		printf 'HALT never fired on inode exhaustion. Full run output:\n%s\n' "$output" >&2
		return 1
	fi
	# Attributable to inodes: the space arm must not have tripped first (it
	# would, if the filler were writing bulk data rather than empty files).
	has "The free inode of /vol/tmp"
	hasnt "The free space of"

	hasnt "FILLER: HOLD-EXPIRED"
	hasnt "FILLER: BUILD-COMPLETED"
	has "BITBAKE_RC="
	hasnt "BITBAKE_RC=0"
}
