#!/usr/bin/env bats
#
# Tests for `mackas lock` and `mackas dump` -- item 13's reproducibility
# artifacts. Both are kas-container's own top-level subcommands (never
# wrapped in kas_shell_ro's 'shell -c' shape), sharing the same
# runtime-args/gitconfig/one-VM preflight every other real kas-container
# invocation in this file goes through.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas` as a subprocess with a fake `kas-container.real` that
# logs its full argv and a fake `container` for the one-VM refusal (same
# shape as tests/exec.bats). Nothing here touches the real Apple container
# runtime or a real checkout.

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
	EXIT_CODE_FILE="$TESTDIR/kas-exit-code"
	echo 0 > "$EXIT_CODE_FILE"
	export EXIT_CODE_FILE
	# What 'kas dump' should print to stdout on success -- lets a test assert
	# the resolved YAML actually lands in the saved file, not just that a
	# file was created.
	DUMP_STDOUT="$TESTDIR/dump-stdout"
	echo "resolved: yaml" > "$DUMP_STDOUT"
	export DUMP_STDOUT

	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
	printf 'ENV: KAS_BUILD_DIR=[%s] DL_DIR=[%s] SSTATE_DIR=[%s]\n' \
		"${KAS_BUILD_DIR-<unset>}" "${DL_DIR-<unset>}" "${SSTATE_DIR-<unset>}"
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
	"system status") echo "status running"; exit 0 ;;
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

# ---------------------------------------------------------------------------
# lock
# ---------------------------------------------------------------------------

@test "lock: runs kas-container lock against the project's kas config" {
	MACKAS_PROJECT_DIR=meta-angstrom mk lock
	[ "$status" -eq 0 ]
	assert_klog "[lock]"
	printf '%s\n' "$output" | grep -qi 'kas lock finished'
}

@test "lock: never adds -k or --skip (it is not kas_shell_ro's shape)" {
	MACKAS_PROJECT_DIR=meta-angstrom mk lock
	[ "$status" -eq 0 ]
	refute_klog "[-k]"
	refute_klog "[--skip]"
	refute_klog "[shell]"
}

@test "lock: blanks KAS_BUILD_DIR/DL_DIR/SSTATE_DIR like every other real invocation" {
	MACKAS_PROJECT_DIR=meta-angstrom mk lock
	[ "$status" -eq 0 ]
	assert_klog "ENV: KAS_BUILD_DIR=[] DL_DIR=[] SSTATE_DIR=[]"
}

@test "lock: refuses when a running container holds a volume (one-VM rule)" {
	MOCK_BUSY_VOLUME="oe-build-tmp" MACKAS_PROJECT_DIR=meta-angstrom mk lock
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_klog "[lock]"
}

@test "lock: a failing kas lock is reported, not silently swallowed" {
	echo 7 > "$EXIT_CODE_FILE"
	MACKAS_PROJECT_DIR=meta-angstrom mk lock
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'kas lock failed'
}

@test "lock: --dry-run runs nothing" {
	MACKAS_PROJECT_DIR=meta-angstrom mk --dry-run lock
	[ "$status" -eq 0 ]
	refute_klog "[lock]"
}

@test "lock --help prints usage and does nothing" {
	mk lock --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'pin every declared repo'
	refute_klog "[lock]"
}

# ---------------------------------------------------------------------------
# dump
# ---------------------------------------------------------------------------

@test "dump: runs kas-container dump with all three --resolve-* flags" {
	MACKAS_PROJECT_DIR=meta-angstrom mk dump
	[ "$status" -eq 0 ]
	assert_klog "[dump] [--resolve-env] [--resolve-local] [--resolve-refs]"
}

@test "dump: blanks KAS_BUILD_DIR/DL_DIR/SSTATE_DIR like every other real invocation" {
	MACKAS_PROJECT_DIR=meta-angstrom mk dump
	[ "$status" -eq 0 ]
	assert_klog "ENV: KAS_BUILD_DIR=[] DL_DIR=[] SSTATE_DIR=[]"
}

@test "dump: saves the resolved YAML to MACKAS_LOGS/dump-<ts>.yml" {
	MACKAS_PROJECT_DIR=meta-angstrom MACKAS_DUMP_TS=20260803000000 mk dump
	[ "$status" -eq 0 ]
	[ -f "$ROOT/logs/dump-20260803000000.yml" ]
	grep -qF "resolved: yaml" "$ROOT/logs/dump-20260803000000.yml"
	printf '%s\n' "$output" | grep -qF "$ROOT/logs/dump-20260803000000.yml"
}

@test "dump: a failing kas dump removes the partial file and reports the failure" {
	echo 3 > "$EXIT_CODE_FILE"
	MACKAS_PROJECT_DIR=meta-angstrom MACKAS_DUMP_TS=20260803000001 mk dump
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'kas dump failed'
	[ ! -f "$ROOT/logs/dump-20260803000001.yml" ]
}

@test "dump: refuses when a running container holds a volume (one-VM rule)" {
	MOCK_BUSY_VOLUME="oe-build-sstate" MACKAS_PROJECT_DIR=meta-angstrom mk dump
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_klog "[dump]"
}

@test "dump: --dry-run runs nothing and creates no file" {
	MACKAS_PROJECT_DIR=meta-angstrom MACKAS_DUMP_TS=20260803000002 mk --dry-run dump
	[ "$status" -eq 0 ]
	refute_klog "[dump]"
	[ ! -f "$ROOT/logs/dump-20260803000002.yml" ]
}

@test "dump --help prints usage and does nothing" {
	mk dump --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'fully-resolved kas config'
	refute_klog "[dump]"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

@test "mackas --help lists lock and dump" {
	mk --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi '  lock '
	printf '%s\n' "$output" | grep -qi '  dump '
}
