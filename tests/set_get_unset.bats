#!/usr/bin/env bats
#
# Tests for `mackas set` / `get` / `unset` -- the persistent counterpart to
# the ephemeral `--set NAME=VALUE` flag.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_USE_NFS_MIRRORS MACKAS_SSTATE_MIRROR_PATH MACKAS_DL_MIRROR_PATH
	# HOME, not a real one: ~/.mackas.conf is the default target when nothing
	# was already loaded, and the real home directory's own config (if any)
	# must never leak into these tests either way.
	export HOME="$TESTDIR/home"
	mkdir -p "$HOME"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

conf() { cat "$HOME/.mackas.conf"; }

@test "set: with no config file yet, creates ~/.mackas.conf" {
	run "$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	[ "$status" -eq 0 ]
	[ -f "$HOME/.mackas.conf" ]
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='1'"
}

@test "set: a second call appends rather than clobbering the first" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	run "$MACKAS" set MACKAS_SSTATE_MIRROR_PATH /Volumes/rogue-build/qualcomm/build/sstate-cache
	[ "$status" -eq 0 ]
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='1'"
	conf | grep -qF "MACKAS_SSTATE_MIRROR_PATH='/Volumes/rogue-build/qualcomm/build/sstate-cache'"
}

@test "set: setting the SAME name again replaces the line in place, not appends" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 0
	[ "$(conf | grep -c '^MACKAS_USE_NFS_MIRRORS=')" -eq 1 ]
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='0'"
}

@test "set: preserves every other line in the file untouched" {
	cat > "$HOME/.mackas.conf" <<'CONF'
# a hand-written comment
MACKAS_ROOT=/Volumes/Foto/temp/mackas
CONF
	run "$MACKAS" set MACKAS_CPUS 8
	[ "$status" -eq 0 ]
	conf | grep -qF '# a hand-written comment'
	conf | grep -qF 'MACKAS_ROOT=/Volumes/Foto/temp/mackas'
	conf | grep -qF "MACKAS_CPUS='8'"
}

@test "set: refuses an unknown setting name" {
	run "$MACKAS" set NOT_A_REAL_SETTING x
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a mackas setting'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: refuses a value with a double quote (would corrupt the file it writes)" {
	run "$MACKAS" set MACKAS_ROOT 'bad"value'
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'double quote'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: a value with spaces, a dollar sign and an apostrophe round-trips" {
	run "$MACKAS" set MACKAS_ROOT "/Volumes/My Disk/o'brien \$HOME"
	[ "$status" -eq 0 ]
	# Written through shq(): single-quoted, so $HOME must NOT expand when the
	# file is later sourced -- assert the literal, unexpanded text is there.
	conf | grep -qF '$HOME'
	run "$MACKAS" get MACKAS_ROOT
	[ "$output" = "/Volumes/My Disk/o'brien \$HOME" ]
}

@test "set --dry-run changes nothing on disk" {
	run "$MACKAS" --dry-run set MACKAS_USE_NFS_MIRRORS 1
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: wrong argument count is refused" {
	run "$MACKAS" set MACKAS_USE_NFS_MIRRORS
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'needs exactly NAME and VALUE'
}

@test "get: reads back a persisted setting" {
	"$MACKAS" set MACKAS_SSTATE_MIRROR_PATH /Volumes/rogue-build/qualcomm/build/sstate-cache
	run "$MACKAS" get MACKAS_SSTATE_MIRROR_PATH
	[ "$status" -eq 0 ]
	[ "$output" = "/Volumes/rogue-build/qualcomm/build/sstate-cache" ]
}

@test "get: resolves through the full precedence chain, --set still wins" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	run "$MACKAS" --set MACKAS_USE_NFS_MIRRORS=99 get MACKAS_USE_NFS_MIRRORS
	[ "$status" -eq 0 ]
	[ "$output" = "99" ]
}

@test "get: refuses an unknown setting name" {
	run "$MACKAS" get NOT_A_REAL_SETTING
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a mackas setting'
}

@test "unset: removes a persisted setting" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	"$MACKAS" set MACKAS_SSTATE_MIRROR_PATH /some/path
	run "$MACKAS" unset MACKAS_SSTATE_MIRROR_PATH
	[ "$status" -eq 0 ]
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='1'"
	! conf | grep -qF 'MACKAS_SSTATE_MIRROR_PATH'
}

@test "unset: a name that was never persisted is a no-op, not an error" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	run "$MACKAS" unset MACKAS_SSTATE_MIRROR_PATH
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'nothing to do'
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='1'"
}

@test "unset: no config file at all is also a no-op, not an error" {
	run "$MACKAS" unset MACKAS_USE_NFS_MIRRORS
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'nothing to do'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "unset: does not remove a DIFFERENT setting whose name shares a suffix" {
	# Regression guard: the removal match is anchored ('NAME='*, a case glob
	# against the whole line), not a substring grep -- MACKAS_DL_MIRROR_PATH
	# must survive unsetting something that merely ends the same way.
	printf 'MACKAS_OLD_MACKAS_DL_MIRROR_PATH=bogus\nMACKAS_DL_MIRROR_PATH=/real/path\n' > "$HOME/.mackas.conf"
	run "$MACKAS" unset MACKAS_DL_MIRROR_PATH
	[ "$status" -eq 0 ]
	conf | grep -qF 'MACKAS_OLD_MACKAS_DL_MIRROR_PATH=bogus'
	! conf | grep -qF 'MACKAS_DL_MIRROR_PATH=/real/path'
}

@test "set/get/unset: --help, 'help X' and 'X help' all print usage without side effects" {
	run "$MACKAS" set --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'persist one setting'

	run "$MACKAS" help set
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'persist one setting'

	run "$MACKAS" set help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'persist one setting'

	run "$MACKAS" get --help
	printf '%s\n' "$output" | grep -qF "resolved value"

	run "$MACKAS" unset --help
	printf '%s\n' "$output" | grep -qF 'Removes NAME'

	[ ! -f "$HOME/.mackas.conf" ]
}

# ---------------------------------------------------------------------------
# --config in scope: switching between per-project config files during the
# day is a real, desired workflow -- set/get/unset must operate on WHATEVER
# config file this invocation is actually pointed at, including one that
# does not exist yet (that is exactly how a brand new project's config gets
# created), never silently fall back to ~/.mackas.conf once --config names
# something else.
# ---------------------------------------------------------------------------

@test "set --config NEWFILE bootstraps a config file that does not exist yet" {
	local newconf="$TESTDIR/qcom.conf"
	run "$MACKAS" --config "$newconf" set MACKAS_PROJECT_DIR meta-qcom
	[ "$status" -eq 0 ]
	[ -f "$newconf" ]
	grep -qF "MACKAS_PROJECT_DIR='meta-qcom'" "$newconf"
	# The default target must be untouched -- this went to --config, not ~/.
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set --config NEWFILE: a second call targets the SAME file, not ~/.mackas.conf" {
	local newconf="$TESTDIR/qcom.conf"
	"$MACKAS" --config "$newconf" set MACKAS_PROJECT_DIR meta-qcom
	run "$MACKAS" --config "$newconf" set MACKAS_USE_NFS_MIRRORS 1
	[ "$status" -eq 0 ]
	grep -qF "MACKAS_PROJECT_DIR='meta-qcom'" "$newconf"
	grep -qF "MACKAS_USE_NFS_MIRRORS='1'" "$newconf"
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set --config: two different project configs stay independent" {
	local qcom="$TESTDIR/qcom.conf" ai="$TESTDIR/ai.conf"
	"$MACKAS" --config "$qcom" set MACKAS_PROJECT_DIR meta-qcom
	"$MACKAS" --config "$ai" set MACKAS_PROJECT_DIR meta-ai
	grep -qF "meta-qcom" "$qcom"
	grep -qF "meta-ai" "$ai"
	! grep -qF "meta-ai" "$qcom"
	! grep -qF "meta-qcom" "$ai"
}

@test "get --config NEWFILE reads back through the file it was just bootstrapped into" {
	local newconf="$TESTDIR/qcom.conf"
	"$MACKAS" --config "$newconf" set MACKAS_PROJECT_DIR meta-qcom
	run "$MACKAS" --config "$newconf" get MACKAS_PROJECT_DIR
	[ "$status" -eq 0 ]
	[ "$output" = "meta-qcom" ]
}

@test "get --config on a config file that still does not exist resolves to the built-in default, not an error" {
	run "$MACKAS" --config "$TESTDIR/never-created.conf" get MACKAS_PROJECT_DIR
	[ "$status" -eq 0 ]
	[ "$output" = "meta-ai" ]
}

@test "a genuinely missing --config still refuses OTHER commands (not a typo silently ignored)" {
	run "$MACKAS" --config "$TESTDIR/does-not-exist.conf" check
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'config file not readable'
}

@test "an existing but permission-denied --config still refuses set (not treated as 'create it')" {
	local locked="$TESTDIR/locked.conf"
	: > "$locked"
	chmod 000 "$locked"
	run "$MACKAS" --config "$locked" set MACKAS_CPUS 4
	chmod 600 "$locked"   # so teardown's rm -rf can clean up
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'config file not readable'
}

# ---------------------------------------------------------------------------
# Fable CLI-consistency review: 'get' accepting --dry-run/-y/-v (it used to
# accept NONE of them, failing with a misleading "needs exactly one NAME, got
# 2 arguments" instead of just ignoring a habitual flag), and 'set' only
# treating a bare 'help' as a help request in NAME's position, never VALUE's.
# ---------------------------------------------------------------------------

@test "get accepts --dry-run/-y/-v after NAME without complaint (it reads only, so they are no-ops)" {
	"$MACKAS" set MACKAS_MEMORY 48g

	run "$MACKAS" get MACKAS_MEMORY -v
	[ "$status" -eq 0 ]
	[ "$output" = "48g" ]

	run "$MACKAS" get MACKAS_MEMORY -y
	[ "$status" -eq 0 ]
	[ "$output" = "48g" ]

	run "$MACKAS" --dry-run get MACKAS_MEMORY
	[ "$status" -eq 0 ]
	[ "$output" = "48g" ]
}

@test "set's VALUE may literally be the string 'help' once NAME is already given" {
	# Regression: cmd_set used to match bare 'help' ANYWHERE in its
	# arguments, so 'mackas set NAME help' silently printed usage instead
	# of persisting the value "help".
	run "$MACKAS" set MACKAS_SMOKETEST_TARGETS help
	[ "$status" -eq 0 ]
	conf | grep -qF "MACKAS_SMOKETEST_TARGETS='help'"

	run "$MACKAS" get MACKAS_SMOKETEST_TARGETS
	[ "$output" = "help" ]
}

@test "'set help' (no NAME yet) still means help, not a malformed set" {
	run "$MACKAS" set help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'persist one setting'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "the general usage() lists set, get and unset" {
	run "$MACKAS" --help
	printf '%s\n' "$output" | grep -qE '^\s+set\s'
	printf '%s\n' "$output" | grep -qE '^\s+get\s'
	printf '%s\n' "$output" | grep -qE '^\s+unset\s'
}
