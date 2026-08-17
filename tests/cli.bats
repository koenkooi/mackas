#!/usr/bin/env bats
#
# Tests for mackas argument parsing, usage output and exit codes,
# plus the guarantee that --dry-run mutates nothing.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_MACHINE
	export HOME="$TESTDIR"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# --help / --version
# ---------------------------------------------------------------------------

@test "--help succeeds and lists every command" {
	run "$MACKAS" --help
	[ "$status" -eq 0 ]
	for cmd in check setup smoketest status shell clean destroy; do
		printf '%s\n' "$output" | grep -q "$cmd"
	done
}

@test "--help documents the precedence order" {
	run "$MACKAS" --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'defaults'
	printf '%s\n' "$output" | grep -q 'config file'
	printf '%s\n' "$output" | grep -q 'environment'
}

@test "-h is equivalent to --help" {
	run "$MACKAS" -h
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'usage'
}

@test "'help' as a subcommand works" {
	run "$MACKAS" help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'usage'
}

@test "--version prints the script name and a version" {
	run "$MACKAS" --version
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'mackas'
	printf '%s\n' "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'
}

# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

@test "an unknown subcommand exits non-zero" {
	run "$MACKAS" frobnicate
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown command'
}

@test "an unknown option exits non-zero" {
	run "$MACKAS" --not-a-real-flag
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown option'
}

@test "two commands at once is an error" {
	run "$MACKAS" check status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'more than one command'
}

# ---------------------------------------------------------------------------
# Fable CLI-consistency review: bare 'help' symmetry, misplaced global
# flags in a tail-capturing command, and --version everywhere.
# ---------------------------------------------------------------------------

@test "bare 'help' AFTER a bare top-level command works (not just before)" {
	# Regression: 'mackas help check' always worked (cmd starts as "help",
	# then 'check' is absorbed); 'mackas check help' did not -- cmd was
	# already "check" by the time 'help' arrived, and that hit the SAME
	# case arm as every other bare command, so it died as "two commands
	# given" instead of being recognised as a help request.
	run "$MACKAS" check help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'usage'

	run "$MACKAS" setup help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'usage'
}

@test "each bare command's --help shows ITS OWN usage, not the general commands list" {
	# Regression: 'mackas setup --help' used to show the SAME general usage()
	# as bare 'mackas --help' (COMMANDS list, EXAMPLES, the works) because
	# -h/--help clobbered cmd to the sentinel "help", losing which command
	# was named. Each bare command now has its own *_usage() function, the
	# same treatment volume/retrieve/buildstats/set/get/unset already had.
	local name; name="$(basename "$MACKAS")"
	for c in check setup smoketest status shell clean destroy; do
		run "$MACKAS" "$c" --help
		[ "$status" -eq 0 ]
		printf '%s\n' "$output" | grep -qi 'usage'
		! printf '%s\n' "$output" | grep -qF 'COMMANDS'
		printf '%s\n' "$output" | grep -qF "$name $c"
	done
}

@test "'X help' and 'help X' also show the command-specific usage, not the general one" {
	run "$MACKAS" setup help
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF 'COMMANDS'

	run "$MACKAS" help setup
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF 'COMMANDS'
}

@test "'help X' and 'X help' produce the SAME output for a bare command" {
	run "$MACKAS" help status
	local a="$output"
	run "$MACKAS" status help
	[ "$output" = "$a" ]
}

@test "two DIFFERENT real commands (neither is 'help') are still refused" {
	run "$MACKAS" check status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'more than one command'
}

@test "--version works after a tail-capturing command's own word" {
	# Verified missing in the Fable review: 'mackas volume --version' used
	# to die as "unknown 'volume' subcommand: --version" instead of doing
	# what --version does everywhere else.
	for cmd in volume retrieve buildstats buildhistory set get unset clean; do
		run "$MACKAS" "$cmd" --version
		[ "$status" -eq 0 ]
		printf '%s\n' "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'
	done
}

@test "--config after a tail-capturing command's word is refused with a clear redirect, not a generic error" {
	# --config/--set are consumed by main()'s OWN parsing loop before
	# cmd_volume/cmd_set/etc. ever run, so one typed AFTER the command word
	# is silently never seen by the code that would act on it. Must die
	# with something actionable, not "unknown option for 'volume'".
	run "$MACKAS" volume list --config /tmp/whatever.conf
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'must come BEFORE'

	run "$MACKAS" set A B --set X=Y
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'must come BEFORE'

	run "$MACKAS" clean downloads --config /tmp/whatever.conf
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'must come BEFORE'
}

@test "--config with no argument is an error" {
	run "$MACKAS" --config
	[ "$status" -ne 0 ]
}

@test "error messages go to stderr, not stdout" {
	run --separate-stderr "$MACKAS" frobnicate
	[ "$status" -ne 0 ]
	[ -n "$stderr" ]
}

# ---------------------------------------------------------------------------
# Flag placement
# ---------------------------------------------------------------------------

@test "flags may appear before the subcommand" {
	run "$MACKAS" --dry-run status
	[ "$status" -eq 0 ]
}

@test "flags may appear after the subcommand" {
	run "$MACKAS" status --dry-run
	[ "$status" -eq 0 ]
}

@test "no command at all defaults to 'check'" {
	# check is read-only, so this is safe. It may legitimately report
	# failures on a machine that isn't set up; we only assert that it ran
	# the preflight rather than erroring out on argument parsing.
	run "$MACKAS" --set "MACKAS_ROOT=$TESTDIR/oe"
	printf '%s\n' "$output" | grep -qi 'preflight'
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "--dry-run setup creates no directories" {
	root="$TESTDIR/oe-root"
	run "$MACKAS" --dry-run --set "MACKAS_ROOT=$root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" setup
	[ ! -e "$root" ]
	[ ! -e "$TESTDIR/short" ]
}

@test "--dry-run setup creates no container volume" {
	# The mock stands in for `container`; if the shim or mackas tried to
	# create a volume for real we would see it in the mock's log.
	#
	# This used to guard its only assertion behind `if [ -f "$mocklog" ]`, so
	# if setup died before the volume step -- never invoking the mock, never
	# creating the log -- the test passed vacuously, asserting nothing. Pin the
	# whole contract instead: setup must SUCCEED, must actually REACH the volume
	# step (the dry-run PRINTS the create command), the mock must really have
	# been invoked (its log exists), and yet no create was EXECUTED.
	root="$TESTDIR/oe-root"
	mocklog="$TESTDIR/mock.log"
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$mocklog"
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH" run "$MACKAS" --dry-run \
		--set "MACKAS_ROOT=$root" --set "MACKAS_SHORT_LINK=$TESTDIR/short" setup
	# Ran to completion, not a die before the volumes step.
	[ "$status" -eq 0 ]
	# Reached the volume step: dry-run PRINTS the create it is declining to run.
	# Without this the "no create executed" check below could pass simply because
	# setup never got that far.
	printf '%s\n' "$output" | grep -qF 'volume create'
	# The read-only probes always run, so the mock really was invoked.
	[ -f "$mocklog" ]
	# ...but no volume was actually created.
	! grep -q 'volume create' "$mocklog"
}

@test "--dry-run setup does not prompt (regression: dry-run used to hang)" {
	# One of the fixed bugs: --dry-run aborted at interactive prompts.
	# Feed it no stdin at all; it must still finish.
	root="$TESTDIR/oe-root"
	run "$MACKAS" --dry-run --set "MACKAS_ROOT=$root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" setup < /dev/null
	[ ! -e "$root" ]
}

@test "--dry-run status is read-only and succeeds" {
	run "$MACKAS" --dry-run status
	[ "$status" -eq 0 ]
}

@test "check creates nothing" {
	root="$TESTDIR/oe-root"
	run "$MACKAS" --set "MACKAS_ROOT=$root" check
	[ ! -e "$root" ]
}

# ---------------------------------------------------------------------------
# Regression guard: destroy under set -e / pipefail
# ---------------------------------------------------------------------------

@test "--dry-run destroy runs to completion and removes nothing" {
	# Regression guard for the pipefail/set -e silent-exit bug on destroy.
	root="$TESTDIR/oe-root"
	mkdir -p "$root"
	touch "$root/sentinel"
	run "$MACKAS" --dry-run -y --set "MACKAS_ROOT=$root" destroy
	[ -f "$root/sentinel" ]
}
