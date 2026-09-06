#!/usr/bin/env bats
#
# M6 (#80), slice 3: per-project KAS_WORK_DIR. Once a project is selected
# (PROJECT_SELECTED non-empty), MACKAS_WORK becomes <root>/work/<name> -- its
# own workspace -- instead of the flat <root>/work, and MACKAS_PROJECT (the
# config checkout) becomes the "<name>/<name>" stutter documented by #72.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/multi_project_compat.bats pins the OTHER half of this contract: an
# unselected run must keep resolving <root>/work, flat, unchanged -- exactly
# like MACKAS_LOGS/MACKAS_ENV_SH/MACKAS_KAS_FRAGMENT_SRC before it (M5, #79).
# Do not relax that file to make anything here pass.
#
# Also covers: legacy_layout_checkout()/refuse_legacy_layout() (the guard
# that stops setup_project()/ensure_project_checked_out() from cloning a
# SECOND copy over a pre-M6 flat checkout), and cmd_runtime_args's
# --emit-dirs flag plus its two new guards.

bats_require_minimum_version 1.5.0

load helpers

lib_setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	SCRIPT_DIR="$REPO_ROOT"
	SCRIPT_NAME="mackas"
	TESTDIR="$(make_tmpdir)"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	MACKAS_CPUS=6
	MACKAS_MEMORY=12g
	MACKAS_PROJECT_DIR="meta-ai"
	derive_paths
	DRY_RUN=0
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# 1. derive_paths(): MACKAS_WORK / MACKAS_PROJECT
# ---------------------------------------------------------------------------

@test "derive: MACKAS_WORK becomes work/<name> once a project is selected" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	[ "$MACKAS_WORK" = "$TESTDIR/work/meta-qcom" ]
	[ "$MACKAS_PROJECT" = "$TESTDIR/work/meta-qcom/meta-qcom" ]
}

@test "derive: a DIFFERENT selected name gets its OWN work dir, not a shared one" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	first="$MACKAS_WORK"
	PROJECT_SELECTED="meta-angstrom"
	MACKAS_PROJECT_DIR="meta-angstrom"
	derive_paths
	second="$MACKAS_WORK"
	[ "$first" != "$second" ]
	[ "$second" = "$TESTDIR/work/meta-angstrom" ]
}

@test "derive: unselected still resolves the flat work dir (no leak from a prior selected call)" {
	# derive_paths() runs more than once per invocation (adopt/setup re-derive
	# after picking a stem); a selected call must not leave anything behind
	# that leaks into a later unselected one in the same process.
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	PROJECT_SELECTED=""
	MACKAS_PROJECT_DIR="meta-ai"
	derive_paths
	[ "$MACKAS_WORK" = "$TESTDIR/work" ]
	[ "$MACKAS_PROJECT" = "$TESTDIR/work/meta-ai" ]
}

@test "derive: with no MACKAS_ROOT, MACKAS_WORK stays blank even when a project is selected" {
	# The no-root early-return branch blanks every derived path regardless of
	# selection -- see MACKAS_LOGS's own equivalent test in
	# tests/project_logs.bats. Under 'set -euo pipefail', an unset
	# MACKAS_REPO_REF_DIR here would abort 'status' on a machine with no
	# config at all -- this also proves it stays a defined empty string.
	PROJECT_SELECTED="meta-qcom"
	MACKAS_ROOT=""
	derive_paths
	[ "$MACKAS_WORK" = "" ]
	[ "$MACKAS_WORK_ROOT" = "" ]
	[ "$MACKAS_REPO_REF_DIR" = "" ]
}

@test "derive: MACKAS_REPO_REF_DIR is always empty this slice, selected or not" {
	# Slice M6-6 gives it a value once a project is selected; until then it is
	# a plain always-empty variable so cmd_runtime_args --emit-dirs and
	# kas_invoke_env() have something to read from day one.
	derive_paths
	[ "$MACKAS_REPO_REF_DIR" = "" ]
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	[ "$MACKAS_REPO_REF_DIR" = "" ]
}

# ---------------------------------------------------------------------------
# 2. legacy_layout_checkout() / refuse_legacy_layout()
# ---------------------------------------------------------------------------

@test "legacy_layout_checkout: silent no-op when nothing is selected" {
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	! legacy_layout_checkout
}

@test "legacy_layout_checkout: silent no-op when MACKAS_PROJECT_DIR is empty" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR=""
	derive_paths
	! legacy_layout_checkout
}

@test "legacy_layout_checkout: silent no-op once the new-layout checkout already exists" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git"
	! legacy_layout_checkout
}

@test "legacy_layout_checkout: silent no-op when neither location has been cloned yet" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	! legacy_layout_checkout
}

@test "legacy_layout_checkout: names the pre-M6 flat path when that is the only place the checkout exists" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_WORK_ROOT/meta-qcom/.git"
	[ "$(legacy_layout_checkout)" = "$MACKAS_WORK_ROOT/meta-qcom" ]
}

@test "refuse_legacy_layout: no-op (returns 0, prints nothing) when there is nothing to convert" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	out="$(refuse_legacy_layout 2>&1)"
	[ -z "$out" ]
}

@test "refuse_legacy_layout: dies naming both paths and the fix when the legacy shape is present" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_WORK_ROOT/meta-qcom/.git"
	out="$(refuse_legacy_layout 2>&1)" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF "$MACKAS_WORK_ROOT/meta-qcom"
	printf '%s\n' "$out" | grep -qF "$MACKAS_PROJECT"
	printf '%s\n' "$out" | grep -qF -- 'project add meta-qcom --from meta-qcom'
}

@test "setup_project: refuses instead of cloning a second copy when the checkout is still at the pre-M6 flat path" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_WORK_ROOT/meta-qcom/.git"
	out="$(setup_project 2>&1)" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF 'pre-M6 flat layout'
	printf '%s\n' "$out" | grep -qF -- 'project add meta-qcom --from meta-qcom'
	[ ! -d "$MACKAS_PROJECT/.git" ]
}

@test "ensure_project_checked_out: refuses instead of offering to clone when the checkout is still at the pre-M6 flat path" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	MACKAS_PROJECT_URL="https://example.invalid/meta-qcom.git"
	derive_paths
	mkdir -p "$MACKAS_WORK_ROOT/meta-qcom/.git"
	out="$(ensure_project_checked_out 2>&1)" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF 'pre-M6 flat layout'
	! printf '%s\n' "$out" | grep -qi 'clone it now'
}

# ---------------------------------------------------------------------------
# 3. cmd_runtime_args --emit-dirs
# ---------------------------------------------------------------------------

@test "runtime-args --emit-dirs: exactly three lines, and line 1 is byte-identical to the plain form" {
	plain="$(cmd_runtime_args)"
	out="$(cmd_runtime_args --emit-dirs)"
	[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 3 ]
	[ "$(printf '%s\n' "$out" | sed -n '1p')" = "$plain" ]
}

@test "runtime-args --emit-dirs: line 2 is KAS_WORK_DIR, line 3 is KAS_REPO_REF_DIR" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_WORK"
	out="$(cmd_runtime_args --emit-dirs)"
	printf '%s\n' "$out" | sed -n '2p' | grep -qxF "KAS_WORK_DIR=$MACKAS_WORK"
	printf '%s\n' "$out" | sed -n '3p' | grep -qxF 'KAS_REPO_REF_DIR='
}

@test "runtime-args --emit-dirs: unselected -- KAS_WORK_DIR is the flat root" {
	out="$(cmd_runtime_args --emit-dirs)"
	printf '%s\n' "$out" | sed -n '2p' | grep -qxF "KAS_WORK_DIR=$MACKAS_WORK_ROOT"
}

@test "runtime-args: --expect-work WITHOUT --emit-dirs refuses once a project is selected (old-wrapper hazard)" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_WORK"
	out="$(cmd_runtime_args --expect-work "$MACKAS_WORK_ROOT" 2>&1)" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF 'predates per-project work directories'
	printf '%s\n' "$out" | grep -qF -- '--project meta-qcom setup'
}

@test "runtime-args: --expect-work WITHOUT --emit-dirs still succeeds when nothing is selected" {
	out="$(cmd_runtime_args --expect-work "$MACKAS_WORK_ROOT" 2>&1)" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
}

@test "runtime-args --emit-dirs: refuses when the selected project's work dir does not exist yet" {
	PROJECT_SELECTED="meta-qcom"
	MACKAS_PROJECT_DIR="meta-qcom"
	derive_paths
	[ ! -d "$MACKAS_WORK" ]
	out="$(cmd_runtime_args --emit-dirs 2>&1)" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF "$MACKAS_WORK"
	printf '%s\n' "$out" | grep -qF -- '--project meta-qcom setup'
}

@test "runtime-args --emit-dirs: unselected succeeds even though the flat work dir already exists from setup" {
	mkdir -p "$MACKAS_WORK"
	out="$(cmd_runtime_args --emit-dirs 2>&1)" && rc=0 || rc=$?
	[ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. kas_invoke_env()'s ensure-step. Always empty (and so a no-op) this
# slice -- MACKAS_REPO_REF_DIR gets a value only in slice M6-6 -- but the
# mechanism itself is exercised now, against a manually-set value, so slice
# M6-6 lands on an already-proven ensure-step rather than an untested one.
# ---------------------------------------------------------------------------

@test "kas_invoke_env: ensures MACKAS_REPO_REF_DIR exists when non-empty" {
	cat > "$TESTDIR/fake-real" <<-'REC'
	#!/usr/bin/env bash
	exit 0
	REC
	chmod +x "$TESTDIR/fake-real"
	rr="$TESTDIR/not-yet-created-repo-ref"
	[ ! -d "$rr" ]
	# Sourcing mackas shadows bats' own run() -- explicit subshell, same idiom
	# tests/hermetic.bats' kas_invoke_env() test already uses, since the
	# function's final exec would otherwise replace the test process itself.
	(
		KAS_CONTAINER_REAL="$TESTDIR/fake-real"
		MACKAS_REPO_REF_DIR="$rr"
		kas_invoke_env "" "$MACKAS_GITCONFIG" 0 --version
	)
	[ -d "$rr" ]
}

@test "kas_invoke_env: no-op, no crash, when MACKAS_REPO_REF_DIR is empty (today's always-empty value)" {
	cat > "$TESTDIR/fake-real" <<-'REC'
	#!/usr/bin/env bash
	exit 0
	REC
	chmod +x "$TESTDIR/fake-real"
	(
		KAS_CONTAINER_REAL="$TESTDIR/fake-real"
		MACKAS_REPO_REF_DIR=""
		kas_invoke_env "" "$MACKAS_GITCONFIG" 0 --version
	)
}
