#!/usr/bin/env bats
#
# THE M3 COMPATIBILITY CONTRACT (issue #77).
#
# M3 teaches mackas to derive mackas-<name>-* volume names from the project
# SELECTOR (--project / $MACKAS_PROJECT_SELECT), on top of the selector M2
# already added as a read-only chooser of WHICH config file load_config()
# sources (see tests/project_select.bats). #77 calls M3
# "backward-compatibility-critical" and "high risk", and requires this exact
# guarantee to be written FIRST, before any of M3's feature code, and to be
# mutation-tested: airtight.
#
# The guarantee, in one sentence: an invocation that never mentions the
# selector -- no --project, no $MACKAS_PROJECT_SELECT, no pinned config
# selected -- resolves EXACTLY what it resolves today, byte for byte, no
# matter what pinned projects happen to exist on disk or what
# MACKAS_PROJECT_DIR happens to be named. Per #72's core architectural rule,
# volume identity keys off the SELECTOR and NEVER off MACKAS_PROJECT_DIR --
# every existing user already has MACKAS_PROJECT_DIR set, so keying off it
# would silently relocate their volumes mid-session the moment M3 landed.
#
# DO NOT RELAX ANY ASSERTION BELOW TO MAKE A LATER CHANGE PASS. If a later
# M3 commit needs one of these to change, that is a sign the change broke
# the compatibility contract, not a sign the test was wrong. These tests
# describe behaviour that ALREADY EXISTS on this branch, before any M3
# feature code -- every one of them must pass right now.

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

	# Same reason project_select.bats fakes it: `status` asks the daemon for
	# a volume's live cap, and a dev Mac with real oe-build-* volumes would
	# answer with real state in tests that are about config resolution. The
	# legacy-volume check needs 'volume ls' to actually list one, so this
	# fake reports "oe-build" as present -- every OTHER name reads as absent,
	# which is exactly what "the derived names are the old ones" needs to be
	# able to observe on the status side too.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") printf 'NAME TYPE DRIVER OPTIONS\noe-build\n'; exit 0 ;;
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

# Read one setting out of `mackas status` output (same helper as
# project_select.bats).
setting() {
	printf '%s\n' "$output" | awk -v k="$1" '$1 == k { $1=""; sub(/^ +/,""); print; exit }'
}

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# The exact runtime-args mount fragment for a given stem, --set on the
# command line so no config file or environment is involved. `runtime-args`
# is a pure, read-only query (cmd_runtime_args) -- it derives and prints
# kas_runtime_args() without needing a real checkout or a running container,
# so it is the lightest black-box hook onto MACKAS_VOL_TMP/DL/SSTATE: it
# prints exactly the -v flags a real build would hand kas-container.
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

assert_default_volume_names() {
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-tmp:/build -e KAS_BUILD_DIR=/build'
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-dl:/downloads -e DL_DIR=/downloads'
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate'
}

# ---------------------------------------------------------------------------
# 1. The baseline: no selector, MACKAS_PROJECT_DIR=meta-ai, no pinned
#    projects on disk at all. This is every existing user's setup today.
# ---------------------------------------------------------------------------

@test "compat: no selector, MACKAS_PROJECT_DIR=meta-ai -- volumes resolve to oe-build-* (black box, runtime-args)" {
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	assert_default_volume_names
}

@test "compat: no selector -- MACKAS_VOL_LEGACY resolves to oe-build (black box, status)" {
	mk_status --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  \[old\] oe-build( |$)'
}

@test "compat: no selector -- internal variables agree with the black-box reading, exactly" {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	SCRIPT_NAME="mackas"
	setup_colors
	set_defaults
	MACKAS_ROOT="$ROOT"
	MACKAS_PROJECT_DIR="meta-ai"
	derive_paths
	[ "$MACKAS_VOL_TMP" = "oe-build-tmp" ]
	[ "$MACKAS_VOL_DL" = "oe-build-dl" ]
	[ "$MACKAS_VOL_SSTATE" = "oe-build-sstate" ]
	[ "$MACKAS_VOL_LEGACY" = "oe-build" ]
}

@test "compat: no selector -- work/ stays flat: MACKAS_WORK and the project checkout are NOT namespaced under a project name" {
	mk_status --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	# "kas work dir"/"project checkout" are multi-word status labels, not
	# single-token settings -- setting() (built for the SETTING_NAMES loop's
	# one-word keys) cannot address them, so match the whole line by hand,
	# same style as project_select.bats' "project selected" grep: anchored,
	# flexible on the show()-padded whitespace between label and value.
	printf '%s\n' "$output" | grep -qE "^  kas work dir +${ROOT}/work\$"
	printf '%s\n' "$output" | grep -qE "^  project checkout +${ROOT}/work/meta-ai\$"
}

# ---------------------------------------------------------------------------
# 2. Pinned configs EXIST in projects_dir(), but none is selected. This is
#    the case that will actually regress the moment M3 wires the selector
#    into volume-name derivation: merely having pinned SOMETHING must not
#    change an invocation that never asked for it.
# ---------------------------------------------------------------------------

@test "compat: pinned projects exist on disk but none is selected -- volumes still oe-build-*" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-pin.yml"
	EOF
	pin another-project <<-'EOF'
	MACKAS_MEMORY="8g"
	EOF
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	assert_default_volume_names
}

@test "compat: pinned projects exist but none is selected -- status shows no selected project and the default config file" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-pin.yml"
	EOF
	mk_status --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
	# "config file" is a multi-word status label -- same reasoning as the
	# work/-layout test above for why setting() cannot address it.
	printf '%s\n' "$output" | grep -qE '^  config file +<none: built-in defaults>$'
	# The pinned file's own setting must NOT have been sourced -- proof that
	# its mere presence on disk had zero effect, not just that the volume
	# names happen to still match.
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

# ---------------------------------------------------------------------------
# 3. The sharpest edge: MACKAS_PROJECT_DIR looks like a plausible project
#    name, INCLUDING one that matches an existing pinned config's name --
#    with no selector in play. This is the direct test of #72's core rule:
#    volume identity keys off the SELECTOR, never off MACKAS_PROJECT_DIR.
# ---------------------------------------------------------------------------

@test "compat: MACKAS_PROJECT_DIR matches a pinned config's name, but no selector was given -- still oe-build-*" {
	# meta-ai.conf pins its OWN volume-affecting setting (MACKAS_VOLUME_NAME).
	# If mackas ever keyed derivation off MACKAS_PROJECT_DIR instead of the
	# selector, this is exactly the config that would silently leak in and
	# relocate the volumes -- so this pin is deliberately loud were it read.
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="pinned-meta-ai-should-never-be-read"
	EOF
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	assert_default_volume_names
	refute_output 'pinned-meta-ai-should-never-be-read'
}

@test "compat: MACKAS_PROJECT_DIR matches a pinned config's name -- status confirms it was never sourced" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="pinned-meta-ai-should-never-be-read"
	EOF
	mk_status --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_NAME)" = "oe-build" ]
	! printf '%s\n' "$output" | grep -q 'project selected'
}

@test "compat: a handful of plausible-looking MACKAS_PROJECT_DIR values, none selected -- all resolve oe-build-*" {
	local dir
	for dir in meta-ai meta-angstrom mackas-foo project the-selector-name work; do
		pin "$dir" <<-EOF
		MACKAS_VOLUME_NAME="wrong-for-$dir"
		EOF
		mk_runtime_args --set "MACKAS_PROJECT_DIR=$dir"
		[ "$status" -eq 0 ]
		assert_default_volume_names
		refute_output "wrong-for-$dir"
	done
}

# refute_output: assert $1 is absent from the last `run`'s $output. A bare
# `! ... | grep -q` is only safe as a test's final line (see helpers.bash's
# assert_fails comment) -- this is the non-final-line-safe form.
refute_output() {
	if printf '%s\n' "$output" | grep -qF -- "$1"; then
		printf 'expected the output NOT to mention: %s\n--- output ---\n%s\n' \
			"$1" "$output" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# 4. The M1 overrides (MACKAS_VOLUME_DL_NAME / MACKAS_VOLUME_SSTATE_NAME)
#    still behave exactly as M1 defined them for an unselected invocation --
#    including in the presence of pinned projects on disk.
# ---------------------------------------------------------------------------

@test "compat: M1's MACKAS_VOLUME_DL_NAME/_SSTATE_NAME overrides still work, unselected, pins present" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-pin.yml"
	EOF
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai \
		--set MACKAS_VOLUME_DL_NAME=shared-dl \
		--set MACKAS_VOLUME_SSTATE_NAME=shared-sstate
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-tmp:/build -e KAS_BUILD_DIR=/build'
	printf '%s\n' "$output" | grep -qF -- '-v shared-dl:/downloads -e DL_DIR=/downloads'
	printf '%s\n' "$output" | grep -qF -- '-v shared-sstate:/sstate -e SSTATE_DIR=/sstate'
}

@test "compat: M1's MACKAS_VOLUME_NAME stem override still works, unselected" {
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai --set MACKAS_VOLUME_NAME=custom-stem
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF -- '-v custom-stem-tmp:/build -e KAS_BUILD_DIR=/build'
	printf '%s\n' "$output" | grep -qF -- '-v custom-stem-dl:/downloads -e DL_DIR=/downloads'
	printf '%s\n' "$output" | grep -qF -- '-v custom-stem-sstate:/sstate -e SSTATE_DIR=/sstate'
}
