#!/usr/bin/env bats
#
# Tests for `mackas buildhistory analyze` -- summarising a retrieved
# buildhistory git tree (see retrieve.bats for how it gets there).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The summary layer never touches the Apple container runtime -- it is host
# `git` plumbing plus a `python3` invocation -- so most tests here drive
# `mackas buildhistory analyze` directly, with no `container` mock, and
# assert `refute_call "container"` to pin that architectural property. The
# --detail half DOES run inside a throwaway container (openembedded-core's
# own scripts/buildhistory-diff); the tests for that below add a fake
# `container` on PATH, same convention as buildstats_analyze.bats and
# retrieve.bats. Nothing here touches the real Apple container runtime, a
# volume, or the build SSD.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin"
	touch "$ROOT/bin/kas-container.real"
	chmod +x "$ROOT/bin/kas-container.real"
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

assert_call() {
	if ! grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected a `container` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

refute_call() {
	if [ -f "$CLOG" ] && grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected NO `container` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# A real two-commit buildhistory git repo, tagged the way
# buildhistory.bbclass itself rotates build-minus-1 before each commit: one
# recipe bumps version, gaining a new sub-package.
bh_fixture() {
	local dir="$1"
	mkdir -p "$dir/packages/cortexa57/busybox/busybox"
	mkdir -p "$dir/packages/cortexa57/openssl/openssl"
	cat > "$dir/packages/cortexa57/busybox/latest" <<'EOF'
PV = 1.36.1
PR = r0
PACKAGES = busybox
EOF
	cat > "$dir/packages/cortexa57/busybox/busybox/latest" <<'EOF'
PKGSIZE = 1044000
EOF
	cat > "$dir/packages/cortexa57/openssl/latest" <<'EOF'
PV = 3.3.1
PR = r0
PACKAGES = openssl-bin
EOF
	cat > "$dir/packages/cortexa57/openssl/openssl/latest" <<'EOF'
PKGSIZE = 421888
EOF
	git init -q "$dir"
	git -C "$dir" config user.email test@example.com
	git -C "$dir" config user.name test
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "Build 1"
	git -C "$dir" tag build-minus-1

	cat > "$dir/packages/cortexa57/busybox/latest" <<'EOF'
PV = 1.37.0
PR = r0
PACKAGES = busybox
EOF
	cat > "$dir/packages/cortexa57/busybox/busybox/latest" <<'EOF'
PKGSIZE = 931840
EOF
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "Build 2"
}

# A checkout shape modelling a real kas checkout: bitbake is a SIBLING of
# oe-core (not nested under it), which is what makes scriptpath's $PATH-walk
# fallback the one that actually fires -- see buildhistory_detail_diff()'s
# own comment on why /bitbake/bin must be prepended to PATH in the container.
detail_checkout_fixture() {
	mkdir -p "$ROOT/work/openembedded-core/scripts" "$ROOT/work/openembedded-core/meta/lib"
	touch "$ROOT/work/openembedded-core/scripts/buildhistory-diff"
	mkdir -p "$ROOT/work/bitbake/lib/bb" "$ROOT/work/bitbake/bin"
	touch "$ROOT/work/bitbake/bin/bitbake"
}

# A fake `container` that models buildhistory_detail_diff()'s single `run`
# invocation: logs every call to CLOG, and -- unless MOCK_BHD_FAIL is set --
# prints one fake buildhistory-diff line so the "no significant changes"
# empty-output path is distinguishable from a real one.
bhd_container_mock() {
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"

[ "$1" = "run" ] || exit 0
[ -z "${MOCK_BHD_FAIL:-}" ] || exit 1
[ -n "${MOCK_BHD_EMPTY:-}" ] && exit 0
echo "packages/cortexa57-oe-linux/busybox: PV changed from \"1.36.1\" to \"1.37.0\""
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

# ---------------------------------------------------------------------------
# 1. Happy path -- the default path never boots a container
# ---------------------------------------------------------------------------

@test "buildhistory analyze: happy path shows the summary and never calls container" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	CLOG="$TESTDIR/container.log"
	export CLOG
	mk buildhistory analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'buildhistory summary'
	printf '%s\n' "$output" | grep -qF 'busybox'
	refute_call "container"
}

# ---------------------------------------------------------------------------
# 2. Missing PATH
# ---------------------------------------------------------------------------

@test "buildhistory analyze: a missing DEFAULT path is informational, exit 0" {
	mk buildhistory analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'INHERIT += "buildhistory"'
}

@test "buildhistory analyze: an explicitly-named missing PATH is an error, exit 1" {
	mk buildhistory analyze "$TESTDIR/does-not-exist"
	[ "$status" -eq 1 ]
	printf '%s\n' "$output" | grep -qi 'no such directory'
}

@test "buildhistory analyze: a directory with no packages/images/sdk is reported, not crashed on" {
	mkdir -p "$TESTDIR/notbh"
	mk buildhistory analyze "$TESTDIR/notbh"
	[ "$status" -eq 1 ]
	printf '%s\n' "$output" | grep -qi 'does not look like a buildhistory tree'
}

# ---------------------------------------------------------------------------
# 3. No .git -- snapshot mode
# ---------------------------------------------------------------------------

@test "buildhistory analyze: BUILDHISTORY_COMMIT off (no .git) -- snapshot mode, exit 0, no container" {
	mkdir -p "$ROOT/artifacts/buildhistory/packages/cortexa57/busybox/busybox"
	echo 'PKGSIZE = 1000' > "$ROOT/artifacts/buildhistory/packages/cortexa57/busybox/busybox/latest"
	CLOG="$TESTDIR/container.log"
	export CLOG
	mk buildhistory analyze
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'BUILDHISTORY_COMMIT is off'
	printf '%s\n' "$output" | grep -qF 'recipes'
	refute_call "container"
}

# ---------------------------------------------------------------------------
# 4. Only one build recorded -- no container even with --detail
# ---------------------------------------------------------------------------

@test "buildhistory analyze: only one commit -- nothing to compare, exit 0, --detail skipped without a container" {
	local bh="$ROOT/artifacts/buildhistory"
	mkdir -p "$bh/packages/cortexa57/busybox/busybox"
	echo 'PKGSIZE = 1000' > "$bh/packages/cortexa57/busybox/busybox/latest"
	git init -q "$bh"
	git -C "$bh" config user.email test@example.com
	git -C "$bh" config user.name test
	git -C "$bh" add -A
	git -C "$bh" commit -q -m "Build 1"

	CLOG="$TESTDIR/container.log"
	export CLOG
	mk buildhistory analyze --detail
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'only one build recorded'
	printf '%s\n' "$output" | grep -qi 'detail skipped'
	refute_call "container"
}

# ---------------------------------------------------------------------------
# 5. Unresolvable user-supplied --from
# ---------------------------------------------------------------------------

@test "buildhistory analyze: an unresolvable --from warns and exits 1" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	mk buildhistory analyze --from no-such-revision
	[ "$status" -eq 1 ]
	printf '%s\n' "$output" | grep -qi "did not resolve"
}

# ---------------------------------------------------------------------------
# 6. --detail happy path -- exact container invocation shape
# ---------------------------------------------------------------------------

@test "buildhistory analyze --detail: mounts, GIT_CONFIG trio, and /bitbake/bin are exactly as specified" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	detail_checkout_fixture
	CLOG="$TESTDIR/container.log"
	export CLOG
	bhd_container_mock

	mk buildhistory analyze --detail
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'buildhistory-diff'
	printf '%s\n' "$output" | grep -qF 'PV changed'

	assert_call "$ROOT/work/openembedded-core:/oe-core:ro"
	assert_call "$ROOT/work/bitbake:/bitbake:ro"
	assert_call "$ROOT/artifacts/buildhistory:/bh:ro"
	assert_call "GIT_CONFIG_COUNT=1"
	assert_call "GIT_CONFIG_KEY_0=safe.directory"
	assert_call "GIT_CONFIG_VALUE_0=*"
	assert_call "/bitbake/bin:\$PATH"
	# The two revisions travel as trailing positionals to 'sh -c ... sh $1
	# $2', not interpolated into the script string -- both resolved SHAs
	# must appear as their OWN argv words.
	grep -qE '\[[0-9a-f]{40}\] \[[0-9a-f]{40}\]$' "$CLOG"
	# No one-VM check, no named volume: never a -v of a bare volume name.
	! grep -qF -- "oe-build-tmp" "$CLOG"
}

# ---------------------------------------------------------------------------
# 7. buildhistory-diff fails -- host-side fallback, non-fatal
# ---------------------------------------------------------------------------

@test "buildhistory analyze --detail: a failed container run warns and falls back to host git, exit 1" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	detail_checkout_fixture
	CLOG="$TESTDIR/container.log"
	export CLOG
	MOCK_BHD_FAIL=1
	export MOCK_BHD_FAIL
	bhd_container_mock

	mk buildhistory analyze --detail
	[ "$status" -eq 1 ]
	printf '%s\n' "$output" | grep -qi 'buildhistory-diff failed'
	printf '%s\n' "$output" | grep -qF 'Build 2'
	# The summary layer itself must still have succeeded and printed --
	# --detail failing must not take the whole command down with it.
	printf '%s\n' "$output" | grep -qF 'buildhistory summary'
}

@test "buildhistory analyze --detail: empty container output reports 'no significant changes'" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	detail_checkout_fixture
	CLOG="$TESTDIR/container.log"
	export CLOG
	MOCK_BHD_EMPTY=1
	export MOCK_BHD_EMPTY
	bhd_container_mock

	mk buildhistory analyze --detail
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'no significant changes'
}

# ---------------------------------------------------------------------------
# 8. PATH handling
# ---------------------------------------------------------------------------

@test "buildhistory analyze --detail: a relative PATH is absolutised before it reaches -v" {
	bh_fixture "$TESTDIR/elsewhere/buildhistory"
	detail_checkout_fixture
	CLOG="$TESTDIR/container.log"
	export CLOG
	bhd_container_mock

	cd "$TESTDIR"
	mk buildhistory analyze "elsewhere/buildhistory" --detail
	[ "$status" -eq 0 ]
	assert_call "$TESTDIR/elsewhere/buildhistory:/bh:ro"
}

@test "buildhistory analyze: a PATH containing ':' is refused" {
	mk buildhistory analyze "$TESTDIR/a:b"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "must not contain ':'"
}

@test "buildhistory analyze: at most one PATH is accepted" {
	bh_fixture "$TESTDIR/elsewhere/buildhistory"
	mk buildhistory analyze "$TESTDIR/elsewhere/buildhistory" "$TESTDIR/extra"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'at most one PATH'
}

# ---------------------------------------------------------------------------
# 9. --dry-run must not leak the '+ cmd' banner into diff output
# ---------------------------------------------------------------------------

@test "buildhistory analyze --dry-run --detail: prints the container command, never runs it, never leaks the banner as diff output" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	detail_checkout_fixture
	CLOG="$TESTDIR/container.log"
	export CLOG
	bhd_container_mock

	mk --dry-run buildhistory analyze --detail
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '+ container run'
	# The mock was never actually invoked -- nothing logged.
	[ ! -s "$CLOG" ]
	# And the summary above the dry-run banner is real output, not garbled
	# by a captured "+ ..." line standing in for buildhistory-diff's output.
	printf '%s\n' "$output" | grep -qF 'buildhistory summary'
}

# ---------------------------------------------------------------------------
# 10. --detail --json refused
# ---------------------------------------------------------------------------

@test "buildhistory analyze: --detail and --json together are refused" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	mk buildhistory analyze --detail --json
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'cannot be combined'
}

@test "buildhistory analyze --json: stdout is a clean JSON stream (no hdr banner)" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	mk buildhistory analyze --json
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

# ---------------------------------------------------------------------------
# 11. Dispatch
# ---------------------------------------------------------------------------

@test "buildhistory: with no subcommand shows buildhistory usage" {
	mk buildhistory
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'analyze'
}

@test "buildhistory --help shows usage" {
	mk buildhistory --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'analyze'
}

@test "mackas help buildhistory shows the same usage" {
	mk help buildhistory
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'analyze'
}

@test "buildhistory: an unknown subcommand is refused" {
	mk buildhistory bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "unknown 'buildhistory' subcommand"
}

@test "buildhistory: --config after the subcommand hits die_on_misplaced_global_flag" {
	mk buildhistory analyze --config ./somewhere.conf
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'must come BEFORE'
}

# ---------------------------------------------------------------------------
# 12. --from=REV and --from REV both parse
# ---------------------------------------------------------------------------

@test "buildhistory analyze: --from=REV (equals form) parses the same as --from REV" {
	bh_fixture "$ROOT/artifacts/buildhistory"
	mk buildhistory analyze --from=build-minus-1 --to=HEAD
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'busybox'

	mk buildhistory analyze --from build-minus-1 --to HEAD
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'busybox'
}
