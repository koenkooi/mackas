#!/usr/bin/env bats
#
# Tests for the ext4 "dirty bit" check wired into `check`/`status`
# (volume_dirty_bit()/check_volume_dirty_bit()/status_volume_dirty_bit() in
# mackas, tools/mackas-ext4-dirty-bit doing the actual superblock read).
# tools/test_ext4_dirty_bit.py already pins the byte-offset parsing itself;
# this file is about the BASH wiring: does check_state()/cmd_status() surface
# the right message for a dirty volume and stay silent for a clean one, and
# does this keep working even when the container daemon is down (it must --
# that is the whole point: host-side, no daemon, the one signal from
# check/status that still answers during the exact reboot-after-a-crash
# scenario issue #33 was about).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# HOME is pointed at TESTDIR (same convention as check_status_daemon_down.bats):
# CONTAINER_VOLUMES_DIR derives from $HOME, so real volume.img files can be
# planted under TESTDIR without going anywhere near the real Mac's volumes.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_RELOCATE_VOLUMES
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	VOLDIR="$HOME/Library/Application Support/com.apple.container/volumes"
	mkdir -p "$TESTDIR/fakebin"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# make_volume_image NAME STATE -- write a minimal, real ext2/3/4 superblock
# (1024-byte pad + a 1024-byte superblock with only magic/state set) at
# CONTAINER_VOLUMES_DIR/NAME/volume.img. STATE is the raw s_state value:
# 0x0001 clean, 0x0002 dirty (EXT2_ERROR_FS). Byte offsets match
# tools/mackas-ext4-dirty-bit's own (0x38 magic, 0x3A state) -- verified
# against e2fsprogs' ext2_fs.h, see that tool's module docstring.
make_volume_image() {
	local name="$1" state="$2" dir
	dir="$VOLDIR/$name"
	mkdir -p "$dir"
	: > "$dir/entity.json"
	/usr/bin/python3 -c "
import struct
sb = bytearray(1024)
struct.pack_into('<H', sb, 0x38, 0xEF53)
struct.pack_into('<H', sb, 0x3A, $state)
with open('$dir/volume.img', 'wb') as f:
    f.write(b'\\x00' * 1024)
    f.write(bytes(sb))
"
}

write_container_mock() {
	local mode="$1"
	cat > "$TESTDIR/fakebin/container" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
	"system status")
		$([ "$mode" = "UP" ] && echo 'echo "status running"; exit 0' || echo 'exit 1')
		;;
	"volume ls") echo "NAME TYPE DRIVER OPTIONS"; exit 0 ;;
	"image ls") echo "NAME TAG"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
}

mk() {
	PATH="$TESTDIR/fakebin:$PATH" run "$MACKAS" \
		--set "MACKAS_ROOT=$ROOT" --set "MACKAS_SHORT_LINK=$TESTDIR/short" "$@"
}

# ---------------------------------------------------------------------------
# check (rung 8)
# ---------------------------------------------------------------------------

@test "check: a dirty volume.img is reported as FAIL with the fsck fix hint" {
	make_volume_image oe-build-tmp 0x0002
	write_container_mock UP
	mk check
	printf '%s\n' "$output" | grep -qi "volume 'oe-build-tmp' has ext4 errors recorded on disk"
	printf '%s\n' "$output" | grep -qF 'volume fsck oe-build-tmp'
}

@test "check: a clean volume.img gets no dirty-bit line at all" {
	make_volume_image oe-build-tmp 0x0001
	write_container_mock UP
	mk check
	! printf '%s\n' "$output" | grep -qi 'ext4 errors recorded'
}

@test "check: the dirty-bit FAIL still fires with the daemon DOWN (host-side, no daemon needed)" {
	make_volume_image oe-build-tmp 0x0002
	write_container_mock DOWN
	mk check
	printf '%s\n' "$output" | grep -qi "volume 'oe-build-tmp' has ext4 errors recorded on disk"
}

@test "check: a not-yet-created volume (no volume.img at all) gets no dirty-bit line" {
	write_container_mock UP
	mk check
	! printf '%s\n' "$output" | grep -qi 'ext4 errors recorded'
}

# ---------------------------------------------------------------------------
# status (the "ext4 volumes" section)
# ---------------------------------------------------------------------------

@test "status: a dirty volume.img gets the annotation line with the fix hint" {
	make_volume_image oe-build-tmp 0x0002
	write_container_mock UP
	mk status
	printf '%s\n' "$output" | grep -qi 'ext4 errors recorded on disk'
	printf '%s\n' "$output" | grep -qF 'volume fsck oe-build-tmp'
}

@test "status: a clean volume.img gets no annotation" {
	make_volume_image oe-build-tmp 0x0001
	write_container_mock UP
	mk status
	! printf '%s\n' "$output" | grep -qi 'ext4 errors recorded'
}

@test "status: the dirty-bit annotation still fires with the daemon DOWN" {
	make_volume_image oe-build-tmp 0x0002
	write_container_mock DOWN
	mk status
	printf '%s\n' "$output" | grep -qi 'ext4 errors recorded on disk'
}

# ---------------------------------------------------------------------------
# Graceful degradation: the check itself missing is silent, never a warning
# ---------------------------------------------------------------------------

@test "check: the dirty-bit check degrades silently (no warning) when its own tool file is missing" {
	make_volume_image oe-build-tmp 0x0002
	write_container_mock UP
	# --set can't relocate SCRIPT_DIR (it is derived from the binary's own
	# path, not a setting), so point MACKAS at a copy in a directory with no
	# tools/ subdirectory at all -- the same "detect, don't require" shape
	# volume_dirty_bit()'s own [ -f "$tool" ] guard is written to hit.
	local nodir="$TESTDIR/no-tools-here"
	mkdir -p "$nodir"
	cp "$MACKAS" "$nodir/mackas"
	chmod +x "$nodir/mackas"
	PATH="$TESTDIR/fakebin:$PATH" run "$nodir/mackas" \
		--set "MACKAS_ROOT=$ROOT" --set "MACKAS_SHORT_LINK=$TESTDIR/short" check
	! printf '%s\n' "$output" | grep -qi 'ext4 errors recorded'
	! printf '%s\n' "$output" | grep -qi 'dirty.bit'
	! printf '%s\n' "$output" | grep -qi 'mackas-ext4-dirty-bit'
}
