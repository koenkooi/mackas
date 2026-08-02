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
# combined existence+size probe (`... sh -c "[ -d ... ] || exit 1; du -sk
# ..."`), and the copy itself (`... sh -c 'cp -r ...'`) which actually
# populates the host --dest so `buildstats analyze` (tested separately in
# buildstats_analyze.bats) would have real files to chew on. It also models
# `container ls` / `container inspect` so the one-VM refusal can be exercised.
# Nothing touches the real Apple container runtime, a volume, or the build SSD.

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
	touch "$ROOT/bin/kas-container.real"
	chmod +x "$ROOT/bin/kas-container.real"

	CLOG="$TESTDIR/container.log"
	export CLOG

	# retrieve buildstats nests each retrieval under its own timestamp
	# (fetch_tmp_subdir's EXTRA param -- see cmd_retrieve) so successive
	# retrievals never merge into the same host path. MACKAS_RETRIEVE_TS is
	# an undocumented test seam (cf. MACKAS_OVERHEAD_BIN) for a deterministic
	# value here instead of the real `date +%Y%m%d%H%M%S`.
	RETRIEVE_TS="20260722000000"
	export MACKAS_RETRIEVE_TS="$RETRIEVE_TS"

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
	# buildhistory is NOT under tmp/ in the guest -- it is ${TOPDIR}/buildhistory,
	# i.e. /build/buildhistory, a sibling of /build/tmp. The fixture is flat, so
	# it sits alongside the others here; the probe path is what the tests pin.
	mkdir -p "$FIXTURE/buildhistory/packages" "$FIXTURE/buildhistory/images"
	echo 'PV = 1.36.1' > "$FIXTURE/buildhistory/packages/latest"
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

# The combined existence+size probe: `... sh -c "[ -d <guest> ] || exit 1;
# du -sk <guest> 2>/dev/null; exit 0"`. Succeed (and print a MOCK_DU_KB-sized
# `du -sk` line) only for a listed sub; MOCK_DU_FAIL models a `du` that errors
# on an existing directory -- still exit 0 (existence, not size, gates
# success), just nothing printed.
case "${@: -1}" in
	*"du -sk"*)
		guest="$(printf '%s\n' "${@: -1}" | sed -E 's#.*du -sk ([^ ]+).*#\1#')"
		sub="${guest##*/}"
		case " $MOCK_TMP_HAS " in
			*" $sub "*)
				[ -n "${MOCK_DU_FAIL:-}" ] || printf '%s\t%s\n' "${MOCK_DU_KB:-4096}" "$guest"
				exit 0
				;;
			*) exit 1 ;;
		esac
		;;
esac

# The copy: `... sh -c "mkdir -p '/out/<sub>' && cp -r '<guest>/.' '/out/<sub>/'"`.
# destsub (the mackas-facing object key, e.g. "deploy") and guestsub (the
# resolved guest path's own basename, or -- for item 24's nested deploy/images
# object specifically -- its path relative to the fixture root) are extracted
# independently -- they can differ when bitbake-getvar resolves a
# distro-redefined path, and the destination must be named after destsub
# regardless.
last="${@: -1}"
case "$last" in
	*"cp -r"*)
		destsub="$(printf '%s\n' "$last" | sed -E "s#.*mkdir -p '/out/([^']*)'.*#\1#")"
		guestdir="$(printf '%s\n' "$last" | sed -E "s#.*cp -r '([^']*)/\.'.*#\1#")"
		case "$guestdir" in
			*/deploy/images|*/deploy/images/*)
				# Nested object: keep it relative to the fixture root
				# ($FIXTURE/deploy/images[/machine]) rather than a bare
				# basename, which would look for a same-named top-level dir
				# that does not exist.
				guestsub="deploy/images${guestdir#*/deploy/images}"
				;;
			*) guestsub="${guestdir##*/}" ;;
		esac
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
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
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
	grep -qF -- 'probe="$(container run --rm -u 0:0 -v "$MACKAS_VOL_TMP:/build" "$KAS_IMAGE" \' "$MACKAS"
	grep -qF -- 'du -sk $(printf '"'"'%q'"'"' "$guest")' "$MACKAS"
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
	assert_call "-d /build/tmp/log ]"
	[ -d "$ROOT/artifacts/log" ]
}

@test "retrieve: multiple objects in one call fetch all of them" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve buildstats logs deploy
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
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
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR "*) echo "/build/some/renamed-output" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	mkdir -p "$FIXTURE/renamed-output/images"
	echo bin > "$FIXTURE/renamed-output/images/fake2.img"

	MOCK_TMP_HAS="renamed-output" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve deploy
	[ "$status" -eq 0 ]
	assert_call "-d /build/some/renamed-output ]"
	# Named after the object key, not the resolved path's own basename.
	[ -d "$ROOT/artifacts/deploy/images" ]
	[ ! -d "$ROOT/artifacts/renamed-output" ]
}

@test "retrieve: bitbake_getvar skips the repo steps even WITH a parseable state" {
	# This used to assert '-k', and that was half of a data-loss bug: -k was
	# passed only when conf/local.conf + conf/bblayers.conf already existed,
	# and NOTHING was passed otherwise -- so on a fresh checkout kas ran its
	# full setup, including repos_checkout and repos_apply_patches, and reset
	# every declared repo. Local commits in a layer under work/ were lost that
	# way for real.
	#
	# The fix is unconditional: always skip the four repo-mutating steps, and
	# never skip write_bbconfig (the one -k would also skip, and the one a
	# checkout with no conf/ still needs). So the SAME flags must appear here,
	# where a parseable state exists, as on a fresh checkout -- that sameness
	# is the point, since the conditional is what made the bug possible.
	mkdir -p "$ROOT/work/meta-angstrom/.git" "$ROOT/work/meta-angstrom/conf"
	touch "$ROOT/work/meta-angstrom/conf/local.conf" "$ROOT/work/meta-angstrom/conf/bblayers.conf"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	KREC="$TESTDIR/kas-argv.log"
	export KREC
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	for a in "$@"; do printf '[%s] ' "$a"; done
	printf '\n'
} >> "$KREC"
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR "*) echo "/build/deploy" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"

	MOCK_TMP_HAS="deploy" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve deploy
	[ "$status" -eq 0 ]
	grep -qF "[shell] [--skip] [setup_dir] [--skip] [finish_setup_repos] [--skip] [repos_checkout] [--skip] [repos_apply_patches] [" "$KREC"
	# -k is NOT used: it would also skip write_bbconfig.
	assert_fails grep -qF "[-k]" "$KREC"
}

@test "retrieve: bitbake_getvar omits -k on a checkout with no parseable state yet" {
	# -k also skips write_bbconfig -- a checkout that has never had
	# local.conf/bblayers.conf written would have nothing to parse if -k
	# were forced unconditionally. Omitting it lets kas do that one-time
	# setup so the query can actually succeed.
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	KREC="$TESTDIR/kas-argv.log"
	export KREC
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	for a in "$@"; do printf '[%s] ' "$a"; done
	printf '\n'
} >> "$KREC"
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR "*) echo "/build/deploy" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"

	MOCK_TMP_HAS="deploy" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve deploy
	[ "$status" -eq 0 ]
	! grep -qF "[-k]" "$KREC"
	grep -qF "[shell] [" "$KREC"
}

@test "retrieve: falls back to the OE-core default with a warning when bitbake-getvar fails" {
	# No gitconfig set up here (the base setup()'s kas-container is an empty
	# stub too) -- bitbake_getvar must fail closed and retrieve must still work.
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'could not resolve BUILDSTATS_BASE'
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
}

@test "retrieve: reports the real measured size to transfer, not a fixed guess" {
	# Item 33: replaces the old hardcoded "deploy can be large" line -- every
	# object gets a REAL, measured figure now, not just deploy.
	MOCK_TMP_HAS="buildstats deploy" MOCK_DU_KB=4194304 mk retrieve deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "deploy: 4.0G to transfer"
	! printf '%s\n' "$output" | grep -qi 'deploy can be large'
}

@test "retrieve: a du failure does not block the retrieval (size reporting is a nicety)" {
	MOCK_TMP_HAS="buildstats" MOCK_DU_FAIL=1 mk retrieve buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
	! printf '%s\n' "$output" | grep -qF 'to transfer'
}

@test "retrieve: warns when the destination looks too small for the measured size" {
	# An absurdly large MOCK_DU_KB (~9.5 PiB) guarantees no real disk has that
	# much free space, so this needs no df fake -- the real df on this host is
	# always the failing side of the comparison.
	MOCK_TMP_HAS="buildstats" MOCK_DU_KB=10000000000000 mk retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'may not have enough free space'
}

@test "retrieve: order of objects does not matter" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve deploy logs buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
	[ -d "$ROOT/artifacts/log" ]
	[ -d "$ROOT/artifacts/deploy" ]
}

# ---------------------------------------------------------------------------
# Item 24: 'retrieve deploy images [MACHINE]' narrows to DEPLOY_DIR_IMAGE
# ---------------------------------------------------------------------------

@test "retrieve: deploy images narrows to DEPLOY_DIR_IMAGE, not the whole deploy tree" {
	MOCK_TMP_HAS="images" mk retrieve deploy images
	[ "$status" -eq 0 ]
	# bitbake-getvar is unwired in this test (no real checkout) -- falls back
	# to the DEPLOY_DIR_IMAGE default, /build/tmp/deploy/images, NOT bare
	# /build/tmp/deploy (the whole-tree object's own default).
	assert_call "-d /build/tmp/deploy/images ]"
	[ -d "$ROOT/artifacts/deploy/images" ]
	# The whole-tree object was never asked for.
	refute_call "-d /build/tmp/deploy ]"
}

@test "retrieve: deploy images asks bitbake-getvar for DEPLOY_DIR_IMAGE, not a hand-built path" {
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	cat > "$ROOT/bin/kas-container.real" <<'STUB'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR_IMAGE "*) echo "/build/some/dist/images/qemuarm" ;;
esac
exit 0
STUB
	chmod +x "$ROOT/bin/kas-container.real"
	MACKAS_PROJECT_DIR=meta-angstrom MOCK_TMP_HAS="qemuarm" mk retrieve deploy images
	[ "$status" -eq 0 ]
	assert_call "-d /build/some/dist/images/qemuarm ]"
}

@test "retrieve: deploy images MACHINE substitutes only the trailing path component" {
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	cat > "$ROOT/bin/kas-container.real" <<'STUB'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR_IMAGE "*) echo "/build/some/dist/images/qemuarm" ;;
esac
exit 0
STUB
	chmod +x "$ROOT/bin/kas-container.real"
	MACKAS_PROJECT_DIR=meta-angstrom MOCK_TMP_HAS="qemuarm-armv5te" \
		mk retrieve deploy images qemuarm-armv5te
	[ "$status" -eq 0 ]
	# The real answer's DEPLOY_DIR-ish prefix ("/build/some/dist/images")
	# survives untouched -- only the trailing "qemuarm" is swapped for the
	# requested MACHINE, never a blind DEPLOY_DIR/images/<machine> guess.
	assert_call "-d /build/some/dist/images/qemuarm-armv5te ]"
	refute_call "-d /build/some/dist/images/qemuarm ]"
}

@test "retrieve: deploy images MACHINE falls back with the machine already appended" {
	# bitbake-getvar unwired (no real checkout): the fallback default must be
	# built WITH the requested machine in place, not substituted afterward --
	# there is no real trailing component to swap in the fallback path.
	MOCK_TMP_HAS="qemuarm-armv5te" mk retrieve deploy images qemuarm-armv5te
	[ "$status" -eq 0 ]
	assert_call "-d /build/tmp/deploy/images/qemuarm-armv5te ]"
}

@test "retrieve: deploy images composes with another object in one call" {
	MOCK_TMP_HAS="buildstats images" mk retrieve deploy images buildstats
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/deploy/images" ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
}

@test "retrieve: deploy images does not swallow --dest as a MACHINE" {
	MOCK_TMP_HAS="images" mk retrieve deploy images --dest "$TESTDIR/elsewhere"
	[ "$status" -eq 0 ]
	[ -d "$TESTDIR/elsewhere/deploy/images" ]
	assert_call "-d /build/tmp/deploy/images ]"
}

@test "retrieve: deploy images does not swallow the next object as a MACHINE" {
	MOCK_TMP_HAS="images log" mk retrieve deploy images logs
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/deploy/images" ]
	[ -d "$ROOT/artifacts/log" ]
	assert_call "-d /build/tmp/deploy/images ]"
	assert_call "-d /build/tmp/log ]"
}

@test "retrieve: bare 'deploy' still fetches the whole tree, unaffected by item 24" {
	MOCK_TMP_HAS="buildstats log deploy" mk retrieve deploy
	[ "$status" -eq 0 ]
	assert_call "-d /build/tmp/deploy ]"
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
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "retrieve: --dry-run prints the copy but creates nothing" {
	mk --dry-run retrieve buildstats
	[ "$status" -eq 0 ]
	# The copy command is shown (the guest path survives printf %q verbatim)...
	printf '%s\n' "$output" | grep -qF '/build/tmp/buildstats'
	# ...but nothing was copied out and no dest was made. The existence+size
	# probe (item 33) DOES run for real even under --dry-run -- same reasoning
	# as clean_tmp_deploy/sstate_prune's own read-only probes: a preview is
	# more useful showing the real transfer size than an assumed yes -- so
	# CLOG is not expected to be empty and a real size IS reported here.
	[ ! -d "$ROOT/artifacts/buildstats" ]
	[ ! -d "$ROOT/artifacts" ]
	printf '%s\n' "$output" | grep -qF 'buildstats: 4.0M to transfer'
	refute_call "cp -r"
	refute_call ":/out]"
}

# ---------------------------------------------------------------------------
# dest override
# ---------------------------------------------------------------------------

@test "retrieve: --dest overrides the default destination" {
	mk retrieve buildstats --dest "$TESTDIR/elsewhere"
	[ "$status" -eq 0 ]
	[ -d "$TESTDIR/elsewhere/buildstats/$RETRIEVE_TS/20260717121723" ]
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
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
}

# ---------------------------------------------------------------------------
# BUILDNAME accumulation: buildstats.bbclass appends build_stats forever for a
# project whose BUILDNAME does not vary per build (e.g. Angstrom's
# `BUILDNAME = "Angstrom ${DISTRO_VERSION}"`). More than one "Build Started:"
# line in the JUST-RETRIEVED build_stats is read directly off that file, not
# inferred across retrievals.
# ---------------------------------------------------------------------------

@test "retrieve: warns and offers to clear the volume's buildstats when the file shows more than one build" {
	cat > "$FIXTURE/buildstats/20260717121723/build_stats" <<'EOF'
Host Info: Linux
Build Started: 500.00
Elapsed time: 10.00 seconds
CPU usage: 40.0%
Host Info: Linux
Build Started: 1000.00
Elapsed time: 42.00 seconds
CPU usage: 55.5%
EOF
	mk -y retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "2 builds' data accumulated"
	assert_call "[rm] [-rf] [/build/tmp/buildstats/20260717121723]"
}

@test "retrieve: declining the clear offer leaves the volume's buildstats untouched" {
	cat > "$FIXTURE/buildstats/20260717121723/build_stats" <<'EOF'
Build Started: 500.00
Elapsed time: 10.00 seconds
Build Started: 1000.00
Elapsed time: 42.00 seconds
EOF
	# Not a terminal and no -y/--yes: confirm() declines.
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "accumulated"
	refute_call "[rm] [-rf]"
}

@test "retrieve: no accumulation warning for a normal single-build build_stats" {
	mk retrieve buildstats
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qi "accumulated"
	refute_call "[rm] [-rf]"
}

# ---------------------------------------------------------------------------
# buildhistory -- the one object that does NOT live under tmp/, and the one
# that is absent for most projects because buildhistory.bbclass is not
# inherited by default.
# ---------------------------------------------------------------------------

@test "retrieve: fetches buildhistory into MACKAS_BASE/artifacts" {
	MOCK_TMP_HAS="buildhistory" mk retrieve buildhistory
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildhistory/packages" ]
	[ -f "$ROOT/artifacts/buildhistory/packages/latest" ]
	printf '%s\n' "$output" | grep -qF "Retrieved to $ROOT/artifacts"
}

@test "retrieve: buildhistory is probed at /build/buildhistory, NOT under tmp/" {
	# BUILDHISTORY_DIR defaults to ${TOPDIR}/buildhistory, and TOPDIR inside the
	# container is /build -- so the fallback used when bitbake-getvar cannot
	# answer is a SIBLING of tmp/, not a child. A tmp-shaped fallback would
	# probe a path that can never exist and report buildhistory as missing on
	# every project that has it.
	MOCK_TMP_HAS="buildhistory" mk retrieve buildhistory
	[ "$status" -eq 0 ]
	assert_call "-d /build/buildhistory ]"
	refute_call "test] [-d] [/build/tmp/buildhistory]"
}

@test "retrieve: buildhistory asks bitbake-getvar for BUILDHISTORY_DIR, not an assumed default" {
	# BUILDHISTORY_DIR is as redefinable as DEPLOY_DIR -- a project may point it
	# at a directory that survives 'mackas clean', which is a sensible thing to
	# do. The resolved path must win over the class default, and the host
	# destination must still be named after the object key.
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q BUILDHISTORY_DIR "*) echo "/build/elsewhere/bh-store" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	mkdir -p "$FIXTURE/bh-store/images"
	echo img > "$FIXTURE/bh-store/images/files-in-image.txt"

	MOCK_TMP_HAS="bh-store" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve buildhistory
	[ "$status" -eq 0 ]
	assert_call "-d /build/elsewhere/bh-store ]"
	refute_call "test] [-d] [/build/buildhistory]"
	# Named after the object key, not the resolved path's own basename.
	[ -d "$ROOT/artifacts/buildhistory/images" ]
	[ ! -d "$ROOT/artifacts/bh-store" ]
}

@test "retrieve: says the project does not INHERIT buildhistory when it is absent" {
	# The common case by far: buildhistory.bbclass is not inherited by default,
	# so there is nothing to copy and nothing wrong. A bare "no such directory"
	# reads like a broken build; this must name the cause and the one-line fix.
	MOCK_TMP_HAS="" mk retrieve buildhistory
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not INHERIT buildhistory'
	printf '%s\n' "$output" | grep -qF 'INHERIT += "buildhistory"'
	# Not the generic per-object "skipping" wording, and not buildstats' one.
	! printf '%s\n' "$output" | grep -qi 'has a build run yet'
	refute_call "cp -r"
}

@test "retrieve: buildhistory swallows bitbake-getvar's real 'not defined' wording" {
	# bitbake-getvar's own source (bin/bitbake-getvar) does exactly this for an
	# undefined variable: exit 1, "The variable 'X' is not defined" on stderr,
	# not a quiet empty value. BUILDHISTORY_DIR is defined nowhere but inside
	# buildhistory.bbclass, so a project that does not inherit it hits this
	# exact wording on every retrieve -- a real, expected outcome, not the
	# generic bitbake-getvar failure the OTHER "does not INHERIT" test above
	# models via an empty stub. Both generic warnings (bitbake_getvar's own,
	# and fetch_tmp_subdir's "assuming the default") must stay silent here:
	# the buildhistory-specific message already says everything there is to
	# say, and printing both would read like two things went wrong instead
	# of one expected thing.
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
case " $* " in
	*"bitbake-getvar --value -q BUILDHISTORY_DIR "*)
		echo "The variable 'BUILDHISTORY_DIR' is not defined" >&2
		exit 1
		;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"

	MOCK_TMP_HAS="" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve buildhistory
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not INHERIT buildhistory'
	! printf '%s\n' "$output" | grep -qF 'bitbake-getvar failed for BUILDHISTORY_DIR'
	! printf '%s\n' "$output" | grep -qF 'could not resolve BUILDHISTORY_DIR'
	assert_call "-d /build/buildhistory ]"
}

@test "retrieve: --dry-run buildhistory prints the copy but creates nothing" {
	MOCK_TMP_HAS="buildhistory" mk --dry-run retrieve buildhistory
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '/build/buildhistory'
	[ ! -d "$ROOT/artifacts/buildhistory" ]
	[ ! -d "$ROOT/artifacts" ]
	refute_call "cp -r"
	refute_call ":/out]"
}

@test "retrieve: buildhistory composes with the other objects in one call" {
	MOCK_TMP_HAS="buildstats buildhistory" mk retrieve buildstats buildhistory
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
	[ -d "$ROOT/artifacts/buildhistory/packages" ]
	# Each object resolved its own path: buildstats keeps its tmp-shaped one.
	assert_call "-d /build/tmp/buildstats ]"
	assert_call "-d /build/buildhistory ]"
	# Both hints, and buildstats still nests under the retrieve timestamp.
	printf '%s\n' "$output" | grep -qF 'buildstats analyze'
	printf '%s\n' "$output" | grep -qF "git -C $ROOT/artifacts/buildhistory log"
}

@test "retrieve: a missing buildhistory does not sink the other objects" {
	# Per-object, best-effort: buildstats is retrieved and reported even though
	# buildhistory is absent, and the exit status reflects that something was
	# retrieved.
	MOCK_TMP_HAS="buildstats" mk retrieve buildstats buildhistory
	[ "$status" -eq 0 ]
	[ -d "$ROOT/artifacts/buildstats/$RETRIEVE_TS/20260717121723" ]
	printf '%s\n' "$output" | grep -qi 'does not INHERIT buildhistory'
	[ ! -d "$ROOT/artifacts/buildhistory" ]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "retrieve --help prints usage and does nothing" {
	mk retrieve --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'retrieve'
	# Every object is documented, buildhistory included.
	printf '%s\n' "$output" | grep -qF 'buildhistory'
	refute_call "cp -r"
}

@test "retrieve: bitbake-getvar can NEVER run kas's repo-mutating steps" {
	# A data-loss regression, hit for real. bitbake_getvar used -k only when
	# conf/local.conf already existed and passed NOTHING otherwise -- and with
	# no local.conf, kas runs its full setup, including repos_checkout and
	# repos_apply_patches, which reset every declared repo to its pinned
	# revision. That wiped local commits in a layer checkout under work/.
	# `mackas retrieve` calls this, so copying build output off a volume could
	# silently destroy unpushed work.
	#
	# The four repo-touching steps must be skipped ALWAYS, on a fresh checkout
	# and a configured one alike. write_bbconfig is deliberately NOT skipped
	# (that is the one -k would also skip, and a checkout with no conf/ needs
	# it) -- which is why this is four --skip flags rather than -k.
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	# Deliberately NO conf/local.conf: this is the branch that used to run the
	# full setup and reset the repos.
	assert_fails test -f "$ROOT/work/meta-angstrom/conf/local.conf"

	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KASARGV_LOG"
case " $* " in
	*"bitbake-getvar --value -q DEPLOY_DIR "*) echo "/build/deploy" ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	KASARGV_LOG="$ROOT/kasargv.log"; export KASARGV_LOG
	: > "$KASARGV_LOG"

	mkdir -p "$FIXTURE/deploy/images"
	echo bin > "$FIXTURE/deploy/images/fake.img"
	MOCK_TMP_HAS="deploy" MACKAS_PROJECT_DIR=meta-angstrom mk retrieve deploy
	[ "$status" -eq 0 ]

	# Every repo-mutating step is skipped...
	grep -qF -- '--skip setup_dir' "$KASARGV_LOG"
	grep -qF -- '--skip finish_setup_repos' "$KASARGV_LOG"
	grep -qF -- '--skip repos_checkout' "$KASARGV_LOG"
	grep -qF -- '--skip repos_apply_patches' "$KASARGV_LOG"
	# ...and write_bbconfig is NOT, so a fresh checkout can still be parsed.
	assert_fails grep -qF -- '--skip write_bbconfig' "$KASARGV_LOG"
	# ...and it is never invoked bare, which is what caused the reset.
	assert_fails grep -qE 'shell [^-]' "$KASARGV_LOG"
}
