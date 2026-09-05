#!/usr/bin/env bats
#
# M5 (#79), item 2: per-project macos-<name>.yml canonical kas fragment.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Once a project is selected (PROJECT_SELECTED non-empty -- set by
# select_pinned_project() for --project / $MACKAS_PROJECT_SELECT / #78's tier-3
# derivation, all three), MACKAS_KAS_FRAGMENT_SRC becomes
# <base>/kas/macos-<name>.yml instead of the flat <base>/kas/macos.yml, using
# the exact same gate derive_paths() already applies to MACKAS_ENV_SH (M5 item
# 1, tests/project_env_sh.bats). The IN-CHECKOUT copy (MACKAS_KAS_FRAGMENT_REPO)
# does NOT change: each project has its own private checkout, so there is no
# collision to resolve there, and it stays literally kas/macos-local.yml.
# tests/generated_paths_compat.bats pins the OTHER half of this contract: an
# unselected run must keep resolving <base>/kas/macos.yml, unchanged. Do not
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
# 1. The path itself
# ---------------------------------------------------------------------------

@test "derive: macos.yml becomes macos-<name>.yml once a project is selected" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	[ "$MACKAS_KAS_FRAGMENT_SRC" = "$TESTDIR/kas/macos-meta-qcom.yml" ]
}

@test "derive: a DIFFERENT selected name gets its OWN canonical fragment, not a shared one" {
	# Two projects on one MACKAS_ROOT must never collide on the generated
	# fragment -- the whole reason for this naming scheme.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	first="$MACKAS_KAS_FRAGMENT_SRC"
	PROJECT_SELECTED="meta-angstrom"
	derive_paths
	second="$MACKAS_KAS_FRAGMENT_SRC"
	[ "$first" != "$second" ]
	[ "$second" = "$TESTDIR/kas/macos-meta-angstrom.yml" ]
}

@test "derive: unselected still resolves the flat macos.yml (no leak from a prior selected call)" {
	# derive_paths() runs more than once per invocation (adopt/setup re-derive
	# after picking a stem); a selected call must not leave anything behind
	# that leaks into a later unselected one in the same process.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	PROJECT_SELECTED=""
	derive_paths
	[ "$MACKAS_KAS_FRAGMENT_SRC" = "$TESTDIR/kas/macos.yml" ]
}

@test "derive: the in-checkout copy stays kas/macos-local.yml regardless of selection" {
	# MACKAS_KAS_FRAGMENT_REPO names a file INSIDE one project's own checkout
	# -- there is only ever one project per checkout, so it needs no project
	# component and must not grow one.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	[ "$MACKAS_KAS_FRAGMENT_REPO" = "$TESTDIR/work/meta-ai/kas/macos-local.yml" ]
	[ "$(basename "$MACKAS_KAS_FRAGMENT_REPO")" = "macos-local.yml" ]
}

# ---------------------------------------------------------------------------
# 2. setup_kas_fragment() actually writing the two files
# ---------------------------------------------------------------------------

@test "setup_kas_fragment: writes the canonical fragment at macos-<name>.yml when selected" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	[ -f "$TESTDIR/kas/macos-meta-qcom.yml" ]
	[ ! -e "$TESTDIR/kas/macos.yml" ]
	grep -qF 'BB_DISKMON_DIRS' "$TESTDIR/kas/macos-meta-qcom.yml"
}

@test "setup_kas_fragment: two different selections produce two different canonical fragments that do not overwrite each other" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	first_content="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"

	PROJECT_SELECTED="meta-angstrom"
	MACKAS_PROJECT_DIR="meta-angstrom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	second_content="$(cat "$MACKAS_KAS_FRAGMENT_SRC")"

	# Both files still exist, distinct, and the second run never touched the
	# first project's fragment.
	[ -f "$TESTDIR/kas/macos-meta-qcom.yml" ]
	[ -f "$TESTDIR/kas/macos-meta-angstrom.yml" ]
	[ "$(cat "$TESTDIR/kas/macos-meta-qcom.yml")" = "$first_content" ]
	[ "$(cat "$TESTDIR/kas/macos-meta-angstrom.yml")" = "$second_content" ]
}

@test "setup_kas_fragment: unselected still writes the flat macos.yml" {
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	[ -f "$TESTDIR/kas/macos.yml" ]
}

@test "setup_kas_fragment: the in-checkout install still lands at kas/macos-local.yml when selected" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git/info"
	: > "$MACKAS_PROJECT/.git/info/exclude"
	setup_kas_fragment >/dev/null 2>&1
	[ -f "$MACKAS_PROJECT/kas/macos-local.yml" ]
	[ "$(basename "$MACKAS_PROJECT/kas/macos-local.yml")" = "macos-local.yml" ]
	# The exclude entry is still the plain, project-agnostic literal -- not
	# "kas/macos-local-meta-qcom.yml" or any other selector-shaped variant.
	[ "$(grep -c '^kas/macos-local.yml$' "$MACKAS_PROJECT/.git/info/exclude")" -eq 1 ]
}

@test "setup_kas_fragment: content is unaffected by selection, only the filename differs" {
	# #79's own text: "the generated fragment content itself is unchanged by
	# this slice -- only where the canonical copy lives and what it is
	# called." Strip the one line that legitimately differs (it names its own
	# path) and the rest must be byte-identical.
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	unselected="$(grep -v '^# Canonical copy:' "$TESTDIR/kas/macos.yml")"
	rm -rf "$TESTDIR/kas" "$MACKAS_PROJECT/kas"

	PROJECT_SELECTED="meta-qcom"
	derive_paths
	setup_kas_fragment >/dev/null 2>&1
	selected="$(grep -v '^# Canonical copy:' "$MACKAS_KAS_FRAGMENT_SRC")"

	[ "$unselected" = "$selected" ]
}

# ---------------------------------------------------------------------------
# 3. status
# ---------------------------------------------------------------------------

@test "status: reports the selected project's own canonical fragment path" {
	PROJECT_SELECTED="meta-qcom"
	PROJECT_SELECT_SOURCE="--project"
	derive_paths
	mkdir -p "$MACKAS_PROJECT/.git"
	setup_kas_fragment >/dev/null 2>&1
	out="$(cmd_status 2>&1)"
	printf '%s\n' "$out" | grep -qF "$TESTDIR/kas/macos-meta-qcom.yml"
	! printf '%s\n' "$out" | grep -qF "$TESTDIR/kas/macos.yml "
}
