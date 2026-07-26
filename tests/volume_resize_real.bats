#!/usr/bin/env bats
#
# OPT-IN real-runtime tests for `mackas volume resize` -- the live half that
# the hermetic suite in volume_mgmt.bats cannot reach.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKIPPED BY DEFAULT, exactly like real_runtime.bats. `volume resize` is
# three moving parts that only a real daemon and a real kernel can settle:
#
#   1. the sparse volume.img is extended on the host,
#   2. entity.json is rewritten and the daemon is RESTARTED so it re-reads it,
#   3. resize2fs grows the ext4 filesystem inside the mounted volume.
#
# The hermetic tests pin that mackas issues all three in the right order. They
# cannot prove the two things that actually decide whether the feature works:
# whether Apple's daemon really re-reads an EDITED entity.json on restart (its
# index is built once, at startup -- the same fact refuse_if_stale_entity
# relies on), and whether the kas image even ships resize2fs. Both are
# answered here, against a real volume, with real data written before the grow
# and checksummed after it.
#
#   MACKAS_REAL_RUNTIME=1 bats tests/volume_resize_real.bats
#
# To exercise a volume living on ANOTHER DRIVE -- which is the case that makes
# the free-space reporting non-trivial, since a moved volume is measured on
# its own disk rather than MACKAS_ROOT's -- point this at a directory there.
# It is deliberately NOT hardcoded to any particular disk:
#
#   MACKAS_REAL_RUNTIME=1 \
#   MACKAS_REAL_VOLUME_DIR="/Volumes/<some disk>/mackas-volume-test" \
#       bats tests/volume_resize_real.bats
#
# SAFETY (dev-Mac only, enforced here, same rules as real_runtime.bats):
#   * Runs only when MACKAS_REAL_RUNTIME=1 AND the runtime is up.
#   * REFUSES while any container holds an oe-build-* volume (one-VM rule).
#   * Only ever creates/attaches/removes volumes named zztest-*. It never
#     names, attaches or removes an oe-build-* volume.
#   * teardown() sweeps every zztest-* volume AND any container still holding
#     one, after each test, pass or fail, plus anything created under
#     MACKAS_REAL_VOLUME_DIR. The container sweep matters: test 6 starts a
#     detached container deliberately, and an interrupted run would strand it
#     holding a volume at Apple's default 4 CPU / 1 GB -- enough to block later
#     container creation, and hard to recognise as test fallout.
#
# NOTE: a resize RESTARTS the container daemon. That is why the one-VM guard
# above is not optional here -- a restart mid-build would take the build with
# it.

load helpers

VOLS_DIR="$HOME/Library/Application Support/com.apple.container/volumes"

# Sizes kept small so the run is quick. They cost nothing on disk: the images
# are sparse, so a 2G cap allocates no blocks until written.
START_SIZE="1G"
GROWN_SIZE="3G"

rt_image() {
	if [ -n "${MACKAS_RT_IMAGE:-}" ]; then
		printf '%s' "$MACKAS_RT_IMAGE"
		return
	fi
	local ver
	ver="$(sed -n 's/^KAS_CONTAINER_VERSION="\([^"]*\)".*/\1/p' "$MACKAS" | head -1)"
	printf 'ghcr.io/siemens/kas/kas:%s' "$ver"
}

container_running() {
	container system status >/dev/null 2>&1 || return 1
	container system status 2>/dev/null \
		| awk '$1=="status" {print $2}' | grep -q '^running$'
}

# Fail CLOSED: anything we cannot determine counts as "in use".
oe_build_in_use() {
	container_running || return 1
	local listing ids id detail
	listing="$(container ls 2>/dev/null)" || return 0
	ids="$(printf '%s\n' "$listing" | awk 'NR>1 {print $1}')"
	for id in $ids; do
		[ -n "$id" ] || continue
		detail="$(container inspect "$id" 2>/dev/null)" || return 0
		if printf '%s\n' "$detail" \
			| grep -qE '"name"[[:space:]]*:[[:space:]]*"oe-build'; then
			return 0
		fi
	done
	return 1
}

rm_vol() {
	container volume rm "$1" >/dev/null 2>&1 \
		|| container volume delete "$1" >/dev/null 2>&1 || true
}

# Kill and remove any container still holding a zztest-* volume.
#
# Test 6 starts a DETACHED container on purpose (to prove the one-VM refusal),
# and a detached container outlives an interrupted run -- ^C, a killed bats, a
# timeout. It then sits there holding an ext4 volume at Apple's default
# 4 CPU / 1 GB, which is enough to block later container creation and is
# maddening to diagnose because it looks nothing like a build. Sweeping is not
# tidiness; leaving one behind breaks the machine for whatever runs next.
sweep_zztest_containers() {
	local listing ids id detail
	listing="$(container ls -a 2>/dev/null)" || return 0
	ids="$(printf '%s\n' "$listing" | awk 'NR>1 {print $1}')"
	for id in $ids; do
		[ -n "$id" ] || continue
		detail="$(container inspect "$id" 2>/dev/null)" || continue
		printf '%s\n' "$detail" \
			| grep -qE '"name"[[:space:]]*:[[:space:]]*"zztest-' || continue
		container kill "$id" >/dev/null 2>&1 || true
		container rm "$id" >/dev/null 2>&1 || true
	done
}

sweep_zztest() {
	local v
	container volume ls 2>/dev/null | awk 'NR>1 {print $1}' \
		| grep '^zztest-' | while IFS= read -r v; do
			[ -n "$v" ] && rm_vol "$v"
		done
	# A `volume move`d volume leaves a symlink behind that the daemon-level
	# delete does not touch; clear any zztest-* one so a later run starts clean.
	local l
	for l in "$VOLS_DIR"/zztest-*; do
		[ -e "$l" ] || [ -L "$l" ] || continue
		rm -rf "$l"
	done
}

# The runtime path for NAME, following the per-volume symlink `volume move`
# plants -- the symlink IS the record of where a volume lives.
vol_real_dir() {
	local link="$VOLS_DIR/$1"
	if [ -L "$link" ]; then readlink "$link"; else printf '%s' "$link"; fi
}

# sizeInBytes as the daemon records it -- the number `resize` must move.
entity_bytes() {
	sed -n 's/.*"sizeInBytes":\([0-9][0-9]*\).*/\1/p' "$(vol_real_dir "$1")/entity.json" | head -1
}

# Bytes the ext4 filesystem INSIDE the volume reports. This is the number that
# proves resize2fs ran: the daemon and the image can agree on a new size while
# the filesystem inside is still the old one, which is the silent-no-op this
# whole feature has to avoid.
guest_fs_bytes() {
	container run --rm -u 0:0 -v "$1:/mnt" "$(rt_image)" \
		sh -c 'df -B1 --output=size /mnt | tail -1' 2>/dev/null | tr -d ' \r'
}

# Create a zztest volume and chown it so the image's non-root user can write.
make_vol() {
	container volume create -s "$2" "$1" >/dev/null
	container run --rm -u 0:0 -v "$1:/mnt" "$(rt_image)" \
		chown "$(id -u):$(id -g)" /mnt >/dev/null 2>&1 || true
}

mk() {
	run "$MACKAS" --set "MACKAS_ROOT=$TESTROOT" \
		--set "MACKAS_SHORT_LINK=$TESTROOT/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

setup() {
	if [ "${MACKAS_REAL_RUNTIME:-}" != "1" ]; then
		skip "opt-in: set MACKAS_REAL_RUNTIME=1 (dev-Mac only, non-hermetic, never CI)"
	fi
	if ! container_running; then
		skip "Apple container runtime is not running (container system start)"
	fi
	if oe_build_in_use; then
		skip "REFUSING: an oe-build-* volume is attached to a running container (one-VM rule)"
	fi
	# `resize` is a mutating command and requires a root; give it a throwaway
	# one. It is only ever used as a gate here -- no volume lives under it.
	TESTROOT="$(make_tmpdir)"
	sweep_zztest_containers
	sweep_zztest
}

teardown() {
	[ "${MACKAS_REAL_RUNTIME:-}" = "1" ] || return 0
	sweep_zztest_containers
	sweep_zztest
	[ -n "${TESTROOT:-}" ] && rm -rf "$TESTROOT"
	# Only ever removes zztest-* dirs we created under the caller's directory.
	if [ -n "${MACKAS_REAL_VOLUME_DIR:-}" ]; then
		rm -rf "${MACKAS_REAL_VOLUME_DIR:?}"/zztest-* 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------

@test "real resize: grows the filesystem, and the data written before it survives" {
	# The headline. Everything else in this file is a guard around this.
	local v=zztest-resize
	make_vol "$v" "$START_SIZE"

	# Populate with something whose integrity is checkable, plus enough bulk
	# that a truncated/recreated filesystem could not fake it.
	local sum_before
	sum_before="$(container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" sh -c '
		set -e
		mkdir -p /mnt/payload
		dd if=/dev/urandom of=/mnt/payload/blob bs=1M count=64 status=none
		echo "canary-do-not-lose-me" > /mnt/payload/canary.txt
		sha256sum /mnt/payload/blob | cut -d" " -f1
	')"
	[ -n "$sum_before" ]

	local fs_before daemon_before
	fs_before="$(guest_fs_bytes "$v")"
	daemon_before="$(entity_bytes "$v")"
	[ "$fs_before" -gt 0 ]

	mk -y volume resize "$v" "$GROWN_SIZE"
	[ "$status" -eq 0 ]

	# 1. The daemon's own record moved...
	local daemon_after; daemon_after="$(entity_bytes "$v")"
	[ "$daemon_after" -gt "$daemon_before" ]
	# 2. ...and so did the FILESYSTEM inside, which is the part that is easy to
	#    get wrong: a bigger block device with the same-sized ext4 gains nothing.
	local fs_after; fs_after="$(guest_fs_bytes "$v")"
	[ "$fs_after" -gt "$fs_before" ]
	# 3. ...and the data is still there, byte-identical.
	local sum_after
	sum_after="$(container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" \
		sh -c 'sha256sum /mnt/payload/blob | cut -d" " -f1')"
	[ "$sum_after" = "$sum_before" ]
	container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" \
		grep -qx 'canary-do-not-lose-me' /mnt/payload/canary.txt
}

@test "real resize: the grown space is actually usable, not just reported" {
	# A filesystem can report a bigger size and still fail to allocate into it.
	# Write past the ORIGINAL cap to prove the space is real.
	local v=zztest-usable
	make_vol "$v" "$START_SIZE"

	mk -y volume resize "$v" "$GROWN_SIZE"
	[ "$status" -eq 0 ]

	# 1.6G of writes cannot fit in the original 1G volume.
	run container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" sh -c '
		set -e
		dd if=/dev/zero of=/mnt/big bs=1M count=1600 status=none
		ls -l /mnt/big | awk "{print \$5}"
	'
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q '1677721600'
}

@test "real resize: refuses to shrink, and changes nothing when it does" {
	local v=zztest-shrink
	make_vol "$v" "$GROWN_SIZE"
	local before; before="$(entity_bytes "$v")"

	mk -y volume resize "$v" "$START_SIZE"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'shrink'
	[ "$(entity_bytes "$v")" = "$before" ]
}

@test "real resize: the same size is a no-op and does not restart the daemon" {
	local v=zztest-noop
	make_vol "$v" "$START_SIZE"
	local before; before="$(entity_bytes "$v")"

	mk -y volume resize "$v" "$START_SIZE"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'already that size'
	[ "$(entity_bytes "$v")" = "$before" ]
}

@test "real resize: a volume moved to another drive grows there, measured on THAT drive" {
	# The case that makes free-space reporting non-trivial: after `volume
	# move`, the image lives on another disk and must be measured there, not on
	# MACKAS_ROOT's. Location comes from the environment -- never hardcoded.
	[ -n "${MACKAS_REAL_VOLUME_DIR:-}" ] || \
		skip "set MACKAS_REAL_VOLUME_DIR=/Volumes/<disk>/<dir> to exercise a cross-drive resize"
	mkdir -p "$MACKAS_REAL_VOLUME_DIR" || skip "cannot write to $MACKAS_REAL_VOLUME_DIR"

	local v=zztest-moved
	make_vol "$v" "$START_SIZE"

	local sum_before
	sum_before="$(container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" sh -c '
		set -e
		dd if=/dev/urandom of=/mnt/blob bs=1M count=32 status=none
		sha256sum /mnt/blob | cut -d" " -f1
	')"

	mk -y volume move "$v" "$MACKAS_REAL_VOLUME_DIR"
	[ "$status" -eq 0 ]
	# It really is on the other drive now, behind the symlink that records it.
	[ -L "$VOLS_DIR/$v" ]
	[ "$(vol_real_dir "$v")" = "$MACKAS_REAL_VOLUME_DIR/$v" ]
	[ -f "$MACKAS_REAL_VOLUME_DIR/$v/volume.img" ]

	local fs_before; fs_before="$(guest_fs_bytes "$v")"

	mk -y volume resize "$v" "$GROWN_SIZE"
	[ "$status" -eq 0 ]
	# The free-space line must name the drive the image is really on, which is
	# a different filesystem from MACKAS_ROOT's.
	printf '%s\n' "$output" | grep -qi 'free on that drive'

	# Grown in place, still on the other drive, data intact.
	[ "$(vol_real_dir "$v")" = "$MACKAS_REAL_VOLUME_DIR/$v" ]
	[ "$(guest_fs_bytes "$v")" -gt "$fs_before" ]
	local sum_after
	sum_after="$(container run --rm -u 0:0 -v "$v:/mnt" "$(rt_image)" \
		sh -c 'sha256sum /mnt/blob | cut -d" " -f1')"
	[ "$sum_after" = "$sum_before" ]
}

@test "real resize: refuses a volume a running container holds (one-VM rule)" {
	local v=zztest-inuse
	make_vol "$v" "$START_SIZE"

	# Hold the volume from a detached container, then try to resize it.
	local cid
	cid="$(container run -d -v "$v:/mnt" "$(rt_image)" sleep 120 2>/dev/null)" \
		|| skip "could not start a detached container to hold the volume"

	mk -y volume resize "$v" "$GROWN_SIZE"
	local rc="$status" out="$output"

	container kill "$cid" >/dev/null 2>&1 || true
	container rm "$cid" >/dev/null 2>&1 || true

	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'running container'
}
