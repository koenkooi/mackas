#!/usr/bin/env bats
#
# OPT-IN real-runtime smoketest -- the one suite that touches the actual Apple
# `container` runtime.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKIPPED BY DEFAULT. Every other test in this repo is hermetic (mock container,
# no VM). This file is the exception: it starts real containers to regression
# test the two things nothing else can -- that a `container volume` is created
# sparse, and that `fstrim` inside the guest actually hands host disk back (the
# whole reason mackas runs it around every build). Because it is non-hermetic it
# is NEVER run in CI and NEVER by a plain `./run-tests.sh`.
#
#   MACKAS_REAL_RUNTIME=1 bats tests/real_runtime.bats
#
# SAFETY (dev-Mac only, and it enforces this itself):
#   * It runs only when MACKAS_REAL_RUNTIME=1 AND the runtime is up.
#   * It REFUSES to run while any container holds an oe-build-* volume (a live
#     build): the one-VM rule -- an ext4 image mounted by two VMs corrupts.
#   * It only ever creates/attaches/removes volumes named zztest-*. It never
#     names, attaches, or removes an oe-build-* volume.
#   * teardown() sweeps every zztest-* volume after each test, pass or fail.

load helpers

# Where Apple `container` keeps each volume's backing image. Same path mackas
# measures du on. Quoted everywhere -- it contains spaces.
VOLS_DIR="$HOME/Library/Application Support/com.apple.container/volumes"

# The image the real fstrim recipe uses. Derived from mackas's pinned version so
# this tracks a bump; overridable for a local experiment.
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

# Fail CLOSED: if any running container's inspect names an oe-build-* volume, or
# we cannot tell, treat it as in use.
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

# du of a file in KB (allocated blocks: what a sparse image really costs).
duk() {
	du -k "$1" 2>/dev/null | awk '{print $1; exit}'
}

# Remove one volume, tolerating both spellings and an already-gone volume.
rm_vol() {
	container volume rm "$1" >/dev/null 2>&1 \
		|| container volume delete "$1" >/dev/null 2>&1 || true
}

# Sweep EVERY zztest-* volume. Never matches oe-build-*.
sweep_zztest() {
	local v
	container volume ls 2>/dev/null | awk 'NR>1 {print $1}' \
		| grep '^zztest-' | while IFS= read -r v; do
			[ -n "$v" ] && rm_vol "$v"
		done
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
	# Belt and braces: start each test from a clean zztest slate.
	sweep_zztest
}

teardown() {
	# Runs after every test, pass or fail -- the trap that guarantees no zztest-*
	# volume is left behind. Guarded so it is a no-op when setup skipped.
	[ "${MACKAS_REAL_RUNTIME:-}" = "1" ] || return 0
	sweep_zztest
}

# ---------------------------------------------------------------------------

@test "real-runtime: container system status reports running" {
	run container system status
	[ "$status" -eq 0 ]
	container_running
}

@test "real-runtime: a 1G zztest volume is created and is sparse" {
	local name="zztest-sparse-$$"
	run container volume create -s 1G "$name"
	[ "$status" -eq 0 ]

	local img="$VOLS_DIR/$name/volume.img"
	[ -e "$img" ]

	# Apparent size is ~1 GiB; a sparse image costs a tiny fraction of that until
	# used. Assert the on-disk cost is far below the 1 GiB (1048576 KB) capacity.
	local kb
	kb="$(duk "$img")"
	[ -n "$kb" ]
	if [ "$kb" -ge 65536 ]; then
		printf 'fresh volume already costs %s KB on disk; not sparse?\n' "$kb" >&2
		return 1
	fi

	rm_vol "$name"
}

@test "real-runtime: fstrim reclaims freed space in a zztest volume" {
	# The ONLY way to regression-test the reclaim mackas depends on: write, delete,
	# fstrim, and prove the backing image SHRANK on the host. fstrim's own
	# "N bytes trimmed" line is the guest's free space, not host reclaim, so we
	# trust the host du delta instead.
	local name="zztest-rt-$$"
	local img="$VOLS_DIR/$name/volume.img"
	local image; image="$(rt_image)"

	run container volume create -s 1G "$name"
	[ "$status" -eq 0 ]
	[ -e "$img" ]

	# Write 200 MiB and fsync so the backing image really grows on disk.
	run container run --rm -u 0:0 -v "$name:/mnt" "$image" \
		sh -c 'dd if=/dev/zero of=/mnt/big bs=1M count=200 && sync'
	[ "$status" -eq 0 ]
	local grown; grown="$(duk "$img")"
	if [ "${grown:-0}" -lt 150000 ]; then
		printf 'write did not grow the image (du=%s KB)\n' "$grown" >&2
		return 1
	fi

	# Delete the file. Without a discard the host image stays large -- this is
	# exactly the dead space fstrim exists to reclaim.
	run container run --rm -u 0:0 -v "$name:/mnt" "$image" \
		sh -c 'rm -f /mnt/big && sync'
	[ "$status" -eq 0 ]
	local afterdel; afterdel="$(duk "$img")"
	# It should still be roughly as large as when full (no discard happened yet).
	if [ "${afterdel:-0}" -lt 150000 ]; then
		printf 'image shrank on delete alone (du=%s KB) -- discard fired without fstrim?\n' \
			"$afterdel" >&2
		return 1
	fi

	# The recipe under test: -u 0:0 AND --cap-add CAP_SYS_ADMIN are both required.
	run container run --rm -u 0:0 --cap-add CAP_SYS_ADMIN -v "$name:/mnt" "$image" \
		fstrim -v /mnt
	[ "$status" -eq 0 ]
	local trimmed; trimmed="$(duk "$img")"

	# The host reclaimed the space: the image is now a fraction of its grown size.
	local reclaimed=$(( ${grown:-0} - ${trimmed:-0} ))
	if [ "$reclaimed" -lt 100000 ]; then
		printf 'fstrim did not reclaim: grown=%s afterdel=%s trimmed=%s (reclaimed=%s KB)\n' \
			"$grown" "$afterdel" "$trimmed" "$reclaimed" >&2
		return 1
	fi
	if [ "${trimmed:-0}" -ge 65536 ]; then
		printf 'image still costs %s KB after fstrim; reclaim incomplete\n' "$trimmed" >&2
		return 1
	fi

	rm_vol "$name"
}

@test "real-runtime: a zztest volume can be created and removed cleanly" {
	local name="zztest-rm-$$"
	run container volume create -s 1G "$name"
	[ "$status" -eq 0 ]
	container volume ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "$name"

	rm_vol "$name"
	# It must be gone.
	if container volume ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "$name"; then
		printf 'volume %s still present after removal\n' "$name" >&2
		return 1
	fi
}
