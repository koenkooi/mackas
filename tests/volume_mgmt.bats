#!/usr/bin/env bats
#
# Tests for `mackas volume` -- list, fstrim (reclaim sparse-image space),
# duplicate, destroy, move, resize (grow in place) and recover an arbitrary
# ext4 container volume.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas volume ...` as a subprocess with a fake `container` on
# PATH that records every call AND models the pieces that matter here:
#
#   * `volume ls`      -- header + one row per known volume, with size=<cap> in
#                         the OPTIONS column (real container 1.1.0 format).
#   * `volume inspect` -- JSON carrying the configured "size", so `duplicate`
#                         can read the source's size.
#   * `volume create`  -- registers the volume AND makes its on-disk dir +
#                         volume.img, the way the real runtime does.
#   * `volume delete`  -- deregisters it and removes the dir.
#   * `run ... fstrim` -- records its argv and SHRINKS the volume.img (the way
#                         a real DISCARD->hole-punch does), then prints a bogus
#                         "N bytes trimmed" line that does NOT match the du
#                         delta -- so a test can prove the reported reclaim
#                         comes from re-measuring du, not from fstrim's output.
#   * `ls` / `inspect` -- running-container queries for the one-VM busy check.
#
# Nothing here touches the real Apple container runtime, a real volume, or the
# build SSD. The fakes are the only engine present.

bats_require_minimum_version 1.5.0

load helpers

# The path mackas derives for a volume's backing image, under the fake HOME.
VOLDIR() { printf '%s/Library/Application Support/com.apple.container/volumes' "$HOME"; }

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	CLOG="$TESTDIR/container.log"
	export CLOG

	# name<TAB>size, one per line: the volumes the fake engine knows about.
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"

	# How many KiB the fstrim mock shrinks a volume.img to (models the reclaim).
	MOCK_FSTRIM_AFTER_KB=2048
	export MOCK_FSTRIM_AFTER_KB

	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"

voldir="$HOME/Library/Application Support/com.apple.container/volumes"

case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"system stop") exit 0 ;;
	"system start")
		# Simulate a REAL start: the daemon scans volumes/*/entity.json
		# into its index -- exactly what refuse_if_stale_entity relies on.
		# There is NO 'system restart' subcommand; mackas does stop+start.
		for d in "$voldir"/*/; do
			[ -e "${d}entity.json" ] || continue
			n="$(basename "$d")"
			grep -q -e "^$n	" "$VSTATE" 2>/dev/null || printf '%s\t800M\n' "$n" >> "$VSTATE"
		done
		exit 0
		;;
	"volume ls")
		echo "NAME TYPE DRIVER OPTIONS"
		# name<TAB>size -> `name  named  local  size=<size>`
		while IFS="$(printf '\t')" read -r n s; do
			[ -n "$n" ] || continue
			printf '%s named local size=%s\n' "$n" "$s"
		done < "$VSTATE"
		exit 0
		;;
	"volume inspect")
		# `... volume inspect NAME` -> JSON with the configured size.
		name="$3"
		size="$(awk -F'\t' -v n="$name" '$1==n {print $2; exit}' "$VSTATE")"
		printf '[ { "configuration" : { "options" : { "size" : "%s" } }, "id" : "%s" } ]\n' \
			"$size" "$name"
		exit 0
		;;
	"volume create")
		# `... volume create -s SIZE NAME`
		eval "name=\${$#}"
		size=""
		prev=""
		for a in "$@"; do [ "$prev" = "-s" ] && size="$a"; prev="$a"; done
		printf '%s\t%s\n' "$name" "$size" >> "$VSTATE"
		mkdir -p "$voldir/$name"
		: > "$voldir/$name/entity.json"
		dd if=/dev/zero of="$voldir/$name/volume.img" bs=1024 count=8 2>/dev/null
		exit 0
		;;
	"volume delete"|"volume rm")
		name="$3"
		grep -v -e "^$name	" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		rm -rf "$voldir/$name"
		exit 0
		;;
	"ls "*|"ls")
		# Running containers: one if MOCK_INUSE names a held volume.
		echo "ID"
		[ -n "${MOCK_INUSE:-}" ] && echo "runner1"
		exit 0
		;;
	"inspect "*)
		# `... inspect <container-id>` -> mounts block naming the held volume.
		[ -n "${MOCK_INUSE:-}" ] && printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_INUSE"
		exit 0
		;;
esac

# Fall through: a `container run ... -v HOSTDIR:/vol IMAGE sh -c '...'` --
# 'volume fsck's throwaway container. It NEVER sees the real volume; the
# only `-v` bind it ever gets is the scratch clone directory fsck_guest_script
# creates, so this branch keys off the ':/vol' target specifically (never
# ':/mnt', which is fstrim's own target) and reports the mock's canned
# MACKAS-FSCK: marker lines instead of running a real e2fsck.
is_fsck=0
fsck_hostdir=""
prev=""
for a in "$@"; do
	if [ "$prev" = "-v" ]; then
		case "$a" in *:/vol) is_fsck=1; fsck_hostdir="${a%:/vol}" ;; esac
	fi
	prev="$a"
done
if [ "$is_fsck" -eq 1 ]; then
	last="${@: -1}"
	case "$last" in
		*"exit 10"*) fsck_mode=check ;;
		*)           fsck_mode=repair ;;
	esac
	case "${MOCK_FSCK_STATE:-clean}" in
		apt-fail)
			echo "MACKAS-FSCK: installing e2fsprogs"
			echo "MACKAS-FSCK: error apt-get update failed"
			exit 12
			;;
		unrepairable)
			echo "MACKAS-FSCK: dirty 1"
			[ "$fsck_mode" = check ] && exit 1
			echo "MACKAS-FSCK: repair-exit 8"
			echo "MACKAS-FSCK: unrepairable"
			exit 11
			;;
		dirty-repairable)
			echo "MACKAS-FSCK: dirty 1"
			[ "$fsck_mode" = check ] && exit 1
			echo "MACKAS-FSCK: repair-exit 1"
			# Overwrite the CLONE (never the real volume -- $fsck_hostdir is
			# the scratch dir, structurally never the volume's own dir) with
			# different-but-same-size bytes, so a test can tell "the clone
			# got repaired" apart from "the original, byte for byte".
			if [ -f "$fsck_hostdir/volume.img" ]; then
				sz="$(stat -f %z "$fsck_hostdir/volume.img" 2>/dev/null)"
				if [ -n "$sz" ]; then
					/usr/bin/python3 -c '
import sys
p = sys.argv[1]; sz = int(sys.argv[2])
with open(p, "r+b") as f:
	f.write(b"REPAIRED-BY-MOCK-FSCK")
	f.truncate(sz)
' "$fsck_hostdir/volume.img" "$sz"
				fi
			fi
			echo "MACKAS-FSCK: repaired"
			exit 0
			;;
		*)
			echo "MACKAS-FSCK: clean"
			exit 0
			;;
	esac
fi

# Fall through: a `container run ... fstrim -v /mnt`. Find the volume from the
# `-v NAME:/mnt` bind, shrink its image, and print a bogus trimmed figure.
is_fstrim=0
for a in "$@"; do [ "$a" = "fstrim" ] && is_fstrim=1; done
if [ "$is_fstrim" -eq 1 ]; then
	if [ -n "${MOCK_FSTRIM_FAIL:-}" ]; then
		echo "fstrim: /mnt: FITRIM ioctl failed: Operation not permitted" >&2
		exit 1
	fi
	name=""
	prev=""
	for a in "$@"; do
		[ "$prev" = "-v" ] && case "$a" in *:/mnt) name="${a%:/mnt}" ;; esac
		prev="$a"
	done
	if [ -n "$name" ] && [ -f "$voldir/$name/volume.img" ]; then
		dd if=/dev/zero of="$voldir/$name/volume.img" bs=1024 \
			count="${MOCK_FSTRIM_AFTER_KB:-2048}" 2>/dev/null
	fi
	if [ -n "${MOCK_FSTRIM_BOOT_NOISE:-}" ]; then
		# Apple container's own boot-progress reporting, verbatim shape: since
		# mackas captures this command's output through $(...) rather than a
		# real TTY, container falls back to one newline-terminated line per
		# step instead of updating a single line in place via \r.
		printf '[0/6] [0s]\n'
		printf '[1/6] Fetching image [0s]\n'
		printf '[2/6] Unpacking image [0s]\n'
		printf '[3/6] Fetching kernel [0s]\n'
		printf '[4/6] Fetching init image [0s]\n'
		printf '[5/6] Unpacking init image [0s]\n'
		printf '[6/6] Starting container [0s]\n'
		printf '[6/6] Starting container [0s]\n'
	fi
	# Deliberately a wild number, unrelated to the du delta: this is guest free
	# space, which is exactly what mackas must NOT report.
	echo "/mnt: 953.7 MiB (999999999 bytes) trimmed"
	exit 0
fi
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

# Register a volume with the fake engine at a given size, and give it an on-disk
# volume.img of KB kilobytes (default 8192 = 8 MiB).
have_volume() {
	local name="$1" size="$2" kb="${3:-8192}"
	printf '%s\t%s\n' "$name" "$size" >> "$VSTATE"
	mkdir -p "$(VOLDIR)/$name"
	: > "$(VOLDIR)/$name/entity.json"
	dd if=/dev/zero of="$(VOLDIR)/$name/volume.img" bs=1024 count="$kb" 2>/dev/null
}

vol() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 volume "$@"
}

# Same knobs, but for the top-level `status` command (not a `volume` subcommand),
# so a test can prove `volume move` persists a location `status` then reports.
mackas_status() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 status
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
# list
# ---------------------------------------------------------------------------

@test "volume list: shows on-disk usage and the in-use marker" {
	have_volume oe-build-tmp 120G 8192          # 8 MiB on disk
	have_volume some-other   10G  4096          # 4 MiB on disk
	MOCK_INUSE=some-other vol list
	[ "$status" -eq 0 ]
	# On-disk cost, re-measured from du of volume.img (not the 120G/10G cap).
	printf '%s\n' "$output" | grep -qE 'oe-build-tmp .* 8\.0M'
	printf '%s\n' "$output" | grep -qE 'some-other .* 4\.0M'
	# The mackas volume is marked; the foreign one is not.
	printf '%s\n' "$output" | grep -qE 'oe-build-tmp +mackas/tmp'
	# In-use marker: some-other is held by the running container, tmp is not.
	printf '%s\n' "$output" | grep -qE 'some-other .* yes'
	printf '%s\n' "$output" | grep -qE 'oe-build-tmp .* no'
}

@test "volume list: reports the configured cap from the OPTIONS column" {
	have_volume oe-build-dl 40G 4096
	vol list
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE 'oe-build-dl .* 40G'
}

# ---------------------------------------------------------------------------
# status -- "on disk" is real usage; near-cap volumes get a reclaim hint
# ---------------------------------------------------------------------------

@test "status: explains that 'on disk' is REAL usage (du, sparse-aware), not the cap" {
	# The recurring question this answers: du -h on macOS already reports
	# actual allocated blocks, not the volume's logical/apparent size -- "on
	# disk" reading the same as "cap" means the host image genuinely filled
	# up (freed ext4 space does not shrink it on its own), not a measurement
	# bug. Say so in the output itself, not just in docs/storage.md.
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'sparse-aware'
	printf '%s\n' "$output" | grep -qF 'volume fstrim <name>|all'
}

@test "status: a volume near its cap gets a 'reclaim it' hint naming the volume" {
	have_volume oe-build-tmp 8M 8192   # 8 MiB on disk against an 8M cap
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_VOLUME_SIZE_TMP=8M \
		status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'near cap'
	printf '%s\n' "$output" | grep -qF "volume fstrim oe-build-tmp"
}

@test "status: a volume far below its cap gets no hint" {
	have_volume oe-build-tmp 120G 8192   # 8 MiB on disk against the default 120G cap
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF 'near cap'
}

@test "status: a real cap that diverged from the configured size says so, once, without a create-fresh lecture" {
	# ensure_volume() never resizes an existing volume, so a 1T volume under a
	# 120G setting is a permanent, legitimate state (e.g. from a one-shot
	# 'setup --tmpdir-size 1T'). status must explain the divergence in ONE
	# line -- the old second line telling the user to create the volume fresh
	# under a different MACKAS_VOLUME_NAME was removed as noise (live report).
	have_volume oe-build-tmp 1T 8192
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		status
	[ "$status" -eq 0 ]
	# The real cap is what the volume line reports...
	printf '%s\n' "$output" | grep -qE 'oe-build-tmp .* cap 1T'
	# ...the one-line explanation names the configured size...
	printf '%s\n' "$output" | grep -qF 'configured size is 120G, but setup never resizes an existing volume'
	# ...and the create-fresh advice is gone.
	! printf '%s\n' "$output" | grep -qF 'fresh under a different'
}

@test "status: a volume whose real cap matches the configured size gets no divergence line" {
	have_volume oe-build-tmp 120G 8192
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF 'setup never resizes'
}

# ---------------------------------------------------------------------------
# fstrim -- the headline
# ---------------------------------------------------------------------------

@test "volume fstrim: refuses an in-use volume (one-VM rule)" {
	have_volume oe-build-tmp 120G
	MOCK_INUSE=oe-build-tmp vol fstrim oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	# Never attached the volume for an fstrim while it was busy.
	refute_call "[fstrim]"
	refute_call "[oe-build-tmp:/mnt]"
}

@test "volume fstrim: runs fstrim with EXACTLY -u 0:0 --cap-add CAP_SYS_ADMIN" {
	have_volume oe-build-tmp 120G
	vol fstrim oe-build-tmp
	[ "$status" -eq 0 ]
	# Pinned to the whole invocation -- both privileges together, in order, on
	# the right command. Neither -u 0:0 nor --cap-add alone works on a real
	# guest (both give EPERM on the FITRIM ioctl), so both must be present.
	assert_call "[run] [--rm] [-u] [0:0] [--cap-add] [CAP_SYS_ADMIN] [-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim] [-v] [/mnt]"
}

@test "volume fstrim: the exact flags are asserted against the source too" {
	# -u 0:0 and CAP_SYS_ADMIN are literals here (not machine-dependent), but
	# pinning the source form as well guards against the pair drifting apart or
	# landing on the wrong command in a refactor.
	grep -qF -- 'run container run --rm -u 0:0 --cap-add CAP_SYS_ADMIN -v "$name:/mnt" "$KAS_IMAGE" fstrim -v /mnt' "$MACKAS"
	grep -qF -- 'container run --rm -u 0:0 --cap-add CAP_SYS_ADMIN -v "$name:/mnt" "$KAS_IMAGE" fstrim -v /mnt 2>&1' "$MACKAS"
}

@test "volume fstrim: a missing volume errors clearly" {
	vol fstrim no-such-volume
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "volume 'no-such-volume' does not exist"
	refute_call "[fstrim]"
}

@test "volume fstrim: reports before->after from du, NOT from fstrim's output" {
	# 8 MiB on disk; the mock fstrim shrinks it to 2 MiB and prints a wild,
	# unrelated "999999999 bytes trimmed" (guest free space). The reported
	# reclaim must be the du delta (8->2 = 6M), never fstrim's number.
	have_volume oe-build-tmp 120G 8192
	MOCK_FSTRIM_AFTER_KB=2048 vol fstrim oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '8.0M -> 2.0M (reclaimed 6.0M)'
	# fstrim's own figure must not leak into what we report as reclaimed.
	! printf '%s\n' "$output" | grep -q '999999999'
	! printf '%s\n' "$output" | grep -qi 'reclaimed 953'
}

@test "volume fstrim: container's own boot-progress noise is collapsed, not printed verbatim" {
	have_volume oe-build-tmp 120G 8192
	MOCK_FSTRIM_AFTER_KB=2048 MOCK_FSTRIM_BOOT_NOISE=1 vol fstrim oe-build-tmp
	[ "$status" -eq 0 ]
	# None of the eight raw "[N/6] ... [Ts]" boot-progress lines survive.
	! printf '%s\n' "$output" | grep -qE '^\s*fstrim: \[[0-9]+/[0-9]+\]'
	# The real fstrim result line still gets through.
	printf '%s\n' "$output" | grep -qF 'trimmed'
}

@test "volume fstrim: the reclaimed figure is wrapped in \$C_BLD/\$C_RST in the source" {
	grep -qF '${C_BLD}(reclaimed $(fmt_kb "$reclaimed_kb"))${C_RST}"' "$MACKAS"
}

@test "volume fstrim: a device that does not support discard is reported, not claimed" {
	have_volume oe-build-tmp 120G 8192
	MOCK_FSTRIM_FAIL=1 vol fstrim oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'did not succeed'
	printf '%s\n' "$output" | grep -qi 'discard_max_bytes=0'
	# It must NOT claim a reclaim figure (the success line is "... (reclaimed X)").
	! printf '%s\n' "$output" | grep -qF '(reclaimed '
}

@test "volume fstrim: --dry-run runs nothing" {
	have_volume oe-build-tmp 120G 8192
	vol --dry-run fstrim oe-build-tmp
	[ "$status" -eq 0 ]
	# The command is shown but no fstrim was actually run...
	refute_call "[fstrim]"
	# ...and the image is untouched (still 8 MiB, not shrunk).
	[ "$(du -k "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" -eq 8192 ]
}

@test "volume fstrim: all trims the three mackas volumes and skips a busy one" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-dl     40G  8192
	have_volume oe-build-sstate 40G  8192
	MOCK_INUSE=oe-build-tmp vol fstrim all
	# tmp is held, so it is skipped (warned), not attached...
	printf '%s\n' "$output" | grep -qi "oe-build-tmp.*skipping"
	refute_call "[-v] [oe-build-tmp:/mnt]"
	# ...but the other two are trimmed.
	assert_call "[-v] [oe-build-dl:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
	assert_call "[-v] [oe-build-sstate:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
}

@test "volume fstrim: --all is accepted as a synonym for the positional 'all'" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-dl     40G  8192
	have_volume oe-build-sstate 40G  8192
	vol fstrim --all
	[ "$status" -eq 0 ]
	assert_call "[-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
	assert_call "[-v] [oe-build-dl:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
	assert_call "[-v] [oe-build-sstate:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
}

@test "volume fstrim: -a is accepted as a synonym for the positional 'all'" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-dl     40G  8192
	have_volume oe-build-sstate 40G  8192
	vol fstrim -a
	[ "$status" -eq 0 ]
	assert_call "[-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [fstrim]"
}

@test "volume fstrim: --all takes no volume name" {
	vol fstrim --all some-name
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "takes no volume name"
}

# ---------------------------------------------------------------------------
# duplicate
# ---------------------------------------------------------------------------

@test "volume duplicate: creates dst at the source's size and clones volume.img" {
	have_volume src-vol 800M 4096
	vol duplicate src-vol dst-vol
	[ "$status" -eq 0 ]
	# dst created at the SAME size read from `volume inspect`.
	assert_call "[volume] [create] [-s] [800M] [dst-vol]"
	# The clone exists on disk (cp -c swapped volume.img into place).
	[ -f "$(VOLDIR)/dst-vol/volume.img" ]
	# It is a copy of the source's image (same 4 MiB of content), not the empty
	# placeholder `create` made.
	[ "$(du -k "$(VOLDIR)/dst-vol/volume.img" | awk '{print $1}')" -eq 4096 ]
	printf '%s\n' "$output" | grep -qi 'copy-on-write'
}

@test "volume duplicate: the clone is done with cp -c (source-pinned)" {
	grep -qF -- 'run cp -c "$src_img" "$dst_img"' "$MACKAS"
}

@test "volume duplicate: refuses when the source is in use (guard on the SOURCE)" {
	have_volume src-vol 800M
	MOCK_INUSE=src-vol vol duplicate src-vol dst-vol
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_call "[volume] [create]"
	[ ! -e "$(VOLDIR)/dst-vol" ]
}

@test "volume duplicate: refuses when the destination already exists" {
	have_volume src-vol 800M
	have_volume dst-vol 800M
	vol duplicate src-vol dst-vol
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "already exists"
	refute_call "[volume] [create]"
}

@test "volume duplicate: refuses to create dst when the daemon's index is stale (on-disk data it doesn't know about)" {
	have_volume src-vol 800M
	# Simulate a stale container-daemon index: dst's entity.json is on disk
	# (e.g. after relocating CONTAINER_VOLUMES_DIR, or attaching a disk
	# carried over from another Mac) but 'volume ls' does not list it --
	# 'volume create' would otherwise reformat the real volume.img in place
	# BEFORE erroring "entity already exists".
	mkdir -p "$(VOLDIR)/dst-vol"
	: > "$(VOLDIR)/dst-vol/entity.json"
	dd if=/dev/zero of="$(VOLDIR)/dst-vol/volume.img" bs=1024 count=4096 2>/dev/null
	vol duplicate src-vol dst-vol
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "stale"
	refute_call "[volume] [create]"
	# The pre-existing image must survive, byte-for-byte untouched.
	[ "$(du -k "$(VOLDIR)/dst-vol/volume.img" | awk '{print $1}')" -eq 4096 ]
}

@test "volume duplicate: accepting the restart offer refuses as 'already exists', not a silent create" {
	# -y auto-accepts "restart the daemon now?" -- a real restart re-scans
	# entity.json into the index (simulated in the fake container's own
	# 'system restart' handler), so dst is now recognized as existing, and
	# duplicate must refuse exactly the way it already does for a destination
	# the daemon knew about from the start -- not silently overwrite it.
	have_volume src-vol 800M
	mkdir -p "$(VOLDIR)/dst-vol"
	: > "$(VOLDIR)/dst-vol/entity.json"
	dd if=/dev/zero of="$(VOLDIR)/dst-vol/volume.img" bs=1024 count=4096 2>/dev/null
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 volume duplicate src-vol dst-vol
	[ "$status" -ne 0 ]
	assert_call "[system] [start]"
	printf '%s\n' "$output" | grep -qi "already exists"
	refute_call "[volume] [create]"
	[ "$(du -k "$(VOLDIR)/dst-vol/volume.img" | awk '{print $1}')" -eq 4096 ]
}

@test "volume duplicate: --dry-run mutates nothing" {
	have_volume src-vol 800M 4096
	vol --dry-run duplicate src-vol dst-vol
	[ "$status" -eq 0 ]
	refute_call "[volume] [create]"
	[ ! -e "$(VOLDIR)/dst-vol" ]
}

# ---------------------------------------------------------------------------
# destroy -- one arbitrary volume (distinct from the top-level `destroy`)
# ---------------------------------------------------------------------------

@test "volume destroy: removes one volume after confirmation" {
	have_volume clone-1 800M 4096
	vol -y destroy clone-1
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [clone-1]"
	[ ! -e "$(VOLDIR)/clone-1" ]
}

@test "volume destroy: refuses an in-use volume" {
	have_volume oe-build-tmp 120G
	MOCK_INUSE=oe-build-tmp vol -y destroy oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	refute_call "[volume] [delete] [oe-build-tmp]"
}

@test "volume destroy: a missing volume errors clearly" {
	vol -y destroy no-such-volume
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "does not exist"
}

@test "volume destroy --all: removes all four mackas volumes" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-dl     40G  8192
	have_volume oe-build-sstate 40G  8192
	have_volume oe-build        1G   4096   # the legacy pre-split volume
	vol -y destroy --all
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-tmp]"
	assert_call "[volume] [delete] [oe-build-dl]"
	assert_call "[volume] [delete] [oe-build-sstate]"
	assert_call "[volume] [delete] [oe-build]"
	[ ! -e "$(VOLDIR)/oe-build-tmp" ]
	[ ! -e "$(VOLDIR)/oe-build" ]
}

@test "volume destroy -a: same as --all" {
	have_volume oe-build-tmp 120G 8192
	vol -y destroy -a
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-tmp]"
}

@test "volume destroy all: bare positional works too, matching fstrim's precedent" {
	have_volume oe-build-tmp 120G 8192
	vol -y destroy all
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-tmp]"
}

@test "volume destroy --all: silently skips a volume that does not exist, warns and skips one that is in use" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-sstate 40G  8192
	# oe-build-dl and oe-build (legacy) were never created -- silently absent.
	MOCK_INUSE=oe-build-tmp vol -y destroy --all
	[ "$status" -ne 0 ]   # a busy volume survives, so the run is non-zero
	printf '%s\n' "$output" | grep -qi "oe-build-tmp.*skipping"
	refute_call "[volume] [delete] [oe-build-tmp]"
	assert_call "[volume] [delete] [oe-build-sstate]"
	refute_call "[volume] [delete] [oe-build-dl]"
	refute_call "[volume] [delete] [oe-build]"
}

@test "volume destroy --all <name>: refused (takes no volume name)" {
	vol -y destroy --all some-name
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "takes no volume name"
	refute_call "[volume] [delete]"
}

@test "volume destroy --all --dry-run: removes nothing" {
	have_volume oe-build-tmp 120G 8192
	vol --dry-run -y destroy --all
	[ "$status" -eq 0 ]
	refute_call "[volume] [delete]"
	[ -e "$(VOLDIR)/oe-build-tmp" ]
}

@test "volume destroy --all -f: force is accepted as a synonym for -y" {
	have_volume oe-build-tmp 120G 8192
	vol -f destroy --all
	[ "$status" -eq 0 ]
	assert_call "[volume] [delete] [oe-build-tmp]"
}

@test "volume destroy --all: a quiet no-op when nothing exists yet" {
	vol -y destroy --all
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "nothing to destroy"
	refute_call "[volume] [delete]"
}

# ---------------------------------------------------------------------------
# move -- relocate one volume's image tree to another disk (symlink behind)
# ---------------------------------------------------------------------------

@test "volume move: refuses an in-use volume (one-VM rule)" {
	have_volume oe-build-tmp 120G
	MOCK_INUSE=oe-build-tmp vol move oe-build-tmp "$TESTDIR/elsewhere"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	# Nothing was moved: the volume dir is still a real dir where it started,
	# and no symlink or destination was created.
	[ -d "$(VOLDIR)/oe-build-tmp" ] && [ ! -L "$(VOLDIR)/oe-build-tmp" ]
	[ ! -e "$TESTDIR/elsewhere" ]
}

@test "volume move: a missing volume errors clearly" {
	vol move no-such-volume "$TESTDIR/elsewhere"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "volume 'no-such-volume' does not exist"
	[ ! -e "$TESTDIR/elsewhere" ]
}

@test "volume move: moves the dir and plants a symlink to the EXACT new home" {
	have_volume oe-build-tmp 120G 4096
	vol move oe-build-tmp "$TESTDIR/relocated"
	[ "$status" -eq 0 ]
	# The runtime location is now a symlink whose target is EXACTLY <dir>/<name>.
	[ -L "$(VOLDIR)/oe-build-tmp" ]
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$TESTDIR/relocated/oe-build-tmp" ]
	# The symlink was planted atomically (ln to a temp name, then mv into place):
	# no leftover .tmp.<pid> symlink is left behind.
	[ -z "$(ls "$(VOLDIR)"/oe-build-tmp.tmp.* 2>/dev/null)" ]
	# The image tree really moved: volume.img (and entity.json) are at the target.
	[ -f "$TESTDIR/relocated/oe-build-tmp/volume.img" ]
	[ -f "$TESTDIR/relocated/oe-build-tmp/entity.json" ]
	# The image is intact through the symlink (still 4 MiB).
	[ "$(du -k "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" -eq 4096 ]
}

@test "volume move: persists the location so 'status' reports it" {
	have_volume oe-build-tmp 120G 4096
	vol move oe-build-tmp "$TESTDIR/relocated"
	[ "$status" -eq 0 ]
	# No separate state file: the symlink IS the record, and status reads it back.
	mackas_status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "moved to: $TESTDIR/relocated/oe-build-tmp"
}

@test "volume move: --dry-run mutates nothing" {
	have_volume oe-build-tmp 120G 4096
	vol --dry-run move oe-build-tmp "$TESTDIR/relocated"
	[ "$status" -eq 0 ]
	# Still a real dir at the original location; no symlink, no destination.
	[ -d "$(VOLDIR)/oe-build-tmp" ] && [ ! -L "$(VOLDIR)/oe-build-tmp" ]
	[ -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
	[ ! -e "$TESTDIR/relocated/oe-build-tmp" ]
}

@test "volume move: a second move (already-symlinked source) re-targets cleanly" {
	have_volume oe-build-tmp 120G 4096
	vol move oe-build-tmp "$TESTDIR/first"
	[ "$status" -eq 0 ]
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$TESTDIR/first/oe-build-tmp" ]
	# Move it AGAIN, now that the source is a symlink from the first move.
	vol move oe-build-tmp "$TESTDIR/second"
	[ "$status" -eq 0 ]
	# Symlink now points at the second home; the first home is emptied out.
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$TESTDIR/second/oe-build-tmp" ]
	[ -f "$TESTDIR/second/oe-build-tmp/volume.img" ]
	[ ! -e "$TESTDIR/first/oe-build-tmp" ]
}

@test "volume move: refuses a non-empty existing destination" {
	have_volume oe-build-tmp 120G 4096
	mkdir -p "$TESTDIR/taken/oe-build-tmp"
	: > "$TESTDIR/taken/oe-build-tmp/something"
	vol move oe-build-tmp "$TESTDIR/taken"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'already exists'
	# Untouched: still a real dir at the runtime location.
	[ -d "$(VOLDIR)/oe-build-tmp" ] && [ ! -L "$(VOLDIR)/oe-build-tmp" ]
}

@test "volume move: a moved volume can be moved back home" {
	have_volume oe-build-tmp 120G 4096
	vol move oe-build-tmp "$TESTDIR/away"
	[ "$status" -eq 0 ]
	[ -L "$(VOLDIR)/oe-build-tmp" ]
	# Move it back to the runtime volumes dir: the inverse of a move-away.
	vol move oe-build-tmp "$(VOLDIR)"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'back home'
	# A real directory again -- NOT a symlink -- with the image intact.
	[ -d "$(VOLDIR)/oe-build-tmp" ] && [ ! -L "$(VOLDIR)/oe-build-tmp" ]
	[ -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
	[ -f "$(VOLDIR)/oe-build-tmp/entity.json" ]
	# The away location is emptied out.
	[ ! -e "$TESTDIR/away/oe-build-tmp" ]
	# The engine still lists it (moving never deregistered the volume).
	vol list
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF oe-build-tmp
}

@test "volume_img_kb: a failing du degrades to empty, not a set -e abort (source-grep)" {
	# `du` failing on an EXISTING image is hard to force portably, so pin the
	# guard by source: the du pipeline must end in `|| true`, or a failure under
	# set -e+pipefail would kill `volume list` mid-listing.
	local body
	body="$(awk '/^volume_img_kb\(\)/{f=1} f{print} f&&/^}/{exit}' "$MACKAS")"
	printf '%s\n' "$body" | grep -qF '|| true'
}

@test "volume list: marks a moved volume's real location" {
	have_volume oe-build-tmp 120G 4096
	vol move oe-build-tmp "$TESTDIR/relocated"
	[ "$status" -eq 0 ]
	vol list
	[ "$status" -eq 0 ]
	# The row is followed by a marker pointing at where the image really lives.
	printf '%s\n' "$output" | grep -qF "moved to: $TESTDIR/relocated/oe-build-tmp"
}

# The crash-window guard cannot be triggered from bats (it is signal timing),
# so pin it by source-grep: volume_move must block INT/TERM around the
# transfer-then-symlink window and restore the handler afterwards. If either
# line is dropped, a Ctrl-C mid-move could strand a first-moved volume.
@test "volume move: blocks INT/TERM across the transfer window (source-grep)" {
	# The move function's body, from its definition to the next function.
	local body
	body="$(awk '/^volume_move\(\)/{f=1} f{print} f&&/^}/{exit}' "$MACKAS")"
	printf '%s\n' "$body" | grep -qF "trap '' INT TERM"
	printf '%s\n' "$body" | grep -qF "trap on_interrupt INT TERM"
}

# A cross-filesystem move must NOT `mv` the tree (macOS mv across filesystems
# drops the sparse image's holes and balloons it to full logical size); it
# clones with holes preserved, then removes the source only AFTER. Two real
# filesystems can't exist in a test, so this sources mackas (MACKAS_LIB_ONLY),
# stubs the engine queries, and overrides volume_mount_point to look cross-fs.
@test "volume move: cross-filesystem clones with holes preserved, not mv" {
	MACKAS_LIB_ONLY=1 . "$MACKAS"
	setup_colors
	DRY_RUN=0; ASSUME_YES=1; VERBOSE=0
	CONTAINER_VOLUMES_DIR="$TESTDIR/vols"
	mkdir -p "$CONTAINER_VOLUMES_DIR/zzmv"
	: > "$CONTAINER_VOLUMES_DIR/zzmv/entity.json"
	: > "$CONTAINER_VOLUMES_DIR/zzmv/volume.img"

	# The volume exists and is not held; src and dest look cross-filesystem.
	volume_exists() { return 0; }
	volume_in_use() { return 1; }
	volume_mount_point() {
		case "$1" in "$CONTAINER_VOLUMES_DIR"*) echo /srcfs ;; *) echo /destfs ;; esac
	}
	# Record each run() invocation (numbered), still executing it, so we can
	# assert cp was used and preceded the source removal.
	RUNLOG="$TESTDIR/runlog"; : > "$RUNLOG"
	run() { printf '%s\n' "$*" >> "$RUNLOG"; "$@"; }

	volume_move zzmv "$TESTDIR/dest"

	# A holes-preserving clone (cp -cR) did the transfer; no plain `mv` of the
	# tree (the only mv is the atomic symlink plant, `mv -f`).
	grep -q '^cp -cR ' "$RUNLOG"
	! grep -qE '^mv [^-]' "$RUNLOG"
	# Source removed only AFTER the copy: cp line precedes the rm -rf line.
	cp_ln="$(grep -n '^cp -cR ' "$RUNLOG" | head -1 | cut -d: -f1)"
	rm_ln="$(grep -n '^rm -rf ' "$RUNLOG" | head -1 | cut -d: -f1)"
	[ -n "$cp_ln" ] && [ -n "$rm_ln" ] && [ "$cp_ln" -lt "$rm_ln" ]
	# The symlink lands right: runtime path -> the exact new home, tree present.
	[ -L "$CONTAINER_VOLUMES_DIR/zzmv" ]
	[ "$(readlink "$CONTAINER_VOLUMES_DIR/zzmv")" = "$TESTDIR/dest/zzmv" ]
	[ -f "$TESTDIR/dest/zzmv/volume.img" ]
	[ ! -e "$TESTDIR/vols/zzmv/volume.img" ] || [ -L "$CONTAINER_VOLUMES_DIR/zzmv" ]
}

# ---------------------------------------------------------------------------
# dispatch / help
# ---------------------------------------------------------------------------

@test "volume: an unknown subcommand is refused" {
	vol wobble
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "unknown 'volume' subcommand"
}

@test "volume --help: lists the subcommands" {
	vol --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'fstrim'
	printf '%s\n' "$output" | grep -qi 'duplicate'
	# It must explain how it differs from the top-level destroy.
	printf '%s\n' "$output" | grep -qi 'top-level'
}

@test "volume <sub> --help: shows the usage, not an unknown-option error" {
	# --help AFTER a subcommand used to reach the sub's own arg parser and die.
	vol fstrim --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'duplicate'
	! printf '%s\n' "$output" | grep -qi 'unknown option'
	# The same for a subcommand that otherwise takes positional args.
	vol move --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'fstrim'
}

@test "volume --help: documents every subcommand's aliases (Fable CLI review, F5)" {
	# The aliases (ls/rm/dup/trim/clone/relocate) already worked; they just
	# were not documented anywhere a user would find them.
	vol --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '(ls)'
	printf '%s\n' "$output" | grep -qF '(trim)'
	printf '%s\n' "$output" | grep -qF '(dup, clone)'
	printf '%s\n' "$output" | grep -qF '(delete, rm)'
	printf '%s\n' "$output" | grep -qF '(relocate)'
}

@test "volume --help: flag-placement wording says before OR after (it undersold its own behaviour)" {
	vol --help
	printf '%s\n' "$output" | grep -qi 'before or after'
}

@test "volume --help: documents --all/-a under both destroy and fstrim" {
	vol --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF -- '--all/-a'
}

@test "volume --help: documents -f/--force alongside -y/--yes" {
	vol --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF -- '-f/--force'
}

# ---------------------------------------------------------------------------
# volume recover -- a volume.img moved by hand; find it with Spotlight and
# offer to re-point the symlink. mdfind is stubbed via MACKAS_MDFIND.
# ---------------------------------------------------------------------------

# Write a fake mdfind that prints the given volume.img paths, one per line.
mk_mdfind() {
	MDFIND="$TESTDIR/fakebin/mdfind"
	{
		printf '#!/usr/bin/env bash\n'
		local p
		for p in "$@"; do printf 'printf "%%s\\n" %q\n' "$p"; done
	} > "$MDFIND"
	chmod +x "$MDFIND"
}

# Run `volume recover` with the stubbed mdfind on PATH-independent seam.
recover() {
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 volume recover "$@"
}

# Break a volume: move its dir aside and leave a dangling symlink where the
# runtime expects it. Echoes the moved-to dir.
break_volume() {
	local name="$1"
	local moved="$TESTDIR/moved/$name"
	mkdir -p "$TESTDIR/moved"
	mv "$(VOLDIR)/$name" "$moved"
	ln -s "$TESTDIR/gone/$name" "$(VOLDIR)/$name"   # dangling
	printf '%s' "$moved"
}

@test "volume recover: nothing to recover when every volume resolves" {
	have_volume oe-build-tmp 120G 4096
	have_volume oe-build-dl 40G 2048
	have_volume oe-build-sstate 40G 2048
	mk_mdfind
	recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to recover'
}

@test "volume recover: re-points a hand-moved volume that Spotlight finds" {
	have_volume oe-build-tmp 120G 4096
	moved="$(break_volume oe-build-tmp)"
	mk_mdfind "$moved/volume.img"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 -y volume recover oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'recovered'
	# The symlink now points at the moved location and resolves to volume.img.
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$moved" ]
	[ -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
}

@test "volume recover: refuses to guess when Spotlight returns several" {
	have_volume oe-build-tmp 120G 4096
	moved="$(break_volume oe-build-tmp)"
	mkdir -p "$TESTDIR/other/oe-build-tmp"
	: > "$TESTDIR/other/oe-build-tmp/entity.json"
	: > "$TESTDIR/other/oe-build-tmp/volume.img"
	mk_mdfind "$moved/volume.img" "$TESTDIR/other/oe-build-tmp/volume.img"
	recover oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qiE 'candidates|refusing to guess'
	# It must NOT have re-pointed (still dangling).
	[ ! -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
}

@test "volume recover: a candidate without entity.json is not offered" {
	have_volume oe-build-tmp 120G 4096
	break_volume oe-build-tmp >/dev/null
	mkdir -p "$TESTDIR/stray/oe-build-tmp"
	: > "$TESTDIR/stray/oe-build-tmp/volume.img"   # NO entity.json -> not a volume
	mk_mdfind "$TESTDIR/stray/oe-build-tmp/volume.img"
	recover oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qiE 'no volume.img|found no'
	[ ! -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
}

@test "volume recover: --dry-run does not re-point" {
	have_volume oe-build-tmp 120G 4096
	moved="$(break_volume oe-build-tmp)"
	mk_mdfind "$moved/volume.img"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 --dry-run volume recover oe-build-tmp
	[ "$status" -eq 0 ]
	# Still dangling: dry-run showed the ln but did not run it.
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$TESTDIR/gone/oe-build-tmp" ]
	# And it must NOT print a false failure: under --dry-run the rm/ln only
	# printed, so re-checking would wrongly claim the (correct) target failed.
	! printf '%s\n' "$output" | grep -qi 'still does not resolve'
	printf '%s\n' "$output" | grep -qi 'dry-run: would re-point'
}

@test "volume recover: scan finds a volume stranded absent from runtime and ls" {
	# The state an interrupted FIRST move leaves: no runtime dir, no symlink,
	# and NOT listed by `container volume ls` (entity.json moved with the tree).
	# A no-arg scan must still ask Spotlight, or the volume stays invisible.
	mkdir -p "$(VOLDIR)"
	local moved="$TESTDIR/stranded/oe-build-tmp"
	mkdir -p "$moved"
	: > "$moved/entity.json"
	: > "$moved/volume.img"
	mk_mdfind "$moved/volume.img"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 -y volume recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'recovered'
	# It re-pointed the runtime path at the stranded tree.
	[ "$(readlink "$(VOLDIR)/oe-build-tmp")" = "$moved" ]
	[ -f "$(VOLDIR)/oe-build-tmp/volume.img" ]
}

@test "volume recover: scan stays silent for a never-created volume" {
	# The counterpart: nothing on disk and Spotlight finds nothing -- a volume
	# that was simply never created must NOT be reported as broken.
	mkdir -p "$(VOLDIR)"
	mk_mdfind
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 volume recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'nothing to recover'
	! printf '%s\n' "$output" | grep -qi 'does not resolve'
}

@test "volume recover: a healthy named volume is reported healthy" {
	have_volume oe-build-tmp 120G 4096
	mk_mdfind
	recover oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'healthy'
}

# ---------------------------------------------------------------------------
# volume recover ALSO checks the workspace image (item 19 phase 3) on a
# no-arg scan -- it has no runtime symlink (its record is
# MACKAS_WORKSPACE_IMAGE itself), so the fix is moving the found file back to
# the recorded path, not re-pointing a symlink.
# ---------------------------------------------------------------------------

@test "volume recover: an attached workspace image is untouched, no Spotlight query" {
	have_volume oe-build-tmp 120G 4096
	local img="$TESTDIR/workspace.sparseimage"
	: > "$img"
	mk_mdfind "should-never-be-queried"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$img" volume recover
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qi 'workspace image is recorded'
}

@test "volume recover: no image configured is a pure no-op for the workspace check" {
	have_volume oe-build-tmp 120G 4096
	mk_mdfind
	recover
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qi 'workspace image'
}

@test "volume recover: a missing workspace image Spotlight finds gets moved back" {
	have_volume oe-build-tmp 120G 4096
	local recorded="$TESTDIR/root-drive/workspace.sparseimage"
	local found="$TESTDIR/other-drive/workspace.sparseimage"
	mkdir -p "$(dirname "$found")"
	echo "sparse-image-payload" > "$found"
	mk_mdfind "$found"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$recorded" -y volume recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'recovered workspace image'
	[ -f "$recorded" ]
	grep -qF "sparse-image-payload" "$recorded"
	[ ! -f "$found" ]
}

@test "volume recover: declining the workspace move leaves it in place, with an adopt hint" {
	have_volume oe-build-tmp 120G 4096
	local recorded="$TESTDIR/root-drive/workspace.sparseimage"
	local found="$TESTDIR/other-drive/workspace.sparseimage"
	mkdir -p "$(dirname "$found")"
	echo "sparse-image-payload" > "$found"
	mk_mdfind "$found"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$recorded" volume recover <<< "n"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'adopt it instead'
	printf '%s\n' "$output" | grep -qF "set MACKAS_WORKSPACE_IMAGE $found"
	[ -f "$found" ]
	[ ! -f "$recorded" ]
}

@test "volume recover: multiple workspace-image candidates refuses to guess" {
	have_volume oe-build-tmp 120G 4096
	local recorded="$TESTDIR/root-drive/workspace.sparseimage"
	local a="$TESTDIR/a/workspace.sparseimage" b="$TESTDIR/b/workspace.sparseimage"
	mkdir -p "$(dirname "$a")" "$(dirname "$b")"
	: > "$a"; : > "$b"
	mk_mdfind "$a" "$b"
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$recorded" -y volume recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'refusing to guess'
	[ ! -f "$recorded" ]
}

@test "volume recover: no Spotlight hits for the workspace image gives a clear message" {
	have_volume oe-build-tmp 120G 4096
	local recorded="$TESTDIR/root-drive/workspace.sparseimage"
	mk_mdfind
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$recorded" -y volume recover
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'found no file named'
	printf '%s\n' "$output" | grep -qF 'unset MACKAS_WORKSPACE_IMAGE'
}

@test "volume recover <name>: an explicit volume name skips the workspace-image check" {
	have_volume oe-build-tmp 120G 4096
	local recorded="$TESTDIR/root-drive/workspace.sparseimage"
	mk_mdfind
	MACKAS_MDFIND="$MDFIND" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_WORKSPACE_IMAGE=$recorded" -y volume recover oe-build-tmp
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qi 'workspace image'
}

# ---------------------------------------------------------------------------
# fsck -- repair ext4 corruption in a volume's backing image, on a CLONE
#
# `volume fsck` never lets a container near the real volume.img: it `cp -c`s
# (APFS clone) it into a scratch subdirectory FIRST, and that scratch
# directory is the ONLY bind mount the throwaway e2fsck container ever gets
# -- structurally, not just by convention (see the source-grep test below).
# The fake container models the mock e2fsck run via MOCK_FSCK_STATE
# (clean/dirty-repairable/unrepairable/apt-fail) rather than shelling out to
# a real losetup/e2fsck/apt-get.
# ---------------------------------------------------------------------------

@test "volume fsck: a clean volume is a no-op" {
	have_volume oe-build-tmp 120G 8192
	MOCK_FSCK_STATE=clean vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "clean -- no repair needed"
	refute_call "[mv]"
	# No pre-repair image kept, no leftover scratch dir.
	[ -z "$(ls "$(VOLDIR)/oe-build-tmp"/volume.img.mackas-corrupt-* 2>/dev/null)" ]
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
}

@test "volume fsck: corruption is detected, backed up, rehearsed against the clone, and promoted" {
	have_volume oe-build-tmp 120G 8192
	local before_sum; before_sum="$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')"
	MOCK_FSCK_STATE=dirty-repairable vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "repaired 'oe-build-tmp'"
	# The pre-repair image is kept, byte-identical to what the volume was
	# before this run (mackas's own undo).
	local kept; kept="$(ls "$(VOLDIR)/oe-build-tmp"/volume.img.mackas-corrupt-* 2>/dev/null | head -1)"
	[ -n "$kept" ]
	[ "$(shasum "$kept" | awk '{print $1}')" = "$before_sum" ]
	# The live volume.img now carries the mock's post-repair bytes -- content
	# actually changed, not just re-blessed in place.
	[ "$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" != "$before_sum" ]
	# No leftover scratch dir once promotion finished.
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
}

@test "volume fsck: declining the repair confirmation leaves everything untouched" {
	have_volume oe-build-tmp 120G 8192
	local before_sum; before_sum="$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')"
	# No -y, stdin not a tty => confirm() declines at GATE 1, before any clone
	# is even made.
	MOCK_FSCK_STATE=dirty-repairable vol fsck oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "left unchanged"
	[ "$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" = "$before_sum" ]
	[ -z "$(ls "$(VOLDIR)/oe-build-tmp"/volume.img.mackas-corrupt-* 2>/dev/null)" ]
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
	refute_call "[-v] [--cap-add]"
}

@test "volume fsck all: skips a volume a running container holds, still handles the others" {
	have_volume oe-build-tmp    120G 8192
	have_volume oe-build-dl     40G  8192
	have_volume oe-build-sstate 40G  8192
	MOCK_INUSE=oe-build-tmp MOCK_FSCK_STATE=clean vol -y fsck all
	[ "$status" -eq 0 ]
	# tmp is held, so it is skipped (warned), never cloned or checked...
	printf '%s\n' "$output" | grep -qi "oe-build-tmp.*skipping"
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
	# ...but the other two get the real treatment.
	printf '%s\n' "$output" | grep -qi "oe-build-dl.*clean -- no repair needed"
	printf '%s\n' "$output" | grep -qi "oe-build-sstate.*clean -- no repair needed"
}

@test "volume fsck <name>: an explicitly named busy volume refuses outright" {
	have_volume oe-build-tmp 120G 8192
	local before_sum; before_sum="$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')"
	MOCK_INUSE=oe-build-tmp vol -y fsck oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'only ONE VM'
	[ "$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" = "$before_sum" ]
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
	refute_call "[-v] [--cap-add]"
}

@test "volume fsck: --dry-run runs nothing and creates no backup" {
	have_volume oe-build-tmp 120G 8192
	local before_sum; before_sum="$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')"
	MOCK_FSCK_STATE=dirty-repairable vol --dry-run fsck oe-build-tmp
	[ "$status" -eq 0 ]
	refute_call "[--cap-add] [CAP_SYS_ADMIN]"
	[ -z "$(ls -d "$(VOLDIR)/oe-build-tmp"/.mackas-fsck-* 2>/dev/null)" ]
	[ -z "$(ls "$(VOLDIR)/oe-build-tmp"/volume.img.mackas-corrupt-* 2>/dev/null)" ]
	[ "$(shasum "$(VOLDIR)/oe-build-tmp/volume.img" | awk '{print $1}')" = "$before_sum" ]
}

@test "volume fsck: the original volume.img is never reachable from inside the guest (safety invariant)" {
	# Source-grep half: the container invocation's only -v names the scratch
	# clone, never the volume's own name/dir directly. Mirrors "volume fstrim:
	# the exact flags are asserted against the source too".
	grep -qF -- '-v "$work:/vol" "$(fsck_image)"' "$MACKAS"
	! grep -qF -- '-v "$name:/vol"' "$MACKAS"
	! grep -qF -- '-v "$dir:/vol"' "$MACKAS"
	! grep -qF -- '-v "$img:/vol"' "$MACKAS"

	# Behavioral half: confirm() declines outright whenever stdin is not a
	# real tty (checked BEFORE it ever reads a reply -- see mackas:229-250),
	# which a bats test can never fake with piped input, so a hermetic test
	# cannot sequence "yes to gate 1, no to gate 2" here. Verify the
	# invariant instead at the PROCESS level, on a run where the container
	# genuinely IS invoked and the repair genuinely IS promoted (-y, same
	# scenario as "corruption is detected, backed up, rehearsed... and
	# promoted" above): the real $CLOG argv the container actually received
	# must never carry the volume's own name -- only the scratch clone's
	# path -- proving the mount target really is what protects the original,
	# not merely that this run happened to decline before reaching it.
	have_volume oe-build-tmp 120G 8192
	MOCK_FSCK_STATE=dirty-repairable vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	assert_call "[--cap-add] [CAP_SYS_ADMIN]"
	local vbind; vbind="$(grep -oE '\[-v\] \[[^]]*:/vol\]' "$CLOG" | head -1)"
	[ -n "$vbind" ]
	printf '%s\n' "$vbind" | grep -qF ".mackas-fsck-"
	! printf '%s\n' "$vbind" | grep -qF "/oe-build-tmp:/vol"
}

# ---------------------------------------------------------------------------
# resize -- grow a volume in place (TODO.md item 26)
#
# `volume resize` grows a volume by COPYING it into a new one of the target
# size. There is no in-place grow: container volumes carry ext4's
# sparse_super2 feature, which the guest kernel cannot resize online, and an
# offline resize would need the filesystem unmounted -- which a container
# volume never is. So these tests pin the copy mechanism and the refusals
# around it, not a truncate/entity.json/resize2fs sequence.
#
# Shrinking is refused: the copy would work, but silently discarding data that
# no longer fits is not something mackas does on the user's behalf.

# Like have_volume, but also writes the entity.json the daemon really keeps --
# minified, keys unspaced, exactly the shape observed on a live install. resize
# reads sizeInBytes out of this and writes it back, so a realistic file is the
# whole point.
have_volume_with_entity() {
	local name="$1" size="$2" bytes="$3" kb="${4:-8192}"
	have_volume "$name" "$size" "$kb"
	printf '{"source":"%s/%s/volume.img","labels":{},"format":"ext4","name":"%s","driver":"local","sizeInBytes":%s,"creationDate":806328848.109219,"options":{"size":"%s"}}' \
		"$(VOLDIR)" "$name" "$name" "$bytes" "$size" > "$(VOLDIR)/$name/entity.json"
	# The image's APPARENT size is what gets extended; keep it consistent with
	# sizeInBytes so a grow is measurable.
	/usr/bin/python3 -c 'import os,sys; os.truncate(sys.argv[1], int(sys.argv[2]))' \
		"$(VOLDIR)/$name/volume.img" "$bytes"
}

apparent_size() { /usr/bin/python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_size)' "$1"; }

@test "volume resize: grows by copying into a new volume of the target size" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize oe-build-tmp 1T
	[ "$status" -eq 0 ]

	# A temp volume at the TARGET size, copied through, then cleaned up...
	assert_call 'volume] [create] [-s] [1T] [oe-build-tmp-mackas-resizing'
	assert_call 'tar -cf - . | (cd /to && tar -xf -)'
	assert_call 'volume] [delete] [oe-build-tmp-mackas-resizing'
	# ...leaving the volume under its ORIGINAL name at the new size.
	grep -qE '^oe-build-tmp\t1T$' "$VSTATE"
	assert_fails grep -q 'oe-build-tmp-mackas-resizing' "$VSTATE"
	# No in-place attempt: no daemon restart, no resize2fs.
	refute_call 'system] [start'
	refute_call 'resize2fs'
}

@test "volume resize: refuses to shrink rather than half-doing it" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize oe-build-tmp 40G
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'shrink'
	# Nothing moved: not the image, not the record.
	[ "$(apparent_size "$(VOLDIR)/oe-build-tmp/volume.img")" -eq 128849018880 ]
	grep -qF '"size":"120G"' "$(VOLDIR)/oe-build-tmp/entity.json"
	refute_call 'system] [start'
}

@test "volume resize: the same size is a no-op, not a pointless daemon restart" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize oe-build-tmp 120G
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'already that size'
	refute_call 'system] [start'
}

@test "volume resize: refuses a volume a running build holds (one-VM rule)" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	MOCK_INUSE=oe-build-tmp vol -y resize oe-build-tmp 1T
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'running container'
	[ "$(apparent_size "$(VOLDIR)/oe-build-tmp/volume.img")" -eq 128849018880 ]
}

@test "volume resize: --dry-run reports the plan and mutates nothing" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol --dry-run resize oe-build-tmp 1T
	[ "$status" -eq 0 ]
	[ "$(apparent_size "$(VOLDIR)/oe-build-tmp/volume.img")" -eq 128849018880 ]
	grep -qF '"sizeInBytes":128849018880' "$(VOLDIR)/oe-build-tmp/entity.json"
	refute_call 'system] [start'
}

@test "volume resize: rejects a size it cannot parse, before touching anything" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize oe-build-tmp banana
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a size'
	[ "$(apparent_size "$(VOLDIR)/oe-build-tmp/volume.img")" -eq 128849018880 ]
}

@test "volume resize: a nonexistent volume errors, and both arguments are required" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize no-such-volume 1T
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not exist'

	vol -y resize oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs <name> and <size>'
}

@test "volume resize: says so when the drive cannot back the growth, since sparse hides it" {
	# The image is sparse, so an over-large cap succeeds now and fails later,
	# mid-build, when the space is actually asked for. Saying it up front is
	# the entire value of the check.
	have_volume_with_entity oe-build-tmp 120G 128849018880
	vol -y resize oe-build-tmp 900T
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'cannot currently back'
	printf '%s\n' "$output" | grep -qi 'fails LATER'
}

@test "volume resize: refuses a volume whose entity.json it cannot read a size from" {
	# `container volume create` in the fake (like the real one, mid-create)
	# leaves an EMPTY entity.json. Guessing a size there would write a
	# fabricated sizeInBytes into the daemon's only record of the volume.
	have_volume oe-build-tmp 120G 4096
	: > "$(VOLDIR)/oe-build-tmp/entity.json"
	vol -y resize oe-build-tmp 1T
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'could not read the current size'
	refute_call 'system] [start'
}

@test "volume resize: declining the copy offer leaves everything untouched" {
	have_volume_with_entity oe-build-tmp 120G 128849018880
	# No -y and stdin not a tty => confirm() declines, which must be a clean
	# refusal, not a half-done resize.
	vol resize oe-build-tmp 1T
	[ "$status" -ne 0 ]
	[ "$(apparent_size "$(VOLDIR)/oe-build-tmp/volume.img")" -eq 128849018880 ]
	grep -qF '"sizeInBytes":128849018880' "$(VOLDIR)/oe-build-tmp/entity.json"
	refute_call 'volume] [create'
}

