#!/usr/bin/env bats
#
# M5 (#79): the per-project log directory, logs/<name>/.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Once a project is selected (PROJECT_SELECTED non-empty -- set by
# select_pinned_project() for --project / $MACKAS_PROJECT_SELECT / #78's tier-3
# derivation, all three), MACKAS_LOGS becomes <base>/logs/<name> instead of
# the flat <base>/logs, using the exact same gate derive_paths() already
# applies to MACKAS_ENV_SH and MACKAS_KAS_FRAGMENT_SRC. Every call site that
# touches MACKAS_LOGS -- dump's output path, the
# smoketest rung log, status's "Recent logs" listing, and bare `clean`'s
# rm -rf/mkdir -p pair -- is a pure read of that one variable, so this one
# gate scopes all four for free; tests/project_logs_cli.bats covers dump/
# status/clean end to end with real filesystem checks. tests/
# generated_paths_compat.bats pins the OTHER half of this contract: an
# unselected run must keep resolving <base>/logs, flat, unchanged. Do not
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

@test "derive: logs becomes logs/<name> once a project is selected" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	[ "$MACKAS_LOGS" = "$TESTDIR/logs/meta-qcom" ]
}

@test "derive: a DIFFERENT selected name gets its OWN log dir, not a shared one" {
	# Two projects on one MACKAS_ROOT must never collide on generated logs --
	# the whole reason for this naming scheme.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	first="$MACKAS_LOGS"
	PROJECT_SELECTED="meta-angstrom"
	derive_paths
	second="$MACKAS_LOGS"
	[ "$first" != "$second" ]
	[ "$second" = "$TESTDIR/logs/meta-angstrom" ]
}

@test "derive: unselected still resolves the flat logs dir (no leak from a prior selected call)" {
	# derive_paths() runs more than once per invocation (adopt/setup re-derive
	# after picking a stem); a selected call must not leave anything behind
	# that leaks into a later unselected one in the same process.
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	PROJECT_SELECTED=""
	derive_paths
	[ "$MACKAS_LOGS" = "$TESTDIR/logs" ]
}

@test "derive: with no MACKAS_ROOT, logs stays blank even when a project is selected" {
	# The no-root early-return branch blanks every derived path regardless of
	# selection -- PROJECT_SELECTED can be non-empty there (it still runs
	# derive_volume_names/project_select_resolution_note), but MACKAS_LOGS
	# must stay "" rather than resolve to the absolute-path bug "/logs/name".
	PROJECT_SELECTED="meta-qcom"
	MACKAS_ROOT=""
	derive_paths
	[ "$MACKAS_LOGS" = "" ]
}

# ---------------------------------------------------------------------------
# 2. smoketest_rung() -- the log filename itself, run_kas stubbed out so this
#    stays library-level (same boundary tests/volumes.bats' "run_kas:
#    captures kas's exit" test already stubs at).
# ---------------------------------------------------------------------------

@test "smoketest_rung: the log lands in the selected project's own logs/<name>/" {
	PROJECT_SELECTED="meta-qcom"
	derive_paths
	run_kas() { return 0; }
	overhead_start() { :; }
	overhead_stop() { :; }
	smoketest_rung 1 1 "test rung" "ok" shell -c true >/dev/null 2>&1
	[ -f "$TESTDIR/logs/meta-qcom/smoketest-1-test-rung.log" ]
	[ ! -e "$TESTDIR/logs/smoketest-1-test-rung.log" ]
}

@test "smoketest_rung: unselected still lands the log flat in <base>/logs/" {
	run_kas() { return 0; }
	overhead_start() { :; }
	overhead_stop() { :; }
	smoketest_rung 1 1 "test rung" "ok" shell -c true >/dev/null 2>&1
	[ -f "$TESTDIR/logs/smoketest-1-test-rung.log" ]
}
