#!/usr/bin/env bats
#
# Tests for `mackas clean`'s targeted forms -- tmp+deploy, downloads, sstate --
# added alongside the pre-existing bare 'clean' (whole TMPDIR volume,
# unchanged, covered by volumes_cmd.bats).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas` as a subprocess with a fake `container` (and, for the
# bitbake-getvar cases, a fake `kas-container`) on PATH, both of which record
# their argv. Nothing here touches the real Apple container runtime, the
# build SSD or the network.

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
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	CLOG="$TESTDIR/container.log"
	export CLOG

	# Which volumes currently "exist", as far as the fake engine is concerned.
	# clean_volume_target/clean_tmpdir_volume delete-then-recreate, so a
	# static list would lie -- 'volume create'/'volume delete' mutate this.
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"

	# Which guest paths a 'test -d' probe (inside the tmp+deploy target)
	# should report as present, space-separated. Mirrors retrieve.bats'
	# MOCK_TMP_HAS.
	MOCK_TMP_HAS=""
	export MOCK_TMP_HAS

	# MOCK_BUSY_VOLUME: a volume the fake engine reports as held by a running
	# container, for the one-VM refusal tests.
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
		exit 0 ;;
	"volume create")
		eval "name=\${$#}"
		printf '%s\n' "$name" >> "$VSTATE"
		exit 0 ;;
	"volume delete"|"volume rm")
		grep -vxF "$3" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		exit 0 ;;
	"ls "*|"ls")
		echo "ID"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "runner1"
		exit 0 ;;
	"inspect "*)
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		exit 0 ;;
	"system status") echo "status running"; exit 0 ;;
	"image ls") echo "NAME TAG"; echo "ghcr.io/siemens/kas/kas 5.4"; exit 0 ;;
esac

# Fall through: 'container run ...'. Two shapes matter here: the combined
# probe (a single 'sh -c' testing both paths) and the delete (another 'sh -c'
# with 'rm -rf'), plus ensure_volume's own 'chown'.
last="${@: -1}"
case "$last" in
	*"[ -d "*)
		# The probe: '[ -d P1 ] || [ -d P2 ]'. Succeed if ANY named path is
		# listed in MOCK_TMP_HAS (space-separated guest paths, not basenames --
		# the probe tests the exact resolved path).
		for p in $MOCK_TMP_HAS; do
			case " $last " in
				*" $p "*|*"'$p'"*) exit 0 ;;
			esac
			# also match without quoting, since printf %q leaves plain paths bare
			case "$last" in
				*" $p "*|*"$p ]"*) exit 0 ;;
			esac
		done
		exit 1 ;;
	*"rm -rf"*) exit 0 ;;
	chown) exit 0 ;;
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

have_volumes() {
	printf '%s\n' "$@" > "$VSTATE"
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

# fake_kas_container VAR=VALUE... -- a kas-container stub answering
# 'bitbake-getvar --value -q VAR' for each VAR=VALUE pair given, and set up
# the real checkout + gitconfig bitbake_getvar() requires to ever invoke it.
fake_kas_container() {
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"
	mkdir -p "$ROOT/work/meta-angstrom/.git"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'case " $* " in\n'
		local pair var val
		for pair in "$@"; do
			var="${pair%%=*}"; val="${pair#*=}"
			printf '\t*"bitbake-getvar --value -q %s "*) echo %q ;;\n' "$var" "$val"
		done
		printf 'esac\n'
		printf 'exit 0\n'
	} > "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"
}

# ---------------------------------------------------------------------------
# Parser / dispatcher
# ---------------------------------------------------------------------------

@test "clean: an unknown target is refused, naming the valid ones" {
	mk clean bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'unknown target'
	printf '%s\n' "$output" | grep -qF 'tmp+deploy downloads sstate'
}

@test "clean --help / help / 'help clean' all show clean_usage, with the targets documented" {
	for args in "clean --help" "clean help" "help clean"; do
		# shellcheck disable=SC2086
		mk $args
		[ "$status" -eq 0 ]
		printf '%s\n' "$output" | grep -qF 'TARGETS'
		printf '%s\n' "$output" | grep -qF 'tmp+deploy'
		printf '%s\n' "$output" | grep -qF 'downloads'
		printf '%s\n' "$output" | grep -qF 'sstate'
	done
}

@test "clean: global flags are accepted both before and after the command word" {
	have_volumes oe-build-dl
	mk --dry-run clean downloads
	[ "$status" -eq 0 ]
	mk clean downloads --dry-run
	[ "$status" -eq 0 ]
}

@test "clean: --config after the command word is refused with a clear redirect" {
	mk clean downloads --config /tmp/whatever.conf
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'must come BEFORE'
}

# ---------------------------------------------------------------------------
# tmp+deploy
# ---------------------------------------------------------------------------

@test "clean tmp+deploy: resolves TMPDIR and DEPLOY_DIR via bitbake-getvar, not assumed defaults" {
	have_volumes oe-build-tmp
	fake_kas_container "TMPDIR=/build/tmp" "DEPLOY_DIR=/build/deploy"
	MOCK_TMP_HAS="/build/deploy" MACKAS_PROJECT_DIR=meta-angstrom mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	assert_call "rm -rf"
	# The resolved DEPLOY_DIR (a sibling of tmp/, as Angstrom sets it) reaches
	# the rm, not a guessed /build/tmp/deploy default.
	grep -A2 'rm -rf' "$CLOG" | grep -qF '/build/deploy' || \
		grep -F 'rm -rf' "$CLOG" | grep -qF '/build/deploy'
}

@test "clean tmp+deploy: falls back to the defaults with a warning when bitbake-getvar fails" {
	have_volumes oe-build-tmp
	# The base setup()'s kas-container is an empty stub -- bitbake_getvar must
	# fail closed and clean must still work against the assumed defaults.
	MOCK_TMP_HAS="/build/tmp" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'could not resolve TMPDIR'
	printf '%s\n' "$output" | grep -qi 'could not resolve DEPLOY_DIR'
}

@test "clean tmp+deploy: never deletes or recreates the TMPDIR volume itself" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	refute_call "volume delete"
	refute_call "volume rm"
	refute_call "volume create"
	# The volume is still there afterward.
	grep -qxF oe-build-tmp "$VSTATE"
}

@test "clean tmp+deploy: one-VM refusal when oe-build-tmp is busy" {
	have_volumes oe-build-tmp
	MOCK_BUSY_VOLUME=oe-build-tmp mk clean tmp+deploy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'attached to a running container'
	refute_call "rm -rf"
}

@test "clean tmp+deploy: a container holding a DIFFERENT volume does not block it" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" MOCK_BUSY_VOLUME=oe-build-sstate mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	assert_call "rm -rf"
}

@test "clean tmp+deploy: --dry-run probes for real but deletes nothing" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk --dry-run clean tmp+deploy
	[ "$status" -eq 0 ]
	# The read-only probe always runs, dry-run or not (same reasoning as
	# sstate prune's scan): its 'test -d' shows up in the real container log.
	assert_call "[ -d "
	# But the delete is gated through run(), so under --dry-run it only
	# prints -- it never reaches the fake container. quote_cmd's printf %q
	# escapes the space in "rm -rf", so match the pieces separately rather
	# than the literal unescaped string.
	refute_call "rm -rf"
	printf '%s\n' "$output" | grep -qF -- '-rf'
	printf '%s\n' "$output" | grep -qF '/build/tmp'
}

@test "clean tmp+deploy: declining leaves everything untouched" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk clean tmp+deploy < /dev/null
	[ "$status" -ne 0 ]
	refute_call "rm -rf"
}

@test "clean tmp+deploy: nothing to clean when neither path exists yet" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to clean'
	refute_call "rm -rf"
}

@test "clean tmp+deploy: nothing to clean when the TMPDIR volume does not exist at all" {
	MOCK_TMP_HAS="" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to clean'
	refute_call "test"
}

@test "clean tmp+deploy: explains the refill is sstate restores, not fresh rebuilds" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'stamps went with TMPDIR'
	printf '%s\n' "$output" | grep -qi 'sstate restores'
}

@test "clean tmp+deploy: auto-fstrims TMPDIR afterward (the in-place rm does not reclaim host disk on its own)" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	assert_call "[fstrim] [-v] [/mnt]"
}

@test "clean tmp+deploy: MACKAS_FSTRIM_AUTO=0 skips the auto-fstrim" {
	have_volumes oe-build-tmp
	MOCK_TMP_HAS="/build/tmp" mk -y --set MACKAS_FSTRIM_AUTO=0 clean tmp+deploy
	[ "$status" -eq 0 ]
	refute_call "fstrim"
}

@test "clean tmp+deploy: skips the auto-fstrim (declined/nothing-to-clean paths never reach it)" {
	have_volumes oe-build-tmp
	# Nothing to clean: neither TMPDIR nor DEPLOY_DIR exists yet.
	MOCK_TMP_HAS="" mk -y clean tmp+deploy
	[ "$status" -eq 0 ]
	refute_call "fstrim"
	# Declined: no -y and not a tty, so confirm() auto-declines before the rm.
	MOCK_TMP_HAS="/build/tmp" mk clean tmp+deploy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	refute_call "rm -rf"
	refute_call "fstrim"
}

@test "clean tmp+deploy: refuses an unsafe resolved path instead of rm-ing it" {
	have_volumes oe-build-tmp
	for bad in "/build" "/" "/sstate/deploy" "/build/../etc"; do
		fake_kas_container "TMPDIR=/build/tmp" "DEPLOY_DIR=$bad"
		MOCK_TMP_HAS="/build/tmp $bad" MACKAS_PROJECT_DIR=meta-angstrom mk -y clean tmp+deploy
		if [ "$status" -eq 0 ]; then
			echo "expected a refusal for DEPLOY_DIR=$bad" >&2
			printf '%s\n' "$output" >&2
			return 1
		fi
		printf '%s\n' "$output" | grep -qi 'not safely under /build'
		refute_call "rm -rf"
		: > "$CLOG"
	done
}

# ---------------------------------------------------------------------------
# downloads
# ---------------------------------------------------------------------------

@test "clean downloads: deletes and recreates ONLY the dl volume" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mk -y clean downloads
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-dl]"
	assert_call "[volume] [create]"
	grep -qxF oe-build-tmp "$VSTATE"
	grep -qxF oe-build-dl "$VSTATE"
	grep -qxF oe-build-sstate "$VSTATE"
}

@test "clean downloads: one-VM refusal when oe-build-dl is busy" {
	have_volumes oe-build-dl
	MOCK_BUSY_VOLUME=oe-build-dl mk clean downloads
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'attached to a running container'
	refute_call "volume delete"
}

@test "clean downloads: --dry-run deletes nothing" {
	have_volumes oe-build-dl
	mk --dry-run clean downloads
	[ "$status" -eq 0 ]
	refute_call "volume delete"
}

@test "clean downloads: mentions a mirror only when one is configured" {
	have_volumes oe-build-dl
	mk -y clean downloads
	printf '%s\n' "$output" | grep -qi 'no mirror configured'

	have_volumes oe-build-dl
	: > "$CLOG"
	mk -y --set MACKAS_USE_HTTP_MIRRORS=1 clean downloads
	printf '%s\n' "$output" | grep -qi 'mirror is configured'
}

@test "clean downloads: nothing to clean when the volume does not exist yet" {
	mk -y clean downloads
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to clean'
	refute_call "volume delete"
}

# ---------------------------------------------------------------------------
# sstate
# ---------------------------------------------------------------------------

@test "clean sstate: deletes and recreates ONLY the sstate volume" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mk -y clean sstate
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-sstate]"
	grep -qxF oe-build-tmp "$VSTATE"
	grep -qxF oe-build-dl "$VSTATE"
	grep -qxF oe-build-sstate "$VSTATE"
}

@test "clean sstate: one-VM refusal when oe-build-sstate is busy" {
	have_volumes oe-build-sstate
	MOCK_BUSY_VOLUME=oe-build-sstate mk clean sstate
	[ "$status" -ne 0 ]
	refute_call "volume delete"
}

@test "clean sstate: points at 'sstate prune --older-than' for partial cleanup" {
	have_volumes oe-build-sstate
	mk -y clean sstate
	printf '%s\n' "$output" | grep -qF 'sstate prune --older-than'
}

# ---------------------------------------------------------------------------
# Combining targets
# ---------------------------------------------------------------------------

@test "clean downloads sstate: does both, order-independent, neither touches TMPDIR" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mk -y clean sstate downloads
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-dl]"
	assert_call "[volume] [delete] [oe-build-sstate]"
	refute_call "[volume] [delete] [oe-build-tmp]"
}
