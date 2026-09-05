#!/usr/bin/env bats
#
# THE M5 GENERATED-FILE-PATHS COMPATIBILITY CONTRACT (issue #79).
#
# M5 teaches mackas to name the files it generates after the project
# SELECTOR (--project / $MACKAS_PROJECT_SELECT) once one is in force:
# env-<name>.sh instead of env.sh, macos-<name>.yml instead of macos.yml,
# and logs/<name>/ instead of a flat logs/. #79 is "part of #72", which
# calls this whole area "backward-compatibility-critical" the same way #77
# (M3, volume names) and #78 (M4, implicit selection) did, and requires the
# same treatment: the compatibility contract written first, before any M5
# feature code, and mutation-tested.
#
# The guarantee, in one sentence: an invocation that never mentions the
# selector -- no --project, no $MACKAS_PROJECT_SELECT, no pinned config
# matching $PWD -- resolves EXACTLY the generated-file layout it resolves
# today, byte for byte, no matter what pinned projects happen to exist on
# disk. Six facts about today's tree, pinned here:
#
#   1. the env file is <base>/env.sh
#   2. the canonical kas fragment is <base>/kas/macos.yml, the in-checkout
#      copy is <checkout>/kas/macos-local.yml
#   3. the log directory is <base>/logs, flat -- no project component
#   4. `mackas dump` writes <base>/logs/dump-<timestamp>.yml, flat
#   5. bare `mackas clean` removes exactly <base>/logs and recreates it
#   6. `mackas status`'s "Recent logs" section reads <base>/logs
#
# DO NOT RELAX ANY ASSERTION BELOW TO MAKE A LATER CHANGE PASS. If a later
# M5 commit needs one of these to change for an UNSELECTED run, that is a
# sign the change broke the compatibility contract, not a sign the test was
# wrong. Every one of these must pass right now, before M5 exists.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY MACKAS_CPUS
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR/home"
	mkdir -p "$HOME"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin" "$ROOT/work/meta-ai/.git"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"

	# kas-container.real: records every argv line and, for a `dump` call,
	# prints a canned "resolved" YAML to stdout -- same shape as
	# tests/lock_dump.bats, so a dump test here can assert the saved file
	# actually holds what kas printed, not just that a file appeared.
	KLOG="$TESTDIR/kas-container.log"
	export KLOG
	EXIT_CODE_FILE="$TESTDIR/kas-exit-code"
	echo 0 > "$EXIT_CODE_FILE"
	export EXIT_CODE_FILE
	DUMP_STDOUT="$TESTDIR/dump-stdout"
	echo "resolved: yaml" > "$DUMP_STDOUT"
	export DUMP_STDOUT
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$KLOG"
for a in "$@"; do
	if [ "$a" = "dump" ] && [ -f "${DUMP_STDOUT:-}" ]; then
		cat "$DUMP_STDOUT"
		break
	fi
done
rc=0
[ -f "$EXIT_CODE_FILE" ] && rc="$(cat "$EXIT_CODE_FILE")"
exit "$rc"
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	# container: the Apple `container` CLI mackas resolves by bare name.
	# Tracks ext4 volume state (create/delete/ls) in VSTATE, the same
	# mechanism tests/volumes_cmd.bats uses, so bare `clean` here really
	# deletes-and-recreates the TMPDIR volume rather than tripping over a
	# static fake; also answers the one-VM busy-volume check dump/lock use
	# (tests/lock_dump.bats' shape).
	CLOG="$TESTDIR/container.log"
	export CLOG
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"
case "$1 $2" in
	"volume ls")
		echo "NAME"
		grep -v '^$' "$VSTATE" 2>/dev/null || true
		;;
	"volume create")
		# ... -s SIZE NAME
		eval "name=\${$#}"
		printf '%s\n' "$name" >> "$VSTATE"
		;;
	"volume delete"|"volume rm")
		grep -vxF "$3" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		;;
	"system status") echo "status running" ;;
	"system start") : ;;
	"image ls") echo "NAME TAG"; echo "ghcr.io/siemens/kas/kas 5.5" ;;
	"--version "*|"--version") echo "container CLI version 1.1.0" ;;
	"ls "*|"ls")
		echo "ID"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "runner1"
		;;
	"inspect "*)
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		;;
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

mk() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

# Seed the fake engine: these volumes already exist.
have_volumes() {
	printf '%s\n' "$@" > "$VSTATE"
}

# ---------------------------------------------------------------------------
# 1-3. env.sh, the two kas fragment paths, and the logs directory, read
#      straight off derive_paths() -- the single place all four are computed
#      (mackas's derive_paths(), MACKAS_ENV_SH/MACKAS_KAS_FRAGMENT_SRC/
#      MACKAS_KAS_FRAGMENT_REPO/MACKAS_LOGS). Library-level, like
#      tests/multi_project_compat.bats' "internal variables" test.
# ---------------------------------------------------------------------------

@test "compat: unselected -- env.sh, kas fragments and logs dir are exactly today's flat paths (internal variables)" {
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
	[ "$MACKAS_ENV_SH" = "$ROOT/env.sh" ]
	[ "$MACKAS_KAS_FRAGMENT_SRC" = "$ROOT/kas/macos.yml" ]
	[ "$MACKAS_KAS_FRAGMENT_REPO" = "$ROOT/work/meta-ai/kas/macos-local.yml" ]
	[ "$MACKAS_LOGS" = "$ROOT/logs" ]
}

# Same three paths, black box this time -- `mackas status` echoes whatever
# derive_paths() actually computed, with no literal of its own (see the
# recon notes: status's "env.sh" line and its "Present?" loop are both pure
# reads of these variables).
@test "compat: unselected -- status reports env.sh and both kas fragment paths at their flat locations" {
	MACKAS_PROJECT_DIR=meta-ai mk status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE "^  env\.sh +${ROOT}/env\.sh\$"
	printf '%s\n' "$output" | grep -qF "$ROOT/kas/macos.yml"
	printf '%s\n' "$output" | grep -qF "$ROOT/work/meta-ai/kas/macos-local.yml"
}

# ---------------------------------------------------------------------------
# 4. mackas dump -- must still land flat at <base>/logs/dump-<ts>.yml.
#    (tests/lock_dump.bats pins the same fact for its own fixture; this is
#    the standalone copy that has to keep passing on its own, since a
#    contract file cannot depend on another test file's assertions staying
#    put.)
# ---------------------------------------------------------------------------

@test "compat: unselected -- dump writes the resolved YAML to <base>/logs/dump-<ts>.yml, flat" {
	MACKAS_PROJECT_DIR=meta-ai MACKAS_DUMP_TS=20260901000000 mk dump
	[ "$status" -eq 0 ]
	[ -f "$ROOT/logs/dump-20260901000000.yml" ]
	grep -qF "resolved: yaml" "$ROOT/logs/dump-20260901000000.yml"
	printf '%s\n' "$output" | grep -qF "$ROOT/logs/dump-20260901000000.yml"
}

# ---------------------------------------------------------------------------
# 5. bare `mackas clean` -- the actual rm -rf/mkdir -p pair (clean_tmpdir_
#    volume), never exercised anywhere else in the suite (tests/volumes_cmd.
#    bats' one bare-clean test only covers the failure-reporting path around
#    an undeletable TMPDIR volume). Pin it wiping exactly <base>/logs, not a
#    project subset and not a wider tree, before M5 gives it a subset to
#    possibly get wrong.
# ---------------------------------------------------------------------------

@test "compat: unselected -- bare clean removes exactly <base>/logs and recreates it empty" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mkdir -p "$ROOT/logs"
	echo "leftover" > "$ROOT/logs/dump-old.yml"
	MACKAS_PROJECT_DIR=meta-ai mk clean
	[ "$status" -eq 0 ]
	[ -d "$ROOT/logs" ]
	[ ! -e "$ROOT/logs/dump-old.yml" ]
	[ -z "$(ls -A "$ROOT/logs")" ]
}

# ---------------------------------------------------------------------------
# 6. `mackas status`'s "Recent logs" section -- a pure `ls -t "$MACKAS_LOGS"`
#    (mackas:10238-10241), so it must surface a file actually sitting in
#    <base>/logs, unselected.
# ---------------------------------------------------------------------------

@test "compat: unselected -- status's Recent logs section reads <base>/logs" {
	mkdir -p "$ROOT/logs"
	echo x > "$ROOT/logs/sentinel-recent-log.txt"
	MACKAS_PROJECT_DIR=meta-ai mk status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qxF "  sentinel-recent-log.txt"
}
