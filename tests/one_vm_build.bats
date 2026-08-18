#!/usr/bin/env bats
#
# The one-VM rule on the BUILD path: `mackas shell` and `mackas smoketest`
# both funnel into run_kas(), which was the last entrypoint without a
# require_volumes_free() guard -- so a second build against a volume an
# existing one already held got Virtualization.framework's
# "The storage device attachment is invalid" instead of a refusal naming it.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Same hermetic shape as tests/exec.bats: a fake `kas-container` that records
# its argv (so "kas never ran" is a real assertion, not an inference) and a
# fake `container` whose MOCK_BUSY_VOLUME makes one named volume read as held.
# Nothing here touches the real Apple container runtime or a real checkout.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN MACKAS_FSTRIM_AUTO
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	PROJ="$ROOT/work/meta-ai"
	mkdir -p "$ROOT/bin" "$ROOT/logs" "$PROJ/.git" "$PROJ/kas"
	touch "$PROJ/kas/macos-local.yml"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"

	KLOG="$TESTDIR/kas-container.log"
	export KLOG
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$KLOG"
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	# ensure_kas_container_installed wants BOTH files; only the .real one runs.
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
	"volume ls")     echo "NAME"; exit 0 ;;
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
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/no-such-link" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_PROJECT_DIR=meta-ai \
		--set MACKAS_KAS_CONFIG=kas/base.yml "$@"
}

# A bare `! ... | grep -q` is vacuous anywhere but the last line of a test
# (see assert_fails in helpers.bash for why), so absence goes through this.
refute_output() {
	if printf '%s\n' "$output" | grep -qF -- "$1"; then
		printf 'expected the output NOT to mention: %s\n--- output ---\n%s\n' \
			"$1" "$output" >&2
		return 1
	fi
}

# The volume-state query volume_in_use() makes: bare `container ls`, then
# `container inspect <id>` per running container. `container volume ls`
# (auto_fstrim's existence probe) is a different call and logs differently.
refute_volume_state_query() {
	if grep -qF -- 'CALL: [ls]' "$CLOG" 2>/dev/null; then
		printf 'expected NO volume-state query, but `container ls` ran\n--- calls ---\n%s\n' \
			"$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
	if grep -qF -- 'CALL: [inspect]' "$CLOG" 2>/dev/null; then
		printf 'expected NO volume-state query, but `container inspect` ran\n--- calls ---\n%s\n' \
			"$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# shell
# ---------------------------------------------------------------------------

@test "shell: refuses when the TMPDIR volume is held, naming that volume, before kas runs" {
	MOCK_BUSY_VOLUME=oe-build-tmp mk shell
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-tmp' is attached to a running container"
	[ ! -f "$KLOG" ]
}

@test "shell: refuses when the downloads volume is held, naming IT and not the tmp volume" {
	MOCK_BUSY_VOLUME=oe-build-dl mk shell
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-dl' is attached to a running container"
	# The message must name the volume actually held -- the free one it
	# checked first must not appear anywhere in the refusal.
	refute_output 'oe-build-tmp'
	[ ! -f "$KLOG" ]
}

@test "shell: refuses when the sstate volume is held, naming IT and not the others" {
	MOCK_BUSY_VOLUME=oe-build-sstate mk shell
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-sstate' is attached to a running container"
	refute_output 'oe-build-tmp'
	refute_output 'oe-build-dl'
	[ ! -f "$KLOG" ]
}

@test "shell: the refusal points back at 'shell', not at some other subcommand" {
	MOCK_BUSY_VOLUME=oe-build-tmp mk shell
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "then re-run '$MACKAS shell'"
}

@test "shell: nothing holding a volume lets the build through to kas" {
	mk shell
	[ "$status" -eq 0 ]
	grep -qF -- 'CALL:' "$KLOG"
	grep -qF -- '[shell]' "$KLOG"
}

# ---------------------------------------------------------------------------
# smoketest -- reaches run_kas via smoketest_ladder/smoketest_rung
# ---------------------------------------------------------------------------

@test "smoketest: refuses at the first rung when the TMPDIR volume is held" {
	MOCK_BUSY_VOLUME=oe-build-tmp mk smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-tmp' is attached to a running container"
	[ ! -f "$KLOG" ]
}

@test "smoketest: refuses when the downloads volume is held, naming it" {
	MOCK_BUSY_VOLUME=oe-build-dl mk smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-dl' is attached to a running container"
	[ ! -f "$KLOG" ]
}

@test "smoketest: refuses when the sstate volume is held, naming it" {
	MOCK_BUSY_VOLUME=oe-build-sstate mk smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "volume 'oe-build-sstate' is attached to a running container"
	[ ! -f "$KLOG" ]
}

@test "smoketest: the refusal points back at 'smoketest', not at 'shell'" {
	MOCK_BUSY_VOLUME=oe-build-tmp mk smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "then re-run '$MACKAS smoketest'"
}

@test "smoketest: nothing holding a volume runs the whole ladder" {
	mk smoketest
	[ "$status" -eq 0 ]
	grep -qF -- '[-c] [bitbake -p]' "$KLOG"
	grep -qF -- '[build]' "$KLOG"
}

# ---------------------------------------------------------------------------
# --dry-run must not query volume state
#
# Deliberately NOT "--dry-run makes no daemon calls": run_kas() calls
# ensure_workspace_attached/ensure_container_running BEFORE its dry-run
# return, so `container system status` legitimately runs. The property the
# guard's placement buys is the narrower one asserted here.
# ---------------------------------------------------------------------------

@test "shell --dry-run: performs no volume-state query" {
	mk --dry-run shell
	[ "$status" -eq 0 ]
	refute_volume_state_query
	[ ! -f "$KLOG" ]
}

@test "shell --dry-run: still starts the runtime, so the check above is about the QUERY only" {
	mk --dry-run shell
	[ "$status" -eq 0 ]
	grep -qF -- 'CALL: [system] [status]' "$CLOG"
}

@test "shell (for real): the mock does log 'CALL: [ls]', so refute_volume_state_query can fail" {
	# Deliberately NOT a check on the guard: on a real run clear_stale_sockets
	# also calls volume_in_use, from BELOW the guard, so this passes even with
	# the guard deleted. All it proves -- which is still worth pinning -- is
	# that the string refute_volume_state_query looks for is one the fake
	# `container` actually emits, so the dry-run assertions above are refuting
	# something real rather than passing on a typo.
	mk shell
	[ "$status" -eq 0 ]
	grep -qF -- 'CALL: [ls]' "$CLOG"
}

@test "shell --dry-run: a held volume is not even noticed, let alone refused" {
	MOCK_BUSY_VOLUME=oe-build-tmp mk --dry-run shell
	[ "$status" -eq 0 ]
	refute_volume_state_query
}
