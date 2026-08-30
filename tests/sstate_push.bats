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
# count and size, and can be told to break in each of the ways that must NOT
# advance the stamp) and the staged copy, which really populates the host
# staging directory from a fixture and prints the "source" manifest by
# extracting retrieve_verify_local() fresh out of the real mackas -- the same
# trick retrieve.bats uses, so an uncorrupted copy verifies and a corrupted one
# does not, without a second manifest implementation to keep in sync. The rsync
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
	MOCK_NO_VOLUME=""
	MOCK_RSYNC_FAIL=""
	MOCK_VERIFY_CORRUPT=""
	MOCK_VERIFY_CORRUPT_ALWAYS=""
	MOCK_PROBE_BREAK=""
	export MOCK_BUSY_VOLUME MOCK_NO_VOLUME MOCK_RSYNC_FAIL
	export MOCK_VERIFY_CORRUPT MOCK_VERIFY_CORRUPT_ALWAYS MOCK_PROBE_BREAK

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
		[ -n "${MOCK_NO_VOLUME:-}" ] || echo "oe-build-sstate named local size=40G"
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
		echo 'COPY:primary' >> "$CLOG"
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
		# copy, with no manifest of its own. Tagged, because the primary
		# copy's own command string carries the identical stage-list marker
		# -- grepping for it cannot tell the two apart, and once did not.
		echo 'COPY:retry' >> "$CLOG"
		stage_copy retry
		exit 0
		;;
	*".mackas-scan"*)
		# The newer-than-the-stamp probe: "<kb><TAB><n> objects", then the
		# marker saying the scan ran all the way through. Each break mode is
		# one of the ways a probe can wrongly look like it found nothing.
		case "${MOCK_PROBE_BREAK:-}" in
			nodir)
				# The `[ -d /sstate ] || exit 1` half: the volume is there,
				# the directory inside it is not.
				exit 1 ;;
			rc)
				echo "find: /sstate: Input/output error" >&2
				exit 9 ;;
			truncated)
				# The nastiest shape: find died after listing nothing, so awk
				# summed nothing and the scan "succeeded" with a perfectly
				# well-formed EMPTY answer -- the one that advances the stamp.
				printf '0\t0 objects\n'
				exit 0 ;;
			garbage)
				printf '%s\tmany objects\n' "${MOCK_NEWER_KB:-64}"
				printf 'MACKAS-SCAN-OK\n'
				exit 0 ;;
		esac
		printf '%s\t%s objects\n' "${MOCK_NEWER_KB:-64}" "${MOCK_NEWER_COUNT:-2}"
		printf 'MACKAS-SCAN-OK\n'
		exit 0
		;;
	*"du -sk"*)
		# The stampless probe. --full and every FIRST push take this branch
		# (no cutoff, so nothing for find to select against) and stamp
		# afterwards exactly as the incremental one does, so it has to prove
		# it finished too. Only the break mode that shape can actually
		# produce is modelled; the rest are indistinguishable here from
		# their incremental counterparts, which is the whole point.
		case "${MOCK_PROBE_BREAK:-}" in
			truncated)
				# A perfectly well-formed size line from a script that never
				# reached its end -- indistinguishable from a real answer
				# unless the marker below is insisted on.
				printf '%s\t/sstate\n' "${MOCK_DU_KB:-4096}"
				exit 0 ;;
		esac
		printf '%s\t/sstate\n' "${MOCK_DU_KB:-4096}"
		printf 'MACKAS-SCAN-OK\n'
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

# $output must not contain LITERAL. A function, never a bare `! ... | grep -q`,
# which set -e does not abort on anywhere but a test's final line.
refute_out() {
	if printf '%s\n' "$output" | grep -qF -- "$1"; then
		printf 'expected this NOT in the output:\n  %s\n--- output ---\n%s\n' \
			"$1" "$output" >&2
		return 1
	fi
}

rsync_calls() {
	local n
	n="$(grep -c '^RSYNC:' "$RLOG" 2>/dev/null || true)"
	printf '%s\n' "${n:-0}"
}

# How many times the mock took its RETRY branch -- the stage-list copy with no
# manifest script appended. The primary copy's command string carries the same
# stage-list marker, so grepping the argv for it cannot tell the two apart,
# which is exactly how the retry once went untested.
retry_calls() {
	local n
	n="$(grep -c '^COPY:retry$' "$CLOG" 2>/dev/null || true)"
	printf '%s\n' "${n:-0}"
}

# The stamp's name is a sanitized volume+destination slug plus a cksum, so
# tests find it rather than hardcode it.
stamp_file() {
	find "$ROOT/state/sstate-push" -name '*.stamp' 2>/dev/null | head -1
}

stamp_count() {
	local n
	n="$(find "$ROOT/state/sstate-push" -name '*.stamp' 2>/dev/null | grep -c . || true)"
	printf '%s\n' "${n:-0}"
}

# Only observable after a push that FAILED: a clean one wipes the stage again.
stage_dir() {
	find "$ROOT/sstate-push" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1
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

@test "sstate push: refuses a destination starting with '-'" {
	# A valid-looking USER@HOST:PATH in every other respect, so only the
	# dedicated leading-'-' refusal can reject it -- rsync would read it as
	# an option, on the one command that reaches another machine.
	mk --set "MACKAS_SSTATE_PUSH_DEST=-oProxyCommand=id:/srv/mackas/sstate" -y sstate push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'may not start with'
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: --dest overrides the configured destination" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=mirror@wrong.invalid:/wrong" -y \
		sstate push --dest "$DEST"
	[ "$status" -eq 0 ]
	assert_rsync "[$DEST]"
	refute_rsync "[mirror@wrong.invalid:/wrong]"
}

@test "sstate push: the --dest=VALUE form overrides it too" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=mirror@wrong.invalid:/wrong" -y \
		sstate push --dest="$DEST"
	[ "$status" -eq 0 ]
	assert_rsync "[$DEST]"
	refute_rsync "[mirror@wrong.invalid:/wrong]"
}

@test "sstate push: an empty --dest= is refused, not silently ignored" {
	# Falling through to the configured destination would publish to the very
	# mirror the user was trying to override.
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" -y sstate push --dest=
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a value'
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: a --dest with no value at all is refused" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" -y sstate push --dest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a value'
	[ "$(rsync_calls)" -eq 0 ]
}

@test "sstate push: an unknown option is refused" {
	push --bogus
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown option'
	[ "$(rsync_calls)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Both push settings go through validate_settings
#
# Registering a setting is a four-place edit, and SETTINGS_INTERPOLATED is the
# place that is easy to miss: MACKAS_SSTATE_PUSH_STAGE becomes the HOST side
# of `-v <stage>:/out` and MACKAS_SSTATE_PUSH_DEST becomes rsync's target, so
# an unchecked value reaches an argv either way (invariant 5). Nothing else in
# the suite exercises those two registrations -- delete the two lines and
# every other test stays green while the refusal silently disappears.
# ---------------------------------------------------------------------------

@test "sstate push: a hostile MACKAS_SSTATE_PUSH_STAGE is refused before anything is attached" {
	mk --set "MACKAS_SSTATE_PUSH_DEST=$DEST" \
		--set 'MACKAS_SSTATE_PUSH_STAGE=/tmp/stage`id`' -y sstate push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_SSTATE_PUSH_STAGE'
	printf '%s\n' "$output" | grep -q 'next:'
	refute_call "oe-build-sstate:/sstate"
	[ "$(rsync_calls)" -eq 0 ]
	[ -z "$(stamp_file)" ]
}

@test "sstate push: a hostile MACKAS_SSTATE_PUSH_DEST is refused before anything is attached" {
	mk --set 'MACKAS_SSTATE_PUSH_DEST=mirror@example.invalid:/srv/"; id; "' \
		-y sstate push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_SSTATE_PUSH_DEST'
	printf '%s\n' "$output" | grep -q 'next:'
	refute_call "oe-build-sstate:/sstate"
	[ "$(rsync_calls)" -eq 0 ]
	[ -z "$(stamp_file)" ]
}

@test "sstate push: no rsync on PATH is refused before anything is attached" {
	# `command -v rsync` can only be exercised by a PATH that genuinely has
	# no rsync anywhere on it, so mirror every entry of the current one into
	# a single directory and drop just that link.
	local nors="$TESTDIR/norsync" p
	mkdir -p "$nors"
	( IFS=:
	  for p in $PATH; do
		[ -d "$p" ] || continue
		ln -sf "$p"/* "$nors/" 2>/dev/null || true
	  done )
	rm -f "$nors/rsync"
	PATH="$nors" push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'rsync is not on PATH'
	refute_call "oe-build-sstate:/sstate"
	[ -z "$(stamp_file)" ]
}

# ---------------------------------------------------------------------------
# One-VM rule, and the volume existing at all
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

@test "sstate push: a volume that does not exist is refused, and never stamped" {
	# An absent named volume bind-mounts as an EMPTY one, which scans as
	# "nothing newer" -- the one answer that advances the stamp. So it has to
	# be refused before the probe attaches anything, exactly as retrieve
	# refuses it.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_NO_VOLUME=1 push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not exist yet'
	refute_call "oe-build-sstate:/sstate"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
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

@test "sstate push: the stamp records when the scan started, not a later time" {
	# An object written DURING a push has to be re-offered by the next one,
	# so the stamp may never run ahead of the scan that produced it.
	local before after stamped
	before="$(date +%s)"
	push
	[ "$status" -eq 0 ]
	after="$(date +%s)"
	stamped="$(cat "$(stamp_file)")"
	[ "$stamped" -ge "$before" ]
	[ "$stamped" -le "$after" ]
}

@test "sstate push: 'now' is read before the scan, not after it" {
	# The wall-clock bound above catches a skewed stamp but cannot see the
	# ORDER of two statements a fraction of a second apart -- pin that in the
	# source, the way AGENTS.md asks for logic bats cannot reach.
	local body now_ln scan_ln
	body="$(awk '/^sstate_push\(\) \{/,/^}/' "$MACKAS")"
	now_ln="$(printf '%s\n' "$body" | grep -n 'now="\$(date +%s)"' | head -1 | cut -d: -f1)"
	scan_ln="$(printf '%s\n' "$body" | grep -nF 'fetch_volume_subdir "$MACKAS_VOL_SSTATE"' | head -1 | cut -d: -f1)"
	[ -n "$now_ln" ]
	[ -n "$scan_ln" ]
	[ "$now_ln" -lt "$scan_ln" ]
}

@test "sstate push: destinations that sanitize alike still get separate stamps" {
	# These two slug to the identical string -- every '@', ':' and '/'
	# becomes '_' -- so only the cksum half of the key keeps them apart. One
	# shared stamp would silently skip objects the OTHER mirror never got.
	mk --set "MACKAS_SSTATE_PUSH_DEST=mirror@example.invalid:/srv/mackas/sstate" \
		-y sstate push
	[ "$status" -eq 0 ]
	mk --set "MACKAS_SSTATE_PUSH_DEST=mirror@example.invalid:/srv:mackas:sstate" \
		-y sstate push
	[ "$status" -eq 0 ]
	[ "$(stamp_count)" -eq 2 ]
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

@test "sstate push: nothing new ADVANCES the stamp and transfers nothing" {
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_NEWER_COUNT=0 push
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to push'
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	printf '%s\n' "$output" | grep -qE '^[0-9]+$'
	[ "$output" -gt 1700000000 ]
}

# ---------------------------------------------------------------------------
# A probe that could not answer must never read as "nothing new"
#
# "the scan matched nothing" is the ONE outcome that moves the stamp forward.
# If a broken scan is indistinguishable from it, every object that really
# existed drops below the cutoff permanently and is never offered to the
# mirror again -- the exact opposite of what the stamp is for.
#
# The rule has to hold on all three entry conditions, not just the
# incremental one: --full and a first push (no stamp yet) skip the cutoff
# entirely and take the `du` probe instead, and they stamp just the same.
# ---------------------------------------------------------------------------

@test "sstate push: a FIRST push whose probe never finished does not stamp" {
	# No stamp yet, so no cutoff, so the `du` probe -- the path a new user
	# hits before any other. It reported a perfectly well-formed size and
	# exited clean without reaching its end; stamping here would put every
	# object that already existed below the next push's cutoff forever.
	[ -z "$(stamp_file)" ]
	MOCK_PROBE_BREAK=truncated push
	[ "$status" -ne 0 ]
	assert_call "du -sk"
	[ "$(rsync_calls)" -eq 0 ]
	[ -z "$(stamp_file)" ]
}

@test "sstate push --full does not stamp when the probe never finished" {
	# Same probe as the first push above, but with a stamp already on disk:
	# this is where the damage is visible, since --full is exactly what a
	# user reaches for after a suspect push.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_PROBE_BREAK=truncated push --full
	[ "$status" -ne 0 ]
	refute_call "-newermt"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: a well-formed EMPTY answer from a scan that never finished does not stamp" {
	# find died having listed nothing, awk faithfully summed nothing, and the
	# result is indistinguishable from a genuine "nothing new" -- unless the
	# scan has to prove it ran to the end.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_PROBE_BREAK=truncated push
	[ "$status" -ne 0 ]
	refute_out "Nothing to push"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: a probe that fails outright does not stamp, and says the scan broke" {
	# fetch_volume_subdir's 3: the probe ran and could not answer. The
	# message has to be the "could not scan" one, never the "no such
	# directory" one -- see the pair below for why the two are kept apart.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_PROBE_BREAK=rc push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "could not scan 'oe-build-sstate' for sstate"
	refute_out "no /sstate in"
	refute_out "Nothing to push"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: an absent directory is reported as absent, not as a broken scan" {
	# The other half of the 1-vs-3 split: `[ -d /sstate ] || exit 1` inside a
	# volume that DOES exist. Both refusals leave the stamp alone, so exit
	# status alone cannot tell them apart -- only the message can, and the
	# whole reason the two codes are kept distinct is that they are different
	# problems with different fixes.
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_PROBE_BREAK=nodir push
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "no /sstate in 'oe-build-sstate'"
	refute_out "could not scan"
	refute_out "Nothing to push"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: an unparseable object count does not stamp" {
	seed_stamp
	printf '1700000000\n' > "$(stamp_file)"
	MOCK_PROBE_BREAK=garbage push
	[ "$status" -ne 0 ]
	refute_out "Nothing to push"
	[ "$(rsync_calls)" -eq 0 ]
	run cat "$(stamp_file)"
	[ "$output" = "1700000000" ]
}

@test "sstate push: the epoch predicate reaches BOTH find passes of the manifest" {
	# retrieve_verify_script splits into a chunked large-file find and a
	# batched small-file find (issue #94). The staged copy took only the
	# subset, so a manifest half that walked the WHOLE volume could never
	# match it -- and nothing hermetic can run that guest-side script (BSD
	# find has no -printf), so pin it in the source.
	local body
	body="$(awk '/^retrieve_verify_script\(\) \{/,/^}/' "$MACKAS")"
	[ "$(printf '%s\n' "$body" | grep -c 'find \. -type f' || true)" -eq 2 ]
	[ "$(printf '%s\n' "$body" | grep -c 'find \. -type f \$newer' || true)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# The guest probe strings themselves.
#
# Nothing hermetic can run them: they execute inside the container, under the
# guest's dash, and BSD find has no -printf. So every guard in them is pinned
# by source-grep (AGENTS.md's rule for logic bats cannot reach) -- one grep
# per guard, each naming its own clause. A single
# `grep -F '.mackas-scan || exit'` once stood in for all of them, and the
# probe has TWO clauses ending that way, so deleting either left it green.
# ---------------------------------------------------------------------------

# The incremental (find) probe, straight out of the source. Exactly one line
# must match, so a second scan shape cannot hide behind a `head -1`.
scan_probe() {
	local lines
	lines="$(grep -F 'probe_cmd=' "$MACKAS" | grep -F '/tmp/.mackas-scan')"
	if [ "$(printf '%s\n' "$lines" | grep -c . || true)" -ne 1 ]; then
		printf 'expected exactly one scan probe_cmd= line, got:\n%s\n' "$lines" >&2
		return 1
	fi
	printf '%s\n' "$lines"
}

# The stampless (du) probe --full and every first push take.
size_probe() {
	local lines
	lines="$(grep -F 'probe_cmd=' "$MACKAS" | grep -F 'du -sk $q_guest')"
	if [ "$(printf '%s\n' "$lines" | grep -c . || true)" -ne 1 ]; then
		printf 'expected exactly one du probe_cmd= line, got:\n%s\n' "$lines" >&2
		return 1
	fi
	printf '%s\n' "$lines"
}

# COUNT occurrences of a fixed string in a probe -- `grep -c` counts matching
# LINES, and a probe is one line, so it reads 1 for a clause present twice.
# Insisting on exactly one occurrence is what makes each pin unambiguous.
probe_has_once() {
	local pat="$1" probe="$2" n
	n="$(printf '%s\n' "$probe" | grep -oF -- "$pat" | grep -c . || true)"
	if [ "${n:-0}" -ne 1 ]; then
		printf 'expected exactly 1 occurrence of:\n  %s\n--- got %s, in ---\n%s\n' \
			"$pat" "${n:-0}" "$probe" >&2
		return 1
	fi
}

# A probe's final clause: everything after the last `; `, minus the `"` that
# closes the shell assignment. `.*; ` is greedy, so the `;` inside awk's own
# program does not split it early.
probe_last_clause() {
	printf '%s\n' "$1" | sed 's/.*; //; s/"$//'
}

@test "sstate push: the scan probe tests the directory itself, with the reserved status 1" {
	# 1 is fetch_volume_subdir's "not there" answer and nothing else's: the
	# caller prints a different message and a different fix for it. Every
	# other guard in this probe must therefore avoid 1.
	probe_has_once '[ -d $q_guest ] || exit 1;' "$(scan_probe)"
}

@test "sstate push: the scan probe checks its own cd" {
	# find runs on `.`, so a cd that silently failed would scan the image's
	# root instead of the sstate dir -- plausible output, wrong volume.
	probe_has_once 'cd $q_guest || exit 8;' "$(scan_probe)"
}

@test "sstate push: the scan probe checks find's own exit status" {
	# The headline invariant. The guest sh has no pipefail and find alone
	# decides what is newer than the stamp, so a find that dies mid-walk
	# otherwise reads as an EMPTY result -- the one answer that advances the
	# stamp and drops those objects from the mirror for good. Pinned on
	# find's own redirect, not on the shared filename, which awk's clause
	# carries too.
	probe_has_once '> /tmp/.mackas-scan || exit 9;' "$(scan_probe)"
}

@test "sstate push: the scan probe checks awk's own exit status" {
	# awk is what turns the scan into the "<kb><TAB><n> objects" line the
	# caller parses; if it dies the caller gets no count at all. Pinned on
	# the clause that closes awk's program, so find's redirect to the same
	# file cannot satisfy it.
	probe_has_once "}' /tmp/.mackas-scan || exit 10" "$(scan_probe)"
}

@test "sstate push: the scan probe prints its completion marker last, and never exits 0" {
	# The marker is the caller's proof the script reached its end (rc=11
	# otherwise), so it has to be the LAST clause -- printed only once awk
	# has also finished -- and a trailing `exit 0` would hand back success
	# from anywhere. Anchored on the clause itself, never on the `exit 10`
	# in front of it, so removing awk's guard fails only awk's own test.
	local probe
	probe="$(scan_probe)"
	[ "$(probe_last_clause "$probe")" = "printf 'MACKAS-SCAN-OK\\\\n'" ]
	assert_fails grep -qF '; exit 0' <<< "$probe"
}

@test "sstate push: the scan probe runs no pipeline" {
	# Why find's status is checkable at all: the guest sh is dash, which has
	# no pipefail, so `find | awk` would report awk's status and a dead find
	# would look like an empty scan. find writes a file, awk reads it back.
	# `||` is not a pipeline.
	# Extracted first, THEN stripped: `scan_probe | sed` would swallow a
	# failed extraction into an empty string and pass on nothing at all.
	local probe stripped
	probe="$(scan_probe)"
	stripped="$(printf '%s\n' "$probe" | sed 's/||/@@/g')"
	assert_fails grep -qF '|' <<< "$stripped"
}

@test "sstate push: the stampless probe tests the directory too, with the same status 1" {
	# --full and every first push take this shape, and a new user hits it
	# first, so the 1-vs-3 split has to hold here as well.
	probe_has_once '[ -d $q_guest ] || exit 1;' "$(size_probe)"
}

@test "sstate push: the stampless probe marks completion after the measurement" {
	# Nothing here can truncate a scan, but it stamps exactly as the
	# incremental path does, so it proves it finished the same way: the
	# marker AFTER du, never instead of it, and never a trailing `exit 0`.
	# du itself stays unguarded on purpose -- its failure loses only the
	# size, and printf still marks the probe complete.
	local probe
	probe="$(size_probe)"
	probe_has_once 'du -sk $q_guest 2>/dev/null;' "$probe"
	[ "$(probe_last_clause "$probe")" = "printf 'MACKAS-SCAN-OK\\\\n'" ]
	assert_fails grep -qF '; exit 0' <<< "$probe"
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
	# match its own comment: pin the invocations themselves. Push's own two
	# passes are asserted to BE in that set first, because an absence check
	# over a grep that matched nothing passes forever -- respelling the call
	# site would otherwise retire this test silently.
	local calls
	calls="$(grep -n 'run rsync' "$MACKAS")"
	[ "$(printf '%s\n' "$calls" | grep -c -- '--ignore-existing')" -eq 2 ]
	assert_fails grep -q -- '--inplace' <<< "$calls"
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

@test "sstate push: the staging tree is wiped before it is refilled" {
	# It holds a second copy of every new object, so anything left behind by
	# a previous push would be re-published and would quietly grow. Only a
	# FAILED push leaves the stage in place to observe.
	local stage
	MOCK_RSYNC_FAIL=1 push
	[ "$status" -ne 0 ]
	stage="$(stage_dir)"
	[ -n "$stage" ]
	touch "$stage/left-over-from-a-previous-push"
	MOCK_RSYNC_FAIL=1 push
	[ "$status" -ne 0 ]
	[ "$stage" = "$(stage_dir)" ]
	[ ! -e "$stage/left-over-from-a-previous-push" ]
	[ -d "$stage/sstate" ]
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
	# Exactly one retry: a copy carrying the stage list but NOT the manifest
	# script, the only thing that distinguishes it from the primary copy.
	[ "$(retry_calls)" -eq 1 ]
	# ...and the incremental path stages with tar-from-a-list throughout,
	# because cp -r has no subset form.
	refute_call "cp -r"
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
	# push's OWN dry-run line: a bare 'dry-run' match is already satisfied by
	# fetch_volume_subdir's staging message and pins nothing here.
	printf '%s\n' "$output" | grep -qF 'nothing was transferred and the push stamp is unchanged'
	refute_out "pushed 'oe-build-sstate'"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

@test "sstate --help documents push" {
	mk sstate --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'sstate push [--dest USER@HOST:/PATH] [--full]'
	# The sentence that documents the transport, not merely the word: the
	# heredoc says "--ignore-existing" twice, so a loose match stays green
	# with the transport paragraph deleted.
	printf '%s\n' "$output" | grep -qF 'sent with --ignore-existing and never --inplace'
	[ "$(rsync_calls)" -eq 0 ]
}
