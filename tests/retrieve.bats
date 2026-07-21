#!/usr/bin/env bats
#
# Tests for `mackas retrieve` -- copying build outputs out of the ext4 TMPDIR
# volume, where macOS cannot see them.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas retrieve` as a subprocess with a fake `container` on
# PATH that records every call and MODELS the two things that matter here: the
# existence probe (`... test -d /build/tmp/<sub>`), and the copy itself
# (`... sh -c 'cp -r ...'`) which actually populates the host --dest so
# `buildstats analyze` (tested separately in buildstats_analyze.bats) would
# have real files to chew on. It also models `container ls` / `container
# inspect` so the one-VM refusal can be exercised. Nothing touches the real
# Apple container runtime, a volume, or the build SSD.

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
	# cmd_retrieve requires kas-container to be installed.
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	CLOG="$TESTDIR/container.log"
	export CLOG

	# What the modelled TMPDIR volume contains under /build/tmp. The probe
	# `test -d /build/tmp/<sub>` succeeds only for a listed sub. A build that
	# has never run lists nothing -> the "no buildstats" path.
	MOCK_TMP_HAS="buildstats"
	export MOCK_TMP_HAS

	# A host fixture standing in for the guest's /build/tmp: the mock's cp
	# handler copies out of here, so a fetched dest ends up with real files.
	FIXTURE="$TESTDIR/guest-tmp"
	mkdir -p "$FIXTURE/buildstats/20260717121723/busybox"
	cat > "$FIXTURE/buildstats/20260717121723/build_stats" <<'EOF'
Host Info: Linux
Build Started: 1000.00
Elapsed time: 42.00 seconds
CPU usage: 55.5%
EOF
	mkdir -p "$FIXTURE/log"
	echo hi > "$FIXTURE/log/cooker.log"
	mkdir -p "$FIXTURE/deploy/images"
	echo bin > "$FIXTURE/deploy/images/fake.img"
	export FIXTURE

	# MOCK_BUSY_VOLUME, if set, is a volume the modelled runtime reports as held
	# by a running container (via ls + inspect) -- the one-VM refusal path.
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
	"volume ls") echo "NAME"; exit 0 ;;
	"image ls") echo "NAME TAG"; echo "ghcr.io/siemens/kas/kas 5.4"; exit 0 ;;
	"container ls"|"ls ")
		echo "ID  IMAGE  STATE"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "buildbox  kas  running"
		exit 0
		;;
	"container inspect"|"inspect "*|"inspect")
		# One "container": report the busy volume if one is configured. The
		# mount block names the volume under a "name" key, the way real
		# `container inspect` does -- volume_in_use anchors to that key, not to
		# a bare substring of the whole JSON (a substring false-positived a
		# volume named e.g. "kas" against the image field).
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		exit 0
		;;
esac

# Fall through: this is a `container run ...`. Two shapes matter.
# Collect the -v HOSTDIR:/out bind and the trailing command.
outdir=""
prev=""
for a in "$@"; do
	if [ "$prev" = "-v" ]; then
		case "$a" in
			*:/out) outdir="${a%:/out}" ;;
		esac
	fi
	prev="$a"
done

# The probe: `... test -d /build/tmp/<sub>`. Succeed only for a listed sub.
for a in "$@"; do
	if [ "$a" = "test" ]; then
		guest="${@: -1}"
		sub="${guest##*/}"
		case " $MOCK_TMP_HAS " in
			*" $sub "*) exit 0 ;;
			*) exit 1 ;;
		esac
	fi
done

# The copy: `... sh -c "mkdir -p '/out/<sub>' && cp -r '<guest>/.' '/out/<sub>/'"`.
# destsub (the mackas-facing object key, e.g. "deploy") and guestsub (the
# resolved guest path's own basename) are extracted independently -- they can
# differ when bitbake-getvar resolves a distro-redefined path, and the
# destination must be named after destsub regardless.
last="${@: -1}"
case "$last" in
	*"cp -r"*)
		destsub="$(printf '%s\n' "$last" | sed -E "s#.*mkdir -p '/out/([^']*)'.*#\1#")"
		guestdir="$(printf '%s\n' "$last" | sed -E "s#.*cp -r '([^']*)/\.'.*#\1#")"
		guestsub="${guestdir##*/}"
		if [ -n "$outdir" ] && [ -d "$FIXTURE/$guestsub" ]; then
			mkdir -p "$outdir/$destsub"
			cp -r "$FIXTURE/$guestsub/." "$outdir/$destsub/"
		fi
		exit 0
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
	if grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected NO `container` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# The copy recipe
# ---------------------------------------------------------------------------

@test "retrieve: fetches buildstats into MACKAS_BASE/artifacts" {
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
	printf '%s\n' "$output" | grep -qF "Retrieved to $ROOT/artifacts"
}

@test "retrieve: the copy container run uses -u 0:0 (uid 30000 cannot read root-owned paths)" {
	# Pinned to the exact invocation, not just "-u 0:0 appears somewhere":
	# both the probe and the copy must run as root.
	mk retrieve buildstats
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-tmp:/build] [-v] [$ROOT/artifacts:/out] [ghcr.io/siemens/kas/kas:5.4] [sh] [-c]"
}

@test "retrieve: the -u 0:0 in the copy is asserted against the source too" {
	# This machine's uid is not 0, so an argv match alone could pass against a
	# hardcoded literal on the wrong command. Pin the source form: both the probe
	# and the copy run as -u 0:0.
	grep -qF -- 'run container run --rm -u 0:0 -v "$MACKAS_VOL_TMP:/build" "$KAS_IMAGE" test -d "$guest"' "$MACKAS"
	grep -qF -- '-v "$MACKAS_VOL_TMP:/build" -v "$dest:/out" "$KAS_IMAGE"' "$MACKAS"
}

@test "retrieve: does NOT fetch logs or deploy unless asked" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve buildstats
	refute_call "test] [-d] [/build/tmp/log]"
	refute_call "test] [-d] [/build/tmp/deploy]"
}

@test "retrieve: logs also fetches tmp/log" {
	MOCK_TMP_HAS="buildstats log" mk retrieve buildstats logs
	[ "$status" -eq 0 ]
	assert_call "test] [-d] [/build/tmp/log]"
	[ -d "$ROOT/artifacts/log" ]
}

@test "retrieve: multiple objects in one call fetch all of them" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve buildstats logs deploy
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
	[ -d "$ROOT/artifacts/log" ]
	[ -d "$ROOT/artifacts/deploy" ]
}

@test "retrieve: asks bitbake-getvar for the real path, not the OE-core default" {
	# Angstrom's own conf/distro/angstrom.conf redefines DEPLOY_DIR away from
	# OE-core's ${TMPDIR}/deploy textbook default. retrieve must resolve it via
	# bitbake-getvar rather than assume the default, and must still name the
	# destination after the mackas-facing object key ("deploy"), not whatever
	# basename the resolved guest path happens to have.
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	# bitbake_getvar refuses up front unless MACKAS_PROJECT is a real checkout
	# (MACKAS_PROJECT_DIR must be set, not just MACKAS_KAS_CONFIG) -- give it one.
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	cat > "$ROOT/bin/kas-container" <<'EOF'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR "*) echo "/build/some/renamed-output" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container"
	mkdir -p "$FIXTURE/renamed-output/images"
	echo bin > "$FIXTURE/renamed-output/images/fake2.img"

	MOCK_TMP_HAS="renamed-output" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve deploy
	[ "$status" -eq 0 ]
	assert_call "test] [-d] [/build/some/renamed-output]"
	# Named after the object key, not the resolved path's own basename.
	[ -d "$ROOT/artifacts/deploy/images" ]
	[ ! -d "$ROOT/artifacts/renamed-output" ]
}

@test "retrieve: falls back to the OE-core default with a warning when bitbake-getvar fails" {
	# No gitconfig set up here (the base setup()'s kas-container is an empty
	# stub too) -- bitbake_getvar must fail closed and retrieve must still work.
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'could not resolve BUILDSTATS_BASE'
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
}

@test "retrieve: deploy warns it can be large" {
	MOCK_TMP_HAS="buildstats deploy" mk retrieve deploy
	printf '%s\n' "$output" | grep -qi 'deploy can be large'
}

@test "retrieve: order of objects does not matter" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve deploy logs buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
	[ -d "$ROOT/artifacts/log" ]
	[ -d "$ROOT/artifacts/deploy" ]
}

# ---------------------------------------------------------------------------
# At least one object is required
# ---------------------------------------------------------------------------

@test "retrieve: no object given is a clear usage error, not a silent default" {
	mk retrieve
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs at least one object'
	refute_call "cp -r"
}

@test "retrieve: --dest with no object is still a usage error" {
	mk retrieve --dest "$TESTDIR/elsewhere"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs at least one object'
}

@test "retrieve: an unknown object is refused" {
	mk retrieve bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown object'
}

# ---------------------------------------------------------------------------
# No build has run yet
# ---------------------------------------------------------------------------

@test "retrieve: clear message when no build has run (no tmp/buildstats)" {
	MOCK_TMP_HAS="" mk retrieve buildstats
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'has a build run yet'
	# It must NOT have attempted the copy.
	refute_call "cp -r"
}

# ---------------------------------------------------------------------------
# One-VM rule
# ---------------------------------------------------------------------------

@test "retrieve: refuses when a running container holds the volume (one-VM rule)" {
	MOCK_BUSY_VOLUME="oe-build-tmp" mk retrieve buildstats
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	# Never attached the volume for a copy while it was busy.
	refute_call "oe-build-tmp:/build] [-v]"
}

@test "retrieve: a container holding a DIFFERENT volume does not block the fetch" {
	MOCK_BUSY_VOLUME="some-other-volume" mk retrieve buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "retrieve: --dry-run prints the copy but creates nothing" {
	mk --dry-run retrieve buildstats
	[ "$status" -eq 0 ]
	# The copy command is shown (the guest path survives printf %q verbatim)...
	printf '%s\n' "$output" | grep -qF '/build/tmp/buildstats'
	# ...but nothing was copied out, no dest was made, and no mutating container
	# run was executed. (volume_in_use's read-only ls/status queries may run --
	# they change nothing -- so CLOG is not required to be empty.)
	[ ! -d "$ROOT/artifacts/buildstats" ]
	[ ! -d "$ROOT/artifacts" ]
	refute_call "cp -r"
	refute_call "[run] [--rm] [-u] [0:0]"
}

# ---------------------------------------------------------------------------
# dest override
# ---------------------------------------------------------------------------

@test "retrieve: --dest overrides the default destination" {
	mk retrieve buildstats --dest "$TESTDIR/elsewhere"
	[ "$status" -eq 0 ]
	[ -d "$TESTDIR/elsewhere/buildstats/20260717121723" ]
	[ ! -d "$ROOT/artifacts/buildstats" ]
}

@test "retrieve: --dest with a colon is refused (breaks the bind-mount spec)" {
	mk retrieve buildstats --dest "/tmp/a:b"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "must not contain ':'"
}

@test "retrieve: a relative --dest is absolutised, not read as a named volume" {
	# Apple container reads a relative -v source as a named volume, so files
	# would vanish into a fresh volume. It must be anchored to $PWD.
	mkdir -p "$TESTDIR/rel"
	cd "$TESTDIR/rel"
	mk retrieve buildstats --dest sub
	[ "$status" -eq 0 ]
	assert_call "[-v] [$TESTDIR/rel/sub:/out]"
}

@test "retrieve: hints at 'buildstats analyze' when buildstats was fetched" {
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'buildstats analyze'
}

@test "retrieve: does not hint at 'buildstats analyze' when buildstats was not fetched" {
	MOCK_TMP_HAS="log" mk retrieve logs
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF 'buildstats analyze'
}

@test "retrieve: is idempotent -- a second fetch still succeeds" {
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/20260717121723" ]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "retrieve --help prints usage and does nothing" {
	mk retrieve --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'retrieve'
	refute_call "cp -r"
}
