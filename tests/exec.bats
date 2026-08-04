#!/usr/bin/env bats
#
# Tests for `mackas exec` -- a one-off, read-only command against the
# checkout, with kas's repo-mutating setup steps always skipped. This is the
# tool form of the `--skip setup_dir --skip finish_setup_repos --skip
# repos_checkout --skip repos_apply_patches` recipe `bitbake_getvar()` already
# uses internally (via the shared `kas_shell_ro()` helper) for retrieve/
# buildstats/clean -- exec exists so a manual, ad-hoc check never has to type
# kas-container directly (and forget the flags) again.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas` as a subprocess with a fake `kas-container` that logs
# its full argv (so the --skip set and the -c payload can be pinned exactly),
# and a fake `container` for the one-VM refusal (same ls/inspect/
# MOCK_BUSY_VOLUME shape as tests/retrieve.bats and tests/clean.bats). Nothing
# here touches the real Apple container runtime or a real checkout.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin" "$ROOT/work/meta-angstrom/.git"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"

	KLOG="$TESTDIR/kas-container.log"
	export KLOG
	# Read once per invocation, so a test can set a non-zero exit for the
	# exit-code-propagation case without touching the stub script itself.
	EXIT_CODE_FILE="$TESTDIR/kas-exit-code"
	echo 0 > "$EXIT_CODE_FILE"
	export EXIT_CODE_FILE

	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
	printf 'ENV: KAS_BUILD_DIR=[%s] DL_DIR=[%s] SSTATE_DIR=[%s]\n' \
		"${KAS_BUILD_DIR-<unset>}" "${DL_DIR-<unset>}" "${SSTATE_DIR-<unset>}"
} >> "$KLOG"
rc=0
[ -f "$EXIT_CODE_FILE" ] && rc="$(cat "$EXIT_CODE_FILE")"
exit "$rc"
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	# ensure_kas_container_installed requires BOTH files present (a wrapper
	# with no .real, or a .real with no wrapper on PATH, both count as "not
	# installed") -- cmd_exec calls it, so the wrapper itself must exist
	# too, even though only kas-container.real above is ever exec'd.
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	CLOG="$TESTDIR/container.log"
	export CLOG
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"
case "$1 $2" in
	"system status")
		if [ "${MOCK_CONTAINER_DOWN:-0}" = "1" ] && [ ! -f "${CONTAINER_STARTED_MARKER:-/nonexistent-marker-xyzzy}" ]; then
			exit 1
		fi
		echo "status running"; exit 0 ;;
	"system start")
		[ -n "${CONTAINER_STARTED_MARKER:-}" ] && touch "$CONTAINER_STARTED_MARKER"
		exit 0 ;;
	"ls "*|"ls")
		echo "ID"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "runner1"
		exit 0 ;;
	"inspect "*)
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

mk() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

assert_klog() {
	if ! grep -qF -- "$1" "$KLOG" 2>/dev/null; then
		printf 'expected a kas-container call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$KLOG" 2>/dev/null)" >&2
		return 1
	fi
}

refute_klog() {
	if grep -qF -- "$1" "$KLOG" 2>/dev/null; then
		printf 'expected NO kas-container call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$KLOG" 2>/dev/null)" >&2
		return 1
	fi
}

assert_clog() {
	if ! grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected a container call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

refute_clog() {
	if grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected NO container call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# The skip set itself
# ---------------------------------------------------------------------------

@test "exec: passes the exact four --skip flags, never -k" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec du -sh meta-angstrom
	[ "$status" -eq 0 ]
	assert_klog "[--skip] [setup_dir]"
	assert_klog "[--skip] [finish_setup_repos]"
	assert_klog "[--skip] [repos_checkout]"
	assert_klog "[--skip] [repos_apply_patches]"
	refute_klog "[-k]"
	refute_klog "[--keep-config-unchanged]"
	assert_klog "[shell]"
}

@test "exec: the joined command reaches kas as one quoted -c argument" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec du -sh meta-angstrom
	[ "$status" -eq 0 ]
	assert_klog "[-c] [du -sh meta-angstrom]"
}

@test "exec: blanks KAS_BUILD_DIR/DL_DIR/SSTATE_DIR (bug 1's fix, shared here too)" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
	assert_klog "ENV: KAS_BUILD_DIR=[] DL_DIR=[] SSTATE_DIR=[]"
}

@test "exec: writes the kas fragment first when it is missing" {
	[ ! -f "$ROOT/work/meta-angstrom/kas/macos-local.yml" ]
	MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
	[ -f "$ROOT/work/meta-angstrom/kas/macos-local.yml" ]
}

# ---------------------------------------------------------------------------
# Argv is never re-parsed as a mackas flag
# ---------------------------------------------------------------------------

@test "exec: the command's own flags are never consumed by mackas (du -sh reaches kas intact)" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec du -sh meta-angstrom
	[ "$status" -eq 0 ]
	assert_klog "[-c] [du -sh meta-angstrom]"
}

@test "exec: -- forces the command to start early, even for a leading dash" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec -- -k
	[ "$status" -eq 0 ]
	# '-k' only ever appears inside the quoted -c payload, never as its own
	# kas-container flag ahead of it.
	assert_klog "[-c] [-k]"
	refute_klog "[shell] [-k]"
}

@test "exec: mackas's own flags stop being recognized after the command starts" {
	# --dry-run AFTER 'du' has already started the payload must NOT be
	# reinterpreted as mackas's global --dry-run: kas-container must still
	# be invoked for real, and the payload must contain the literal text.
	MACKAS_PROJECT_DIR=meta-angstrom mk exec du --dry-run
	[ "$status" -eq 0 ]
	assert_klog "[-c] [du --dry-run]"
}

@test "exec: --dry-run BEFORE the command is still mackas's own flag" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec --dry-run du -sh meta-angstrom
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF -- '--skip setup_dir'
	[ ! -f "$KLOG" ]
}

@test "exec: -v before the command sets verbose; the SAME flag after it is payload" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec -v du -v
	[ "$status" -eq 0 ]
	assert_klog "[-c] [du -v]"
}

# ---------------------------------------------------------------------------
# Usage errors
# ---------------------------------------------------------------------------

@test "exec: no command given is a clear usage error, kas-container never runs" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "needs a command to run"
	[ ! -f "$KLOG" ]
}

@test "exec: an unknown option before the command dies, does not guess" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec --bogus du
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "unknown option for 'exec'"
	[ ! -f "$KLOG" ]
}

@test "exec: --config after the command word is refused with a clear redirect" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec --config /tmp/whatever.conf true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'must come BEFORE'
}

# ---------------------------------------------------------------------------
# Help, and the prepend-not-append fix
# ---------------------------------------------------------------------------

@test "exec --help / exec help / help exec all show exec_usage" {
	for args in "exec --help" "exec help" "help exec"; do
		# shellcheck disable=SC2086
		mk $args
		[ "$status" -eq 0 ]
		printf '%s\n' "$output" | grep -qF 'ONE-VM RULE'
		printf '%s\n' "$output" | grep -qF 'WHAT THIS DOES NOT DO'
	done
}

@test "exec: 'help exec CMD...' shows help, does not pass --help to CMD (prepend, not append)" {
	# Regression: appending "--help" (like every other tail-capturer) would
	# land it AFTER the command word, where cmd_exec's own parser -- which
	# stops recognizing flags at the first positional -- would hand it to
	# the user's command as an argument instead of showing help.
	MACKAS_PROJECT_DIR=meta-angstrom mk help exec du -sh meta-angstrom
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'ONE-VM RULE'
	[ ! -f "$KLOG" ]
}

# ---------------------------------------------------------------------------
# One-VM rule
# ---------------------------------------------------------------------------

@test "exec: refuses when the TMPDIR volume is held by a running container" {
	MOCK_BUSY_VOLUME=oe-build-tmp MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'attached to a running container'
	[ ! -f "$KLOG" ]
}

@test "exec: refuses when the downloads volume is held by a running container" {
	MOCK_BUSY_VOLUME=oe-build-dl MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'attached to a running container'
}

@test "exec: refuses when the sstate volume is held by a running container" {
	MOCK_BUSY_VOLUME=oe-build-sstate MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'attached to a running container'
}

@test "exec: an unrelated command holding no mackas volume does not block it" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
	assert_klog "[shell]"
}

# ---------------------------------------------------------------------------
# Exit code propagation
# ---------------------------------------------------------------------------

@test "exec: propagates the command's real exit status" {
	echo 3 > "$EXIT_CODE_FILE"
	MACKAS_PROJECT_DIR=meta-angstrom mk exec false
	[ "$status" -eq 3 ]
}

@test "exec: a zero exit status propagates too, not just failures" {
	echo 0 > "$EXIT_CODE_FILE"
	MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Auto-start the container runtime (issue #33): kas_shell_ro() -- the helper
# 'exec' shares with retrieve/buildstats analyze/clean/sstate prune/lock/dump
# -- must not surface a raw daemon-down error; it auto-starts the runtime
# first, the same check_running-then-start logic setup_runtime() has always
# had for 'mackas setup'.
# ---------------------------------------------------------------------------

@test "exec: runtime already up, no 'system start' is ever called" {
	MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
	refute_clog "[system] [start]"
}

@test "exec: runtime down at invocation, comes up after 'system start', the command still runs" {
	marker="$TESTDIR/container-started"
	MOCK_CONTAINER_DOWN=1 CONTAINER_STARTED_MARKER="$marker" \
		MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -eq 0 ]
	assert_clog "[system] [start]"
	[ -f "$marker" ]
	assert_klog "[shell]"
}

@test "exec: runtime stays down after 'system start', refuses with a clear message, kas-container never runs" {
	MOCK_CONTAINER_DOWN=1 MACKAS_PROJECT_DIR=meta-angstrom mk exec true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'container system did not start'
	assert_clog "[system] [start]"
	[ ! -f "$KLOG" ]
}
