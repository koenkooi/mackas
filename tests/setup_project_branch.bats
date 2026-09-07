#!/usr/bin/env bats
#
# setup_project()'s branch-mismatch gate (#115): when the live project
# checkout's actual branch disagrees with the pinned MACKAS_PROJECT_BRANCH,
# switching it is a real `git checkout` against a live working tree that may
# hold uncommitted work. It must be confirm()-gated, not run unconditionally,
# and -y/no-tty must default to REFUSING rather than assuming "switch".
#
# Sourced directly (MACKAS_LIB_ONLY=1), same pattern as the "volume move:
# cross-filesystem" test in volume_mgmt.bats: bats' `run` wrapper (a
# subprocess) attaches no tty and cannot exercise a genuinely-interactive
# confirm() "yes" answer (see project_add.bats' note on the same
# limitation), so the interactive yes/no cases here call setup_project()
# directly in-process and stand in for the real prompt by overriding confirm()
# itself -- this still pins the real thing under test: that setup_project()
# calls confirm() at all, and branches on its answer, rather than switching
# unconditionally.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"

	# A real local fixture repo with two branches, so the real `git fetch
	# origin`/`git checkout` this code path runs have a real origin to talk
	# to -- not a stub. "main" is the fixture's initial branch; "other" is
	# where the live checkout below actually sits, standing in for a
	# checkout moved by hand after MACKAS_PROJECT_BRANCH was pinned.
	FIXTURE="$TESTDIR/fixture.git"
	mkdir -p "$FIXTURE"
	(
		cd "$FIXTURE"
		git init -q -b main
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		git checkout -q -b other
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m other
	)

	PROJECT="$TESTDIR/work/proj"
	mkdir -p "$TESTDIR/work"
	git clone -q "$FIXTURE" "$PROJECT"
	git -C "$PROJECT" checkout -q other

	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	setup_colors
	DRY_RUN=0; ASSUME_YES=0; VERBOSE=0

	MACKAS_PROJECT="$PROJECT"
	MACKAS_PROJECT_DIR="proj"
	MACKAS_PROJECT_URL="$FIXTURE"
}

teardown() {
	rm -rf "$TESTDIR"
}

# The branch the live checkout is actually on right now.
current_branch() {
	git -C "$PROJECT" symbolic-ref --short -q HEAD
}

@test "setup_project: branch already matches the pin -- no prompt, no change" {
	MACKAS_PROJECT_BRANCH="other"
	output="$(setup_project 2>&1)"

	printf '%s\n' "$output" | grep -qi 'already done'
	! printf '%s\n' "$output" | grep -qi 'switch'
	[ "$(current_branch)" = "other" ]
}

@test "setup_project: branch differs, interactive confirm answers yes -- switches" {
	MACKAS_PROJECT_BRANCH="main"
	# Stand in for a real tty answering "y": bats attaches no tty, so the
	# real prompt cannot be driven directly (see file header).
	confirm() { return 0; }
	output="$(setup_project 2>&1)"

	printf '%s\n' "$output" | grep -qF "switched proj to main"
	[ "$(current_branch)" = "main" ]
}

@test "setup_project: branch differs, interactive confirm answers no -- refuses, checkout untouched" {
	MACKAS_PROJECT_BRANCH="main"
	confirm() { return 1; }
	output="$(setup_project 2>&1)"

	printf '%s\n' "$output" | grep -qi "declined -- leaving proj on 'other'"
	[ "$(current_branch)" = "other" ]
}

@test "setup_project: branch differs, -y (non-interactive) -- refuses by default, checkout untouched, clear warning" {
	MACKAS_PROJECT_BRANCH="main"
	ASSUME_YES=1
	output="$(setup_project 2>&1)"

	# Names the mismatch (current branch vs the pin) and what to do by hand.
	printf '%s\n' "$output" | grep -qF "proj is on 'other', pinned branch is 'main'"
	printf '%s\n' "$output" | grep -qi 'not switching a live checkout non-interactively'
	printf '%s\n' "$output" | grep -qF "git -C $PROJECT checkout main"
	[ "$(current_branch)" = "other" ]
}

@test "setup_project: branch differs, no tty and no -y -- refuses by default, checkout untouched" {
	MACKAS_PROJECT_BRANCH="main"
	# ASSUME_YES stays 0; bats itself attaches no tty to this shell, so this
	# exercises confirm()'s own built-in no-tty decline -- the real,
	# unoverridden confirm().
	output="$(setup_project 2>&1)"

	printf '%s\n' "$output" | grep -qi 'not a terminal'
	printf '%s\n' "$output" | grep -qi "declined -- leaving proj on 'other'"
	[ "$(current_branch)" = "other" ]
}
