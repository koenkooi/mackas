#!/usr/bin/env bats
#
# M3 slice 1 (issue #77): selector-derived volume names, and the
# precedence-and-warn rule around them.
#
#   1. Selecting a project (--project NAME / $MACKAS_PROJECT_SELECT) defaults
#      the volume stem to mackas-<name>, giving mackas-<name>-tmp/-dl/-sstate.
#   2. This is a DEFAULT, not a fifth precedence rung: an explicit
#      MACKAS_VOLUME_NAME / MACKAS_VOLUME_DL_NAME / MACKAS_VOLUME_SSTATE_NAME
#      -- from the config file, the environment, or --set -- always wins.
#      The defaults -> config -> environment -> --set chain is unchanged.
#   3. When an explicit value disagrees with what the selector would have
#      derived, `status` prints one informational note. It must say what is
#      set, what would have been derived, and that the explicit value is
#      honoured -- never phrased as an error or a "fix this".
#
# tests/multi_project_compat.bats is the sibling contract proving an
# UNSELECTED invocation is completely untouched by any of this -- these
# tests are the SELECTED side of the same feature and must never contradict
# it.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR
	export HOME="$TESTDIR/home"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"

	ROOT="$TESTDIR/oe"

	# Same fake as multi_project_compat.bats/project_select.bats: `status`
	# asks the daemon for a volume's live cap, and a real dev-Mac daemon
	# would answer with real, unrelated state.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") echo "NAME TYPE DRIVER OPTIONS"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	chmod -R u+rwX "$TESTDIR" 2>/dev/null || true
	rm -rf "$TESTDIR"
}

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# The exact runtime-args mount fragment -- see multi_project_compat.bats'
# own comment on mk_runtime_args for why this is the lightest black-box hook
# onto MACKAS_VOL_TMP/DL/SSTATE.
mk_runtime_args() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		"$@" runtime-args
}

mk_status() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		"$@" status
}

assert_volumes() {
	local tmp="$1" dl="$2" sstate="$3"
	printf '%s\n' "$output" | grep -qF -- "-v ${tmp}:/build -e KAS_BUILD_DIR=/build"
	printf '%s\n' "$output" | grep -qF -- "-v ${dl}:/downloads -e DL_DIR=/downloads"
	printf '%s\n' "$output" | grep -qF -- "-v ${sstate}:/sstate -e SSTATE_DIR=/sstate"
}

refute_output_containing() {
	if printf '%s\n' "$output" | grep -qF -- "$1"; then
		printf 'expected the output NOT to mention: %s\n--- output ---\n%s\n' \
			"$1" "$output" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# 1. Derivation under a selector: no override anywhere -> mackas-<name>-*
# ---------------------------------------------------------------------------

@test "selected project with no volume-name override derives mackas-<name>-{tmp,dl,sstate}" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes mackas-meta-ai-tmp mackas-meta-ai-dl mackas-meta-ai-sstate
}

@test "\$MACKAS_PROJECT_SELECT derives the same names as --project" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	MACKAS_PROJECT_SELECT=meta-ai mk_runtime_args
	[ "$status" -eq 0 ]
	assert_volumes mackas-meta-ai-tmp mackas-meta-ai-dl mackas-meta-ai-sstate
}

@test "a not-yet-pinned project selected via --project (set/get path) still derives the same stem" {
	# 'set' is allowed to target a pinned config that does not exist yet
	# (load_config's allow_missing path) -- runtime-args is not one of those
	# three commands, so pin the file for real here, empty, to isolate just
	# the derivation with nothing else in play.
	pin brand-new <<-'EOF'
	EOF
	mk_runtime_args --project brand-new
	[ "$status" -eq 0 ]
	assert_volumes mackas-brand-new-tmp mackas-brand-new-dl mackas-brand-new-sstate
}

# ---------------------------------------------------------------------------
# 2. Each explicit override beats derivation -- a default, never a rung.
# ---------------------------------------------------------------------------

@test "an explicit MACKAS_VOLUME_NAME in the pinned config beats the derived stem entirely" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="custom-stem"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes custom-stem-tmp custom-stem-dl custom-stem-sstate
	refute_output_containing "mackas-meta-ai"
}

@test "THE HAZARD CASE: MACKAS_VOLUME_NAME=oe-build (byte-identical to the factory default) still wins over derivation" {
	# mark_explicit_from_config() can only compare VALUES against the
	# factory default -- and the factory default for MACKAS_VOLUME_NAME is
	# the non-empty string "oe-build", so a config that pins exactly that
	# value (migration path B of #72: keep oe-build-*, no data move) is
	# byte-identical to "never touched it". If derivation trusted
	# setting_is_explicit() alone, this is exactly the config it would
	# silently steamroll. config_pinned_setting() exists to close this gap
	# by grepping the actual file; this is the test that would catch its
	# regression.
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes oe-build-tmp oe-build-dl oe-build-sstate
	refute_output_containing "mackas-meta-ai"
}

@test "an explicit MACKAS_VOLUME_DL_NAME beats only the dl slice; tmp and sstate still derive" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes mackas-meta-ai-tmp shared-dl mackas-meta-ai-sstate
}

@test "an explicit MACKAS_VOLUME_SSTATE_NAME beats only the sstate slice; tmp and dl still derive" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_SSTATE_NAME="shared-sstate"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes mackas-meta-ai-tmp mackas-meta-ai-dl shared-sstate
}

@test "the environment rung still beats derivation under a selector" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	MACKAS_VOLUME_NAME=from-env mk_runtime_args --project meta-ai
	[ "$status" -eq 0 ]
	assert_volumes from-env-tmp from-env-dl from-env-sstate
}

@test "--set still beats everything, including the selector-derived default" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="from-config"
	EOF
	mk_runtime_args --project meta-ai --set MACKAS_VOLUME_NAME=from-cli
	[ "$status" -eq 0 ]
	assert_volumes from-cli-tmp from-cli-dl from-cli-sstate
}

@test "the three-way collision check still fires against a derived name" {
	# MACKAS_VOL_DL is pinned to literally what MACKAS_VOL_TMP would derive
	# to under this selector -- the invariant-3 guard must still catch it
	# even though tmp's own name only exists because of the new default.
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-meta-ai-tmp"
	EOF
	mk_runtime_args --project meta-ai
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "mackas-meta-ai-tmp"
}

# ---------------------------------------------------------------------------
# 3. The disagreement note: status, once, informational.
# ---------------------------------------------------------------------------

@test "status shows no note when the selected project has no override (agreement)" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	refute_output_containing "note:"
}

@test "status shows no note at all for an unselected invocation" {
	mk_status
	[ "$status" -eq 0 ]
	refute_output_containing "note:"
}

@test "status shows exactly one note when MACKAS_VOLUME_NAME disagrees with the derived stem" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	local n
	n="$(printf '%s\n' "$output" | grep -c 'note:')"
	[ "$n" -eq 1 ]
	printf '%s\n' "$output" | grep -qF "oe-build-tmp"
	printf '%s\n' "$output" | grep -qF "mackas-meta-ai-tmp"
}

@test "the note names what is set and what would have been derived, for every disagreeing slice" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE 'tmp.*oe-build-tmp.*mackas-meta-ai-tmp'
	printf '%s\n' "$output" | grep -qE 'dl.*oe-build-dl.*mackas-meta-ai-dl'
	printf '%s\n' "$output" | grep -qE 'sstate.*oe-build-sstate.*mackas-meta-ai-sstate'
}

@test "the note fires for a lone MACKAS_VOLUME_DL_NAME override too, mentioning only the dl slice" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	local n
	n="$(printf '%s\n' "$output" | grep -c 'note:')"
	[ "$n" -eq 1 ]
	printf '%s\n' "$output" | grep -qF "shared-dl"
	# tmp and sstate agree with derivation -- neither should be named as a
	# mismatch. "tmp     set:" is the note's own per-line prefix, distinct
	# from the "MACKAS_VOLUME_SIZE_TMP" settings line above it in the same
	# output, so this cannot false-match on an unrelated line.
	! printf '%s\n' "$output" | grep -q 'tmp     set:'
	! printf '%s\n' "$output" | grep -q 'sstate  set:'
}

@test "the note reads as informational, never as an error or a suggestion to change anything" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'not an error'
	printf '%s\n' "$output" | grep -qi 'supported choice'
	# "not an error" is deliberate, reassuring wording -- what must never
	# appear is a scold or a suggestion to change something.
	! printf '%s\n' "$output" | grep -qiE '\b(invalid|wrong|fix|should)\b'
}

@test "an explicit override that happens to AGREE with the derived name shows no note" {
	# Same literal value the derivation would have produced anyway --
	# nothing to warn about, even though it came from the config file.
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="mackas-meta-ai"
	EOF
	mk_status --project meta-ai
	[ "$status" -eq 0 ]
	refute_output_containing "note:"
}
