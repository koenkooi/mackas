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

# ---------------------------------------------------------------------------
# A wrapper is per ROOT, and M3's `project add` puts several projects in one
# root sharing that ONE generated wrapper. Before #114, a wrapper pinned to A
# (because 'mackas --project A setup' ran last) relied on a SEPARATE
# pin-vs-cwd disagreement guard (cmd_runtime_args(), next to --expect-work)
# to catch a hand-typed build standing in work/B and refuse before handing it
# A's volumes with B's sources -- and that guard had a gap: it could only
# refuse when tier-3 cwd derivation found a DIFFERENT candidate to disagree
# with the frozen pin, so a build with no derivable candidate at all (a flat/
# legacy layout, an ambiguous cwd) silently fell through to the stale pin
# instead (the actual #114 incident).
#
# #114's fix removes the frozen pin itself in this scenario: with two or
# more projects pinned under one root, write_kas_wrapper() leaves
# MACKAS_PROJECT_PIN empty even for an explicit tier-1/2 selector, so there
# is nothing left for cwd to disagree WITH -- every hand-typed invocation
# through this wrapper now re-derives live from ITS OWN cwd (or falls
# through to the neutral default), the same as any unpinned invocation
# would. The tests below regenerate the SAME $KAS_CONTAINER_BIN with an
# EXPLICIT tier-1/2 pin requested (PROJECT_SELECT_SOURCE "--project", exactly
# as write_kas_wrapper()'s own q_projsel branch requires before it even
# CONSIDERS baking anything in) to prove the pin still comes out empty and
# every invocation is answered correctly anyway -- matching
# kas_wrapper.bats's own "selector:"/"#114:" tests' shape for regenerating
# the wrapper mid-test.
# ---------------------------------------------------------------------------

# #114: meta-qcom and poky share ONE root, so write_kas_wrapper() now leaves
# the pin EMPTY even though this call is an explicit --project meta-qcom --
# pinned_projects_referencing_root() finds two claimants of $TESTDIR, not
# one. There is therefore no frozen pin left for cwd to disagree WITH: the
# wrapper's live recompute falls straight through to ordinary tier-3
# derivation, which -- standing in poky's own workspace -- correctly derives
# poky on its own. The refusal this test used to assert was the OLD guard
# catching a disagreement between a frozen wrong pin and a live right cwd;
# post-#114 there is no wrong pin to freeze in the first place, so the build
# just succeeds with poky's own volumes instead of needing a refusal to
# recover from a bad pin.
@test "#114: a wrapper written under --project meta-qcom, meta-qcom and poky sharing a root, derives poky live when standing in poky's own workspace" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR/work/poky"
	run_wrapper build kas/base.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names mackas-poky
}

@test "pin-vs-cwd guard: the SAME wrapper still launches normally from meta-qcom's own workspace" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR/work/meta-qcom"
	run_wrapper build kas/base.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names mackas-meta-qcom
}

# #114: standing in bare work/ (neither project's own directory, no chain
# hint to derive from) with an empty pin, tier 3 finds zero candidates --
# neither meta-qcom's nor poky's MACKAS_ROOT/work/<name> matches "$TESTDIR/
# work" itself -- so this now falls through to tier 4's default search path
# config, the plain oe-build-* stem, rather than replaying meta-qcom's
# frozen pin. That fallthrough is the whole point of #114: a NEUTRAL,
# project-agnostic default beats confidently mounting the WRONG one of two
# sibling projects sharing this root.
@test "#114: a wrapper written under --project meta-qcom, meta-qcom and poky sharing a root, falls through to the default stem standing in bare work/ with no chain" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR/work"
	run_wrapper build foo.yml
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	assert_volume_names oe-build
}

# ---------------------------------------------------------------------------
# #114 superseded the OLD "unrelated unreadable pinned config does not break
# a settled selector" guarantee for THIS scenario specifically. That
# guarantee depended on an explicit pin being baked into the wrapper, which
# let the live recompute skip ordinary tier-3 derivation (and its ALL-of-
# projects_dir() fail-closed-on-unreadable scan) entirely -- see
# derive_project_candidates()'s own comment on why MODE=lenient exists only
# for an ALREADY-pinned consult. With meta-qcom and poky sharing a root,
# write_kas_wrapper() no longer bakes a pin at all (the whole point of
# #114), so the live recompute has nothing to skip tier 3 WITH any more: it
# runs the same ordinary, STRICT tier-3 derivation an unpinned invocation
# would, which fails closed on ANY unreadable pinned config in
# projects_dir() -- "it could have been the match" applies just as much to
# an invocation standing in meta-qcom's own directory as to any other,
# once there is no explicit selector left to exempt it. This is the correct
# trade: the alternative would be resurrecting some OTHER way to bypass
# tier 3's fail-closed rule for "no real pin, but maybe fine anyway", which
# is exactly the kind of silent-guess mackas's fail-closed philosophy
# refuses to make.
# ---------------------------------------------------------------------------

@test "#114: with the pin suppressed (shared root), an unrelated unreadable pinned config now refuses a build that used to be exempt" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	chmod 000 "$PROJDIR/poky.conf"
	cd "$TESTDIR/work/meta-qcom"
	run_wrapper build kas/base.yml
	chmod 600 "$PROJDIR/poky.conf"
	[ "$rc" -ne 0 ]
	[ ! -e "$KREC" ]
	printf '%s\n' "$out" | grep -qF 'cannot tell whether $PWD names a pinned project'
	printf '%s\n' "$out" | grep -qF 'poky.conf'
}

@test "#114: with the pin suppressed (shared root), an unrelated unreadable pinned config also refuses a neutral-cwd build" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	chmod 000 "$PROJDIR/poky.conf"
	cd "$TESTDIR/work"
	run_wrapper build foo.yml
	chmod 600 "$PROJDIR/poky.conf"
	[ "$rc" -ne 0 ]
	[ ! -e "$KREC" ]
	printf '%s\n' "$out" | grep -qF 'cannot tell whether $PWD names a pinned project'
	printf '%s\n' "$out" | grep -qF 'poky.conf'
}
