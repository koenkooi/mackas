#!/usr/bin/env bats
#
# End-to-end coverage for #78's kas-chain special case, THROUGH THE WRAPPER
# SUBPROCESS, with a REAL mackas behind it.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/kas_wrapper.bats already proves the generated wrapper's own
# leading-options scan finds the right file list and forwards it as
# '--kas-files' -- but it does that against a SCRIPTED MACKAS_SELF stub, which
# only proves the wrapper's half of the contract. This file proves the OTHER
# half: that an ACTUAL mackas, invoked exactly the way the wrapper invokes
# it, actually derives the right project (or correctly derives NOTHING and
# falls through to the factory oe-build-* stem) from that hint -- the
# standing-in-work/ case env.sh's kas-container() shell function cannot
# handle on its own, because MACKAS_PROJECT_DIR/MACKAS_KAS_CONFIG live in the
# CALLING shell while --runtime-args is computed by a SEPARATE subprocess
# (see load_config()'s own tier-3 comment in mackas, and the epic's "why the
# wrapper gets this for free" section).
#
# Harness: the SAME write_kas_wrapper()-generates-a-real-file, fake-.real-
# recorder idiom tests/kas_wrapper.bats uses, but MACKAS_SELF is pointed at
# $MACKAS itself (the real script under test) instead of a stub, and $HOME is
# a fresh, throwaway directory holding real pinned project configs plus a
# default (tier-4) config -- so the wrapper's live recompute is answered by
# an ACTUAL 'mackas runtime-args' subprocess doing real tier-3 derivation
# from whatever $PWD and --kas-files it was handed.
#
# One root, two pinned projects (meta-qcom, poky) sharing it -- the M3
# 'project add' shape #78's own design brief calls out as the reason a
# wrapper must never freeze a single project's selector into itself.

bats_require_minimum_version 1.5.0

load helpers

lib_setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	# Unexport it again immediately: MACKAS_SELF below is the REAL mackas,
	# invoked as a genuine SUBPROCESS by the generated wrapper -- an exported
	# MACKAS_LIB_ONLY=1 would leak into that child too and make IT skip
	# main() the same way this sourcing just did, producing silent, empty
	# --runtime-args output (a real bug this file's own first draft hit).
	unset MACKAS_LIB_ONLY
	TESTDIR="$(make_tmpdir)"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	MACKAS_CPUS=6
	MACKAS_MEMORY=12g

	# The REAL mackas as MACKAS_SELF -- see file header for why this file
	# exists at all rather than just extending kas_wrapper.bats's own
	# scripted-stub tests.
	SCRIPT_DIR="$(dirname "$MACKAS")"
	SCRIPT_NAME="$(basename "$MACKAS")"

	derive_paths
	DRY_RUN=0

	KREC="$TESTDIR/kas.rec"
	export KREC

	# A fresh, throwaway HOME: the real mackas subprocess resolves ITS OWN
	# config through this, exactly as a genuine invocation would -- nothing
	# here is injected directly into that subprocess, only left for it to
	# find on disk.
	export HOME="$TESTDIR/home"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"
	mkdir -p "$TESTDIR/work/meta-qcom" "$TESTDIR/work/poky" "$TESTDIR/work/legacy-checkout"

	pin meta-qcom <<-EOF
	MACKAS_ROOT="$TESTDIR"
	EOF
	pin poky <<-EOF
	MACKAS_ROOT="$TESTDIR"
	EOF
	# Tier 4's own default search path config: without this, every scenario
	# below where tier 3 derives NOTHING would fall through to a $MACKAS_ROOT
	# that is simply unset in the real subprocess, and --expect-work would
	# refuse ("generated for a different configuration") rather than the
	# oe-build-* stem the design calls for -- exactly the shape a real Mac
	# with one pinned root and a couple of `project add`-ed sub-projects is
	# already in.
	cat > "$HOME/.mackas.conf" <<-EOF
	MACKAS_ROOT="$TESTDIR"
	EOF
	chmod 600 "$HOME/.mackas.conf"

	write_container_mock
	write_recorder
	write_kas_wrapper
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

# Write a pinned project config named $1 from stdin, 0600 like adopt/project
# add always leave one.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# A fake `container`: daemon always up, no running containers -- so
# require_volumes_free()'s one-VM check always passes. Same minimal shape
# project_derive.bats' fakebin uses for the parts this file actually needs.
write_container_mock() {
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"system start") exit 0 ;;
	"ls "*|"ls") echo "ID"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

# The fake .real kas-container the wrapper execs at the end -- records argv
# to $KREC, same recorder idiom as kas_wrapper.bats.
write_recorder() {
	mkdir -p "$MACKAS_BIN"
	cat > "$KAS_CONTAINER_REAL" <<'REC'
#!/usr/bin/env bash
{
	printf 'ARGV_BEGIN\n'
	for a in "$@"; do printf 'ARG:%s\n' "$a"; done
	printf 'ARGV_END\n'
} >> "$KREC"
exit 0
REC
	chmod +x "$KAS_CONTAINER_REAL"
}

# The exact token passed to --runtime-args on the first recorded call.
rec_runtime_args_value() {
	awk '/^ARG:--runtime-args$/{getline; sub(/^ARG:/,""); print; exit}' "$KREC"
}

assert_volume_names() {
	local stem="$1" rt
	rt="$(rec_runtime_args_value)"
	printf '%s\n' "$rt" | grep -qF -- "-v ${stem}-tmp:/build"
	printf '%s\n' "$rt" | grep -qF -- "-v ${stem}-dl:/downloads"
	printf '%s\n' "$rt" | grep -qF -- "-v ${stem}-sstate:/sstate"
}

run_wrapper() {
	# NOTE: mackas defines its own run() -- bats' own `run` is shadowed by
	# lib_setup's `. "$MACKAS"` above, so this drives the wrapper through an
	# explicit subshell with a manually captured status, the same pattern
	# kas_wrapper.bats and volumes.bats already use.
	out="$( ("$KAS_CONTAINER_BIN" "$@") 2>&1 )" && rc=0 || rc=$?
}

# ---------------------------------------------------------------------------
# 1: from inside a pinned project's own workspace -- cwd derivation alone,
# no chain hint needed at all.
# ---------------------------------------------------------------------------

@test "from inside work/meta-qcom (pinned): mackas-meta-qcom-{tmp,dl,sstate}" {
	cd "$TESTDIR/work/meta-qcom"
	run_wrapper build kas/base.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names mackas-meta-qcom
}

# ---------------------------------------------------------------------------
# 2: from work/ ITSELF, with a chain naming meta-qcom -- cwd alone derives
# nothing ($PWD is work/, the parent of every checkout), so the chain's own
# leading component is what names the project.
# ---------------------------------------------------------------------------

@test "from work/ with chain meta-qcom/kas/a.yml:meta-qcom/kas/b.yml: same as standing in meta-qcom's own workspace" {
	cd "$TESTDIR/work"
	run_wrapper build meta-qcom/kas/a.yml:meta-qcom/kas/b.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names mackas-meta-qcom
}

# ---------------------------------------------------------------------------
# 3: a chain spanning two SIBLING workspaces derives nothing -- the entries
# disagree on their first component, the same rule env.sh's own
# _mackas_derive_project applies for the identical reason.
# ---------------------------------------------------------------------------

@test "from work/ with a chain spanning meta-qcom/... and poky/...: falls through to oe-build-*" {
	cd "$TESTDIR/work"
	run_wrapper build meta-qcom/kas/a.yml:poky/kas/b.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names oe-build
}

# ---------------------------------------------------------------------------
# 4: a chain naming a real, but UNPINNED, checkout under work/ -- the
# candidate path derives cleanly but matches no pinned config, so it is the
# same "zero candidates" answer as an unpinned legacy checkout today.
# ---------------------------------------------------------------------------

@test "from work/ with an unpinned checkout's chain: falls through to oe-build-*" {
	cd "$TESTDIR/work"
	run_wrapper build legacy-checkout/kas/a.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names oe-build
}

# ---------------------------------------------------------------------------
# 5: leading options (a value flag AND a boolean flag) are skipped by the
# wrapper's own scan to find the chain -- proven here by the REAL derivation
# still firing on the far end, not just by the wrapper forwarding SOMETHING.
# ---------------------------------------------------------------------------

@test "with --skip repos_checkout and -k before the chain: still derives meta-qcom" {
	cd "$TESTDIR/work"
	run_wrapper build --skip repos_checkout -k meta-qcom/kas/a.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names mackas-meta-qcom
	# And the leading options themselves reached kas-container untouched --
	# the hint is a SEPARATE --kas-files flag on the runtime-args call, never
	# a rewrite of the caller's own argv.
	rec_argv() { sed -n 's/^ARG://p' "$KREC"; }
	rec_argv | grep -qxF -- '--skip'
	rec_argv | grep -qxF 'repos_checkout'
	rec_argv | grep -qxF -- '-k'
}

# ---------------------------------------------------------------------------
# 6: an absolute chain names a real path outright -- nothing to derive
# relative to $PWD, so this is the same "no hint" shape as no chain at all.
# ---------------------------------------------------------------------------

@test "with an absolute chain: falls through to oe-build-*" {
	cd "$TESTDIR/work"
	run_wrapper build /abs/path/a.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names oe-build
}

# ---------------------------------------------------------------------------
# 7: from $HOME, nowhere near any workspace, with an ordinary bare file list
# (no leading path component at all) -- cwd derives nothing, the chain hint
# yields no component either, tier 4's own default config supplies the root.
# ---------------------------------------------------------------------------

@test "from \$HOME: falls through to oe-build-*" {
	cd "$HOME"
	run_wrapper build foo.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names oe-build
}
