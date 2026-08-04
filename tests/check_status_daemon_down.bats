#!/usr/bin/env bats
#
# Issue #33, part 2: `check`/`status` stay read-only (no auto-start), but must
# not misreport real state as absent/orphaned when the container daemon is
# simply not running. Before this fix, volume_exists()/image_present()/
# find_orphaned_volume_images() all ask the daemon ('container volume ls' /
# 'image ls'), which return nothing while it's down -- every volume that
# genuinely exists on disk printed as "[ no]" (check_one_volume/status_volume)
# or even "orphaned" (find_orphaned_volume_images), even though nothing was
# actually wrong. The fix short-circuits rung 8 (check_state) and the "ext4
# volumes" section (cmd_status) with one clear line instead.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# HOME is pointed at TESTDIR, same as every other full-CLI test file here --
# CONTAINER_VOLUMES_DIR derives from $HOME ("$HOME/Library/Application
# Support/com.apple.container/volumes"), so real volume dirs can be planted
# under TESTDIR without going anywhere near the real Mac's actual volumes.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_RELOCATE_VOLUMES
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	VOLDIR="$HOME/Library/Application Support/com.apple.container/volumes"

	# Plant real, on-disk volume trees for all three mackas volumes -- exactly
	# what a genuinely-present, just-currently-unreachable (daemon down) set
	# of volumes looks like on disk.
	for v in oe-build-tmp oe-build-dl oe-build-sstate; do
		mkdir -p "$VOLDIR/$v"
		: > "$VOLDIR/$v/entity.json"
		printf 'not really ext4, just needs to be a real file with real bytes\n' > "$VOLDIR/$v/volume.img"
	done

	mkdir -p "$TESTDIR/fakebin"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# write_container_mock UP|DOWN -- UP: 'system status'/'volume ls'/'image ls'
# report the daemon running with none of the mackas volumes/image (so any
# [ no]/orphaned finding in the UP case is real, not a daemon-down artifact).
# DOWN: 'system status' fails outright, as it does the moment the runtime
# just isn't running -- the actual issue #33 condition.
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
# check (rung 8: check_state)
# ---------------------------------------------------------------------------

@test "check: daemon down -- one short-circuit line, no [ no]/orphaned noise for real on-disk volumes" {
	write_container_mock DOWN
	mk check
	printf '%s\n' "$output" | grep -qi 'container system is not running'
	printf '%s\n' "$output" | grep -qi 'everything below this point is UNKNOWN'
	! printf '%s\n' "$output" | grep -q 'not created yet'
	! printf '%s\n' "$output" | grep -qi 'orphaned'
}

@test "check: daemon up but volumes genuinely absent from 'volume ls' -- [info] not-created-yet is real, not suppressed" {
	# Contrast case: proves the short-circuit is conditional on the daemon
	# being down, not a blanket change to rung 8's behavior. Here the daemon
	# answers, and 'volume ls' genuinely lists none of the three -- that IS
	# real "not created yet" and must still be reported.
	write_container_mock UP
	mk check
	printf '%s\n' "$output" | grep -q 'not created yet'
	! printf '%s\n' "$output" | grep -qi 'container system is not running'
}

# ---------------------------------------------------------------------------
# status (the "ext4 volumes" section)
# ---------------------------------------------------------------------------

@test "status: daemon down -- ext4 volumes section short-circuits, no [ no] for real on-disk volumes" {
	write_container_mock DOWN
	mk status
	printf '%s\n' "$output" | grep -qi 'volume existence cannot be checked'
	ext4_section="$(printf '%s\n' "$output" | awk '/ext4 volumes/{f=1;next} /^$/{f=0} f')"
	! printf '%s\n' "$ext4_section" | grep -qF '[ no]'
}

@test "status: daemon up but volumes genuinely absent -- [ no] is real, not suppressed" {
	write_container_mock UP
	mk status
	ext4_section="$(printf '%s\n' "$output" | awk '/ext4 volumes/{f=1;next} /^$/{f=0} f')"
	printf '%s\n' "$ext4_section" | grep -qF '[ no]'
}
