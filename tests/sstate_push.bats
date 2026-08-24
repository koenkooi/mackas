#!/usr/bin/env bats
#
# Tests for `mackas sstate push` -- publishing new sstate objects to a mirror.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas sstate push` as a subprocess with a fake `container` AND
# a fake `rsync` on PATH, so nothing here reaches the Apple container runtime,
# a volume, a network or an ssh host. The container mock models the two calls
# that matter: the newer-than-the-stamp probe (which reports a scripted object
# count and size) and the staged copy, which really populates the host staging
# directory from a fixture and prints the "source" manifest by extracting
# retrieve_verify_local() fresh out of the real mackas -- the same trick
# retrieve.bats uses, so an uncorrupted copy verifies and a corrupted one does
# not, without a second manifest implementation to keep in sync. The rsync
# mock records its argv, which is what pins the two-pass ordering and the
# --ignore-existing / never --inplace contract.

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

	CLOG="$TESTDIR/container.log"
	RLOG="$TESTDIR/rsync.log"
	export CLOG RLOG
	export REAL_MACKAS="$MACKAS"

	DEST="mirror@example.invalid:/srv/mackas/sstate"
	export DEST

	# Stands in for the guest's /sstate: one payload object and its siginfo,
	# the pair whose ORDER on the wire is the thing push has to get right.
	FIXTURE="$TESTDIR/guest-sstate"
	mkdir -p "$FIXTURE/universal/ab"
	echo payload > "$FIXTURE/universal/ab/sstate-busybox-populate-sysroot.tgz"
	echo sig     > "$FIXTURE/universal/ab/sstate-busybox-populate-sysroot.tgz.siginfo"
	export FIXTURE

	# How many objects the probe reports as newer than the stamp, and their
	# size in KB. 0 -> the "nothing new" path.
	MOCK_NEWER_COUNT=2
	MOCK_NEWER_KB=64
	export MOCK_NEWER_COUNT MOCK_NEWER_KB

	: > "$CLOG"
	: > "$RLOG"

	MOCK_BUSY_VOLUME=""
	MOCK_RSYNC_FAIL=""
	MOCK_VERIFY_CORRUPT=""
	MOCK_VERIFY_CORRUPT_ALWAYS=""
	export MOCK_BUSY_VOLUME MOCK_RSYNC_FAIL MOCK_VERIFY_CORRUPT MOCK_VERIFY_CORRUPT_ALWAYS

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
	"system start") exit 0 ;;
	"volume ls")
		echo "NAME TYPE DRIVER OPTIONS"
		echo "oe-build-sstate named local size=40G"
		exit 0
		;;
	"container ls"|"ls ")
		echo "ID  IMAGE  STATE"
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && echo "buildbox  kas  running"
		exit 0
		;;
	"container inspect"|"inspect "*|"inspect")
		[ -n "${MOCK_BUSY_VOLUME:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_BUSY_VOLUME"
		exit 0
		;;
esac

# Fall through: a `container run ...`. Find the host staging bind mount.
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

stage_copy() {
	[ -n "$outdir" ] || return 0
	mkdir -p "$outdir/sstate"
	cp -r "$FIXTURE/." "$outdir/sstate/"
	if [ -n "${MOCK_VERIFY_CORRUPT_ALWAYS:-}" ] || \
	   { [ -n "${MOCK_VERIFY_CORRUPT:-}" ] && [ "$1" = "primary" ]; }; then
		# Flip one byte in the STAGED copy so the real
		# retrieve_verify_local() mackas runs against it disagrees with the
		# source manifest printed below.
		f="$(find "$outdir/sstate" -type f | head -1)"
		[ -n "$f" ] && printf 'X' | dd of="$f" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null
	fi
	return 0
}

# Order matters: the primary copy string embeds BOTH the stage list and the
# verify script, so the more specific marker has to be tested first.
last="${@: -1}"
case "$last" in
	*".mackas-verify-jobs"*)
		stage_copy primary
		# The "source" manifest: the real retrieve_verify_local(), extracted
		# from the real mackas and run against the fixture that was just
		# copied FROM.
		eval "$(awk '/^retrieve_verify_local\(\) \{/,/^}/' "$REAL_MACKAS")"
		retrieve_verify_local "$FIXTURE"
		exit 0
		;;
	*".mackas-stage-list"*)
		# The retry after a verification mismatch: the same tar-from-a-list
		# copy, with no manifest of its own.
		stage_copy retry
		exit 0
		;;
	*"-printf"*)
		# The newer-than-the-stamp probe: "<kb><TAB><n> objects".
		printf '%s\t%s objects\n' "${MOCK_NEWER_KB:-64}" "${MOCK_NEWER_COUNT:-2}"
		exit 0
		;;
	*"du -sk"*)
		printf '%s\t/sstate\n' "${MOCK_DU_KB:-4096}"
		exit 0
		;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"

	cat > "$TESTDIR/fakebin/rsync" <<'EOF'
#!/usr/bin/env bash
{
	printf 'RSYNC:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$RLOG"
if [ -n "${MOCK_RSYNC_FAIL:-}" ]; then
	echo "rsync: connection unexpectedly closed" >&2
	exit 12
fi
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/rsync"

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

push() {
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" -y sstate push "$@"
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

assert_rsync() {
	if ! grep -qF -- "$1" "$RLOG" 2>/dev/null; then
		printf 'expected an `rsync` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$RLOG" 2>/dev/null)" >&2
		return 1
	fi
}

refute_rsync() {
	if grep -qF -- "$1" "$RLOG" 2>/dev/null; then
		printf 'expected NO `rsync` call containing:\n  %s\n--- calls ---\n%s\n' \
			"$1" "$(cat "$RLOG" 2>/dev/null)" >&2
		return 1
	fi
}

rsync_calls() {
	local n
	n="$(grep -c '^RSYNC:' "$RLOG" 2>/dev/null || true)"
	printf '%s\n' "${n:-0}"
}

# The stamp's name is a sanitized volume+destination slug plus a cksum, so
# tests find it rather than hardcode it.
stamp_file() {
	find "$ROOT/state/sstate-push" -name '*.stamp' 2>/dev/null | head -1
}

# One successful push, then a clean slate. A first push has no stamp, so it
# stages the WHOLE volume (cp -r, du -sk); everything about the incremental
# path only exists once a stamp does.
seed_stamp() {
	push
	[ "$status" -eq 0 ]
	[ -n "$(stamp_file)" ]
	: > "$CLOG"
	: > "$RLOG"
}

# ---------------------------------------------------------------------------
# Destination handling
# ---------------------------------------------------------------------------

@test "sstate push: refuses with no destination configured" {
	mk -y sstate push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a destination'
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: refuses a destination that is not a remote rsync target" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=/srv/mackas/sstate" -y sstate push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'remote rsync target'
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: --dest overrides the configured destination" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=mirror@wrong.invalid:/wrong" -y \
		sstate push --dest "$DEST"
	[ "$status" -eq 0 ]
	assert_rsync "[$DEST]"
	refute_rsync "[mirror@wrong.invalid:/wrong]"
}

@test "sstate push: an unknown option is refused" {
	push --bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown option'
	[ "$(rsync_calls)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# One-VM rule
# ---------------------------------------------------------------------------

@test "sstate push: refuses when a running container holds the sstate volume" {
	MOCK_BUSY_VOLUME="oe-build-sstate" push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_call "oe-build-sstate:/sstate"
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: a container holding a DIFFERENT volume does not block it" {
	MOCK_BUSY_VOLUME="some-other-volume" push
	[ "$status" -eq 0 ]
	assert_call "oe-build-sstate:/sstate:ro"
}

@test "sstate push: the volume is mounted READ-ONLY for staging" {
	push
	[ "$status" -eq 0 ]
	assert_call "[-v] [oe-build-sstate:/sstate:ro]"
	refute_call "[-v] [oe-build-sstate:/sstate]"
}

# ---------------------------------------------------------------------------
# The stamp
# ---------------------------------------------------------------------------

@test "sstate push: a successful push writes a stamp" {
	push
	[ "$status" -eq 0 ]
	[ -n "$(stamp_file)" ]
	run cat "$(stamp_file)"
	printf '%s\n' "$output" | grep -qE '^[0-9]+$'
}

@test "sstate push: an existing stamp becomes find's -newermt cutoff" {
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	push
	[ "$status" -eq 0 ]
	assert_call "-newermt @1700000000"
}

@test "sstate push: --full ignores the stamp and offers everything again" {
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	push --full
	[ "$status" -eq 0 ]
	refute_call "-newermt"
	assert_call "du -sk"
}

@test "sstate push: an unreadable stamp rescans everything instead of guessing" {
	seed_stamp
	printf 'not-an-epoch\n' > "$(stamp_file)"
	push
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'unreadable push stamp'
	refute_call "-newermt"
}

@test "sstate push: a failed rsync leaves the stamp untouched" {
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_RSYNC_FAIL=1 push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'rsync failed'
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: nothing new stamps and transfers nothing" {
	seed_stamp
	MOCK_NEWER_COUNT=0 push
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to push'
	[ "$(rsync_calls)" -eq 0 ]
	[ -n "$(stamp_file)" ]
}

# ---------------------------------------------------------------------------
# The transfer itself
# ---------------------------------------------------------------------------

@test "sstate push: transfers in two passes, siginfo second" {
	push
	[ "$status" -eq 0 ]
	[ "$(rsync_calls)" -eq 2 ]
	sed -n '1p' "$RLOG" > "$TESTDIR/pass1"
	sed -n '2p' "$RLOG" > "$TESTDIR/pass2"
	# Pass 1 carries every object EXCEPT the signatures...
	grep -qF -- '[--exclude=*.siginfo]' "$TESTDIR/pass1"
	assert_fails grep -qF -- '[--include=*.siginfo]' "$TESTDIR/pass1"
	# ...and only pass 2 carries them, recursing through the directories.
	grep -qF -- '[--include=*.siginfo]' "$TESTDIR/pass2"
	grep -qF -- '[--include=*/]' "$TESTDIR/pass2"
	grep -qF -- '[--exclude=*]' "$TESTDIR/pass2"
}

@test "sstate push: neither pass publishes ext4's lost+found" {
	# A stampless (full) push stages the whole volume, lost+found included,
	# and pass 2's --include='*/' would otherwise recreate it on the mirror.
	push
	[ "$status" -eq 0 ]
	[ "$(grep -c -- "\[--exclude=lost+found\]" "$RLOG")" -eq 2 ]
	sed -n '2p' "$RLOG" > "$TESTDIR/pass2"
	# First filter rule wins in rsync, so the exclude has to come first.
	grep -qE '\[--exclude=lost\+found\].*\[--include=\*/\]' "$TESTDIR/pass2"
}

@test "sstate push: every pass is --ignore-existing and never --inplace" {
	push
	[ "$status" -eq 0 ]
	[ "$(grep -c -- '\[--ignore-existing\]' "$RLOG")" -eq 2 ]
	refute_rsync "[--inplace]"
}

@test "sstate push: no rsync invocation in the source carries --inplace" {
	# The prose above it says "NEVER --inplace", so a bare source grep would
	# match its own comment: pin the invocations themselves.
	! grep -n 'run rsync' "$MACKAS" | grep -q -- '--inplace'
}

@test "sstate push: the staged copy, not the volume, is what rsync reads" {
	push
	[ "$status" -eq 0 ]
	assert_rsync "$ROOT/sstate-push/"
	refute_rsync "oe-build-sstate:/sstate"
}

@test "sstate push: MACKAS_SSTATE_PUSH_STAGE relocates the staging directory" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" \
		--set "MACKAS_SSTATE_PUSH_STAGE=$TESTDIR/elsewhere" -y sstate push
	[ "$status" -eq 0 ]
	assert_rsync "$TESTDIR/elsewhere/"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

@test "sstate push: a verification failure aborts before any transfer" {
	MOCK_VERIFY_CORRUPT_ALWAYS=1 push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'still fails verification'
	[ "$(rsync_calls)" -eq 0 ]
	[ -z "$(stamp_file)" ]
}

@test "sstate push: a first-copy mismatch is retried, and a clean retry still pushes" {
	seed_stamp
	MOCK_VERIFY_CORRUPT=1 push
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'failed verification after the staged copy'
	assert_call ".mackas-stage-list"
	[ "$(rsync_calls)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# --dry-run
# ---------------------------------------------------------------------------

@test "sstate push --dry-run leaves an existing stamp alone when there is nothing new" {
	# The nothing-new path stamps and returns before the transfer's own
	# dry-run branch is reached, so this is the one that pins push_stamp_write
	# refusing to write under --dry-run.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_NEWER_COUNT=0 mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" -y --dry-run sstate push
	[ "$status" -eq 0 ]
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push --dry-run transfers nothing and stamps nothing" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" -y --dry-run sstate push
	[ "$status" -eq 0 ]
	[ "$(rsync_calls)" -eq 0 ]
	[ -z "$(stamp_file)" ]
	printf '%s\n' "$output" | grep -qi 'dry-run'
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

@test "sstate --help documents push" {
	mk sstate --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'sstate push'
	printf '%s\n' "$output" | grep -qi 'ignore-existing'
	[ "$(rsync_calls)" -eq 0 ]
}
