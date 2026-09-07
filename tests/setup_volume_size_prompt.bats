#!/usr/bin/env bats
#
# setup's interactive volume-size prompts (prompt_setup_settings) must never
# ask for the size of a volume that already exists -- ensure_volume() ignores
# the size argument entirely once a volume exists, so a size typed at that
# prompt is silently discarded a few steps later. That is exactly what a
# reused --set MACKAS_VOLUME_DL_NAME=<existing volume> setup hit in real use:
# `mackas status` already showed oe-build-dl at cap 200G / 52G on disk, and
# `setup` still asked "Downloads volume size [40G]:" as though nothing was
# there.
#
# bats' `run` never attaches a tty, so prompt_setup_settings() itself (gated
# on `[ -t 0 ]`) cannot be exercised hermetically here -- same limitation
# every other confirm()-gated test in this suite already lives with (see
# project_add.bats's own note on this). These tests instead pin the two
# pieces of logic prompt_setup_settings delegates to directly:
#   volume_already_provisioned() -- can we even TELL the volume exists yet
#   skipped_size_prompt_note()   -- the message printed instead of asking,
#                                   which must say "reusing it as requested"
#                                   only when the user actually asked for
#                                   that specific volume by name, never for
#                                   a volume that merely already exists from
#                                   an earlier run of this same project.
# Plus one source-grep pinning that prompt_setup_settings() actually calls
# volume_already_provisioned() for all three volumes, so a future edit that
# reverts the integration (while leaving the two helpers themselves intact)
# still fails a test.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

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

	mkdir -p "$TESTDIR/fakebin"
	FAKE_CONTAINER="$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

# write_fake_container DOWN EXISTING_VOLUME -- a minimal container answering
# only what volume_already_provisioned() needs: "system status" for
# container_running(), "volume ls" for volume_exists(). DOWN=1 makes system
# status fail outright (the daemon simply not started -- same modelling
# tests/volume_mgmt.bats and tests/exec.bats use for it). EXISTING_VOLUME,
# if non-empty, is the one name volume_exists() will report as present.
write_fake_container() {
	local down="$1" existing="${2:-}"
	cat > "$FAKE_CONTAINER" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
	"system status")
		[ "$down" = "1" ] && exit 1
		echo "status running"; exit 0 ;;
	"volume ls")
		echo "NAME TYPE DRIVER OPTIONS"
		[ -n "$existing" ] && echo "$existing  named  local  size=100G"
		exit 0 ;;
esac
exit 0
EOF
	chmod +x "$FAKE_CONTAINER"
}

# ---------------------------------------------------------------------------
# volume_already_provisioned()
# ---------------------------------------------------------------------------

@test "volume_already_provisioned: true when the daemon is up and the volume is listed" {
	write_fake_container 0 "oe-build-dl"
	if volume_already_provisioned "oe-build-dl"; then ok=1; else ok=0; fi
	[ "$ok" -eq 1 ]
}

@test "volume_already_provisioned: false when the daemon is up but the volume is NOT listed" {
	write_fake_container 0 "some-other-volume"
	if volume_already_provisioned "oe-build-dl"; then ok=1; else ok=0; fi
	[ "$ok" -eq 0 ]
}

@test "volume_already_provisioned: false (unknown, not 'does not exist') when the daemon is down" {
	# Mutation-control shape: the fake WOULD list oe-build-dl were it asked,
	# proving this is the daemon-down check firing, not an empty volume list.
	write_fake_container 1 "oe-build-dl"
	if volume_already_provisioned "oe-build-dl"; then ok=1; else ok=0; fi
	[ "$ok" -eq 0 ]
}

# ---------------------------------------------------------------------------
# skipped_size_prompt_note() -- the message itself
# ---------------------------------------------------------------------------

@test "skipped_size_prompt_note: explicit override -> says 'reusing it as requested' and names the setting" {
	__EXPLICIT_MACKAS_VOLUME_DL_NAME=1
	local out; out="$(skipped_size_prompt_note "Downloads" "oe-build-dl" MACKAS_VOLUME_DL_NAME)"
	printf '%s\n' "$out" | grep -qF "reusing it as requested (MACKAS_VOLUME_DL_NAME)"
	printf '%s\n' "$out" | grep -qF "oe-build-dl"
}

@test "skipped_size_prompt_note: no explicit override -> says 'from an earlier setup', never claims reuse" {
	unset __EXPLICIT_MACKAS_VOLUME_DL_NAME
	local out; out="$(skipped_size_prompt_note "Downloads" "mackas-demo-dl" MACKAS_VOLUME_DL_NAME)"
	printf '%s\n' "$out" | grep -qF "from an earlier setup"
	! printf '%s\n' "$out" | grep -qF "reusing it as requested"
}

@test "skipped_size_prompt_note: a config-file-pinned (not just --set) override still reads as explicit" {
	# config_pinned_setting() falls back to grepping CONFIG_FILE_USED when
	# __EXPLICIT_ alone says no -- MACKAS_VOLUME_NAME's own factory-default
	# collision is the reason that fallback exists at all (mackas's own
	# config_pinned_setting() comment). Prove the DL/SSTATE settings this
	# function actually serves take that same path, not just __EXPLICIT_.
	local cfg="$TESTDIR/pinned.conf"
	printf "MACKAS_VOLUME_SSTATE_NAME='oe-build-sstate'\n" > "$cfg"
	CONFIG_FILE_USED="$cfg"
	unset __EXPLICIT_MACKAS_VOLUME_SSTATE_NAME
	local out; out="$(skipped_size_prompt_note "sstate" "oe-build-sstate" MACKAS_VOLUME_SSTATE_NAME)"
	printf '%s\n' "$out" | grep -qF "reusing it as requested"
}

@test "skipped_size_prompt_note: names 'mackas volume resize' as the real way to grow it" {
	unset __EXPLICIT_MACKAS_VOLUME_SIZE_TMP
	local out; out="$(skipped_size_prompt_note "TMPDIR" "oe-build-tmp" MACKAS_VOLUME_NAME)"
	printf '%s\n' "$out" | grep -qF "volume resize"
}

# ---------------------------------------------------------------------------
# Integration: prompt_setup_settings() actually calls volume_already_provisioned
# for all three volumes, not just some of them. Source-grep, per AGENTS.md's
# rule for logic a hermetic runtime test cannot reach ([ -t 0 ] is untestable
# here) -- see this file's header note and project_add.bats's own precedent.
# ---------------------------------------------------------------------------

@test "prompt_setup_settings: gates all three size prompts on volume_already_provisioned (source-grep)" {
	local body
	body="$(awk '/^prompt_setup_settings\(\) \{/,/^}/' "$MACKAS")"
	printf '%s\n' "$body" | grep -qF 'volume_already_provisioned "$MACKAS_VOL_TMP"'
	printf '%s\n' "$body" | grep -qF 'volume_already_provisioned "$MACKAS_VOL_DL"'
	printf '%s\n' "$body" | grep -qF 'volume_already_provisioned "$MACKAS_VOL_SSTATE"'
}
