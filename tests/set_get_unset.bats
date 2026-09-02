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
	unset MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
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

# ---------------------------------------------------------------------------
# set-time validation (issue #106): refuse_unwritable_setting_value() above
# only catches characters that would corrupt the file itself (", `, control
# chars) -- it does NOT run the per-setting shape checks validate_settings()
# enforces on every other command (no whitespace in a volume name, integer-
# only CPUS/MONITOR_PORT, the MEMORY/VOLUME_SIZE_* size shape). Before this
# fix, a value that failed one of THOSE checks still wrote successfully, and
# every LATER mackas invocation -- including `unset`, the only in-tool way
# back -- died in main()'s unconditional validate_settings before dispatch
# ever reached it. cmd_set now runs that same validation before writing, so
# a bad value is refused up front and there is nothing left to be locked out
# of.
# ---------------------------------------------------------------------------

@test "set: refuses a volume name with whitespace and writes nothing (issue #106)" {
	run "$MACKAS" set MACKAS_VOLUME_DL_NAME "a b"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'contains whitespace'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: a refused value never locks a later command out, including unset (issue #106)" {
	run "$MACKAS" set MACKAS_VOLUME_DL_NAME "a b"
	[ "$status" -ne 0 ]

	# This is the lockout the issue describes: before the fix, the write
	# above would have succeeded, and both of these would then die in
	# validate_settings instead of running normally.
	run "$MACKAS" status
	[ "$status" -eq 0 ]

	run "$MACKAS" unset MACKAS_VOLUME_DL_NAME
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'nothing to do'
}

@test "set: refuses a non-integer MACKAS_CPUS" {
	run "$MACKAS" set MACKAS_CPUS abc
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a positive integer'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: refuses a malformed MACKAS_MEMORY" {
	run "$MACKAS" set MACKAS_MEMORY 8x
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a size like 8g, 512m or 16'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: refuses a non-integer MACKAS_MONITOR_PORT" {
	run "$MACKAS" set MACKAS_MONITOR_PORT abc
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a positive integer'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: refuses a malformed MACKAS_VOLUME_SIZE_TMP" {
	run "$MACKAS" set MACKAS_VOLUME_SIZE_TMP big
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'is not a size like 1T, 200G or 512M'
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set: valid values for every newly-checked setting still succeed" {
	run "$MACKAS" set MACKAS_VOLUME_DL_NAME mackas-shared-dl
	[ "$status" -eq 0 ]
	run "$MACKAS" set MACKAS_CPUS 8
	[ "$status" -eq 0 ]
	run "$MACKAS" set MACKAS_MEMORY 48g
	[ "$status" -eq 0 ]
	run "$MACKAS" set MACKAS_MONITOR_PORT 9001
	[ "$status" -eq 0 ]
	run "$MACKAS" set MACKAS_VOLUME_SIZE_TMP 200G
	[ "$status" -eq 0 ]

	conf | grep -qF "MACKAS_VOLUME_DL_NAME='mackas-shared-dl'"
	conf | grep -qF "MACKAS_CPUS='8'"
	conf | grep -qF "MACKAS_MEMORY='48g'"
	conf | grep -qF "MACKAS_MONITOR_PORT='9001'"
	conf | grep -qF "MACKAS_VOLUME_SIZE_TMP='200G'"
}

@test "set --dry-run changes nothing on disk" {
	run "$MACKAS" --dry-run set MACKAS_USE_NFS_MIRRORS 1
	[ "$status" -eq 0 ]
	[ ! -f "$HOME/.mackas.conf" ]
}

@test "set --dry-run reports 'would write', not 'written'" {
	run "$MACKAS" --dry-run set MACKAS_USE_NFS_MIRRORS 1
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'would write MACKAS_USE_NFS_MIRRORS=1'
	! printf '%s\n' "$output" | grep -qF 'MACKAS_USE_NFS_MIRRORS=1 written'
}

@test "set --dry-run leaves no mackas-conf.* tempfile behind in TMPDIR" {
	# config_write_setting() always mktemp's a scratch file; the final mv onto
	# the real config is run()-gated (never executes under --dry-run), so the
	# function must clean the scratch file up itself or it leaks forever.
	local scratch; scratch="$(make_tmpdir)"
	local old_tmpdir="${TMPDIR:-}"
	export TMPDIR="$scratch"
	run "$MACKAS" --dry-run set MACKAS_USE_NFS_MIRRORS 1
	if [ -n "$old_tmpdir" ]; then export TMPDIR="$old_tmpdir"; else unset TMPDIR; fi
	[ "$status" -eq 0 ]
	[ -z "$(find "$scratch" -name 'mackas-conf.*')" ]
}

@test "unset --dry-run reports 'would remove', not 'removed'" {
	"$MACKAS" set MACKAS_USE_NFS_MIRRORS 1
	run "$MACKAS" --dry-run unset MACKAS_USE_NFS_MIRRORS
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'would remove MACKAS_USE_NFS_MIRRORS'
	assert_fails grep -qF 'MACKAS_USE_NFS_MIRRORS removed' <<< "$output"
	conf | grep -qF "MACKAS_USE_NFS_MIRRORS='1'"
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

@test "set/get/unset: MACKAS_VOLUME_DL_NAME round-trips and unsets back to the derived default" {
	# Registering a setting is a four-place operation; missing SETTING_NAMES
	# is what makes set/get/unset reject it outright.
	run "$MACKAS" set MACKAS_VOLUME_DL_NAME mackas-shared-dl
	[ "$status" -eq 0 ]
	conf | grep -qF "MACKAS_VOLUME_DL_NAME='mackas-shared-dl'"

	run "$MACKAS" get MACKAS_VOLUME_DL_NAME
	[ "$status" -eq 0 ]
	[ "$output" = "mackas-shared-dl" ]

	run "$MACKAS" unset MACKAS_VOLUME_DL_NAME
	[ "$status" -eq 0 ]
	assert_fails grep -qF 'MACKAS_VOLUME_DL_NAME' "$HOME/.mackas.conf"

	# Empty again: the default is "derive from MACKAS_VOLUME_NAME".
	run "$MACKAS" get MACKAS_VOLUME_DL_NAME
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "set/get/unset: MACKAS_VOLUME_SSTATE_NAME round-trips and unsets back to the derived default" {
	run "$MACKAS" set MACKAS_VOLUME_SSTATE_NAME mackas-shared-sstate
	[ "$status" -eq 0 ]
	conf | grep -qF "MACKAS_VOLUME_SSTATE_NAME='mackas-shared-sstate'"

	run "$MACKAS" get MACKAS_VOLUME_SSTATE_NAME
	[ "$status" -eq 0 ]
	[ "$output" = "mackas-shared-sstate" ]

	run "$MACKAS" unset MACKAS_VOLUME_SSTATE_NAME
	[ "$status" -eq 0 ]
	assert_fails grep -qF 'MACKAS_VOLUME_SSTATE_NAME' "$HOME/.mackas.conf"

	run "$MACKAS" get MACKAS_VOLUME_SSTATE_NAME
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
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
	run "$MACKAS" --config "$TESTDIR/never-created.conf" get MACKAS_VOLUME_SIZE_TMP
	[ "$status" -eq 0 ]
	[ "$output" = "120G" ]
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
