#!/usr/bin/env bats
#
# M5 (#79): the per-project generated env file, env-<name>.sh.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Once a project is selected (PROJECT_SELECTED non-empty -- set by
# select_pinned_project() for --project / $MACKAS_PROJECT_SELECT / #78's tier-3
# derivation, all three), MACKAS_ENV_SH becomes <base>/env-<name>.sh instead of
# the flat <base>/env.sh, and the generated file exports the selector itself
# with the same '${VAR:-...}' guard idiom setup_shim_and_env() already uses for
# GITCONFIG_FILE / MACKAS_KAS_AUTO_FRAGMENT / MACKAS_KAS_AUTO_PROJECT -- so
# sourcing it can never clobber a shell that already picked a project of its
# own. tests/generated_paths_compat.bats pins the OTHER half of this contract:
# an unselected run must keep resolving <base>/env.sh, unchanged. Do not
# relax that file to make anything here pass.

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
	derive_paths
	DRY_RUN=0
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

write_env_sh() {
	mkdir -p "$MACKAS_BIN"
	setup_shim_and_env >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. The path itself
# ---------------------------------------------------------------------------

@test "derive: env.sh becomes env-<name>.sh once a project is selected" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	[ "$MACKAS_ENV_SH" = "$TESTDIR/env-meta-qcom.sh" ]
}

@test "derive: a DIFFERENT selected name gets its OWN env file, not a shared one" {
	# Two projects on one MACKAS_ROOT must never collide on the generated file
	# -- the whole reason for this naming scheme.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	first="$MACKAS_ENV_SH"
	PROJECT_SELECTED="meta-angstrom"
	derive_paths
	second="$MACKAS_ENV_SH"
	[ "$first" != "$second" ]
	[ "$second" = "$TESTDIR/env-meta-angstrom.sh" ]
}

@test "derive: unselected still resolves the flat env.sh (no new field left set from a prior call)" {
	# derive_paths() runs more than once per invocation (adopt/setup re-derive
	# after picking a stem); a selected call must not leave anything behind
	# that leaks into a later unselected one in the same process.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	PROJECT_SELECTED=""
	derive_paths
	[ "$MACKAS_ENV_SH" = "$TESTDIR/env.sh" ]
}

# ---------------------------------------------------------------------------
# 2. The generated file's content
# ---------------------------------------------------------------------------

@test "env-<name>.sh: exports MACKAS_PROJECT_SELECT using the \${VAR:-...} guard idiom" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	derive_paths
	write_env_sh
	[ -f "$MACKAS_ENV_SH" ]
	# The exact idiom GITCONFIG_FILE/MACKAS_KAS_AUTO_FRAGMENT already use in
	# this same file: a bare assignment would clobber a value set before this
	# file is sourced, so it must be the ':-' (or if-guard) form, never bare.
	grep -qF "export MACKAS_PROJECT_SELECT=\${MACKAS_PROJECT_SELECT:-'meta-qcom'}" "$MACKAS_ENV_SH"
}

@test "env.sh (unselected): has no MACKAS_PROJECT_SELECT export at all" {
	# Byte-identical to today for an unselected run: this whole export must
	# not appear, not even as an empty default -- see the compat contract in
	# tests/generated_paths_compat.bats.
	write_env_sh
	[ -f "$MACKAS_ENV_SH" ]
	! grep -q 'MACKAS_PROJECT_SELECT' "$MACKAS_ENV_SH"
}

@test "env-<name>.sh: a project name with a shell metacharacter is baked in inert" {
	# validate_project_select() is what actually refuses this at every real
	# entry point (select_pinned_project calls it first); this only pins that
	# the generated file has no SECOND, weaker path to the same protection --
	# shq() is what stands between PROJECT_SELECTED and shell code here, same
	# as every other interpolated value in this heredoc.
	# No '/' in the fake name: PROJECT_SELECTED becomes part of a FILENAME
	# here (unlike the write_kas_wrapper() precedent this is modelled on,
	# where it is just a string embedded in script text), so a slash would
	# only prove this test's fixture wrong, not the injection question.
	cd "$TESTDIR"
	PROJECT_SELECTED="a'\$(touch pwned)b"
	derive_paths
	write_env_sh
	[ -f "$MACKAS_ENV_SH" ]
	# The unbalanced "'" is the sharper failure mode than code execution: fed
	# in raw, it opens a quote inside the ${VAR:-...} word that never closes,
	# so bash's parser swallows every line after it -- including the whole
	# kas-container() function below -- into one string value, no syntax
	# error anywhere. bash -n stays happy either way, so the real check is
	# that sourcing the file still leaves a working kas-container function.
	out="$(/bin/bash -c '. "$1" >/dev/null 2>&1; type kas-container >/dev/null 2>&1 && echo FUNC_OK' _ "$MACKAS_ENV_SH")"
	[ "$out" = "FUNC_OK" ]
	[ ! -e "$TESTDIR/pwned" ]
}

@test "env-<name>.sh: is valid bash 3.2 and zsh" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	write_env_sh
	/bin/bash -n "$MACKAS_ENV_SH"
	/bin/zsh -n "$MACKAS_ENV_SH"
}

# ---------------------------------------------------------------------------
# 3. Sourcing behaviour -- the guard's whole point
# ---------------------------------------------------------------------------

@test "sourcing env-<name>.sh does NOT clobber a MACKAS_PROJECT_SELECT the shell already set" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	write_env_sh
	got="$(MACKAS_PROJECT_SELECT=other-proj /bin/bash -c '
		. "$1" >/dev/null 2>&1
		printf "%s" "$MACKAS_PROJECT_SELECT"' _ "$MACKAS_ENV_SH")"
	[ "$got" = "other-proj" ]
}

@test "sourcing env-<name>.sh DOES fill in MACKAS_PROJECT_SELECT when the shell had none" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	write_env_sh
	got="$(env -u MACKAS_PROJECT_SELECT /bin/bash -c '
		. "$1" >/dev/null 2>&1
		printf "%s" "$MACKAS_PROJECT_SELECT"' _ "$MACKAS_ENV_SH")"
	[ "$got" = "meta-qcom" ]
}
