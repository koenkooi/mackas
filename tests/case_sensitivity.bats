#!/usr/bin/env bats
#
# setup must refuse a case-INSENSITIVE MACKAS_ROOT, not just warn about it.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Real-world bug this guards: `mackas check` correctly FAILs a case-insensitive
# root, but `mackas setup` used to skip that probe entirely and report "Done"
# across all 11 steps -- leaving a root that looked fully set up but broke on
# the very first `kas-container build` with git errors from a corrupted oe-core
# checkout ("fatal: unknown error occurred while reading the configuration
# files"). A successful `setup` must mean a USABLE root.
#
# tests/helpers.bash exports MACKAS_REQUIRE_CASE_SENSITIVE=0 for the whole
# suite (the bats tmpdir itself is case-insensitive APFS), so every test here
# re-enables the gate explicitly to test it.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	export HOME="$TESTDIR"

	# A fake `container` so nothing here can touch the real Apple runtime. The
	# refusal happens in setup_oe_root(), before any container call, so the
	# negative test never reaches this; the positive test runs --dry-run, which
	# also never reaches it -- both belt-and-suspenders.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls")     echo "NAME"; exit 0 ;;
	*)               exit 0 ;;
esac
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

@test "setup: refuses a case-INSENSITIVE work/ when the workspace-image offer is declined" {
	# $TESTDIR is under the bats tmpdir, guaranteed case-insensitive per
	# helpers.bash's comment -- re-enable the gate to prove it fires here.
	# No -y: offer_workspace_image()'s confirm() must auto-decline (no tty,
	# ASSUME_YES unset), falling through to the same die() as before this
	# offer existed. $TESTDIR/root's parent is writable, so setup reaches the
	# gate without any EARLIER confirm() prompt muddying the result.
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'CASE-INSENSITIVE filesystem'
	# It must be OUR gate that refused, not some later, murkier failure --
	# and it must refuse before ever calling the container runtime.
	printf '%s\n' "$output" | grep -qF 'point MACKAS_ROOT at a case-sensitive volume'
	! printf '%s\n' "$output" | grep -qiF 'unbound variable'
}

@test "setup: offers a workspace image, and --dry-run shows the create command on accept" {
	# work/ must genuinely exist first: under --dry-run, setup_oe_root's own
	# `mkdir -p work/` is only PRINTED, never executed, so a not-yet-real
	# work/ probes as "unknown" (2), not "insensitive" (1), and the offer
	# would never fire. Pre-create it for real -- realistic anyway, since a
	# second `setup` run (this gate's actual trigger) always finds it there.
	mkdir -p "$TESTDIR/root/work"
	# --dry-run + -y: the offer is accepted, but run() prints hdiutil instead
	# of executing it, so this stays hermetic -- no real image is created.
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	printf '%s\n' "$output" | grep -qF 'create a case-sensitive workspace image'
	printf '%s\n' "$output" | grep -qF 'hdiutil create'
	# quote_cmd renders the space-containing arg backslash-escaped, not quoted.
	printf '%s\n' "$output" | grep -qF 'Case-sensitive\ APFS'
	printf '%s\n' "$output" | grep -qF "$TESTDIR/root/workspace"
	printf '%s\n' "$output" | grep -qF 'hdiutil attach'
	printf '%s\n' "$output" | grep -qF -- '-nobrowse'
	# No -mountpoint (found live: fails when work/ sits on a non-APFS host
	# volume); work/ becomes a symlink to whatever real path hdiutil reports.
	! printf '%s\n' "$output" | grep -qF -- '-mountpoint'
	printf '%s\n' "$output" | grep -qF "ln -s /Volumes/mackas-workspace $TESTDIR/root/work"
	# Creating the image must also leave the two things that make it survive a
	# reboot: the sentinel at the mount root, and the recorded path (item 19).
	# Without them work/ comes back as a bare case-insensitive directory and
	# nothing downstream knows it was ever supposed to be a mount.
	printf '%s\n' "$output" | grep -qF '.mackas-workspace'
	printf '%s\n' "$output" | grep -qF 'MACKAS_WORKSPACE_IMAGE'
	# The post-mount sanity re-probe must not fire a false "still not
	# case-sensitive" die under --dry-run, where nothing was really mounted.
	! printf '%s\n' "$output" | grep -qF 'still not case-sensitive after mounting'
}

@test "setup: offers to REATTACH an existing workspace image, not recreate it" {
	# work/ must genuinely exist too (see the previous test for why); a
	# pre-existing workspace.sparseimage (a dummy file -- --dry-run never
	# touches it for real) must steer offer_workspace_image() to the
	# reattach branch, not the create-a-new-one branch.
	mkdir -p "$TESTDIR/root/work"
	: > "$TESTDIR/root/workspace.sparseimage"
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	printf '%s\n' "$output" | grep -qF 'already exists'
	printf '%s\n' "$output" | grep -qF 'reattach it?'
	printf '%s\n' "$output" | grep -qF 'hdiutil attach'
	! printf '%s\n' "$output" | grep -qF 'hdiutil create'
	! printf '%s\n' "$output" | grep -qF -- '-mountpoint'
	printf '%s\n' "$output" | grep -qF "ln -s /Volumes/mackas-workspace $TESTDIR/root/work"
}

@test "setup: a dangling work/ symlink (Mac rebooted since the last attach) is reattached, not mkdir'd over" {
	# The real bug, found live on a real Mac: work/ survives a reboot as a
	# symlink, but hdiutil attach does not -- the mount point it names is
	# gone. setup_oe_root()'s directory loop used to `[ -d work ] || mkdir -p
	# work`, and mkdir on a path that is already a (broken) symlink dies with
	# a confusing "No such file or directory" instead of ever reaching the
	# case-sensitivity gate that knows how to reattach.
	mkdir -p "$TESTDIR/root"
	ln -s "/Volumes/mackas-workspace-does-not-exist-$$" "$TESTDIR/root/work"
	: > "$TESTDIR/root/workspace.sparseimage"
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	printf '%s\n' "$output" | grep -qF 'no longer mounted'
	printf '%s\n' "$output" | grep -qF 'reattach'
	printf '%s\n' "$output" | grep -qF 'hdiutil attach'
	printf '%s\n' "$output" | grep -qF "reattached workspace image at $TESTDIR/root/work -> /Volumes/mackas-workspace"
	! printf '%s\n' "$output" | grep -qiF 'no such file or directory'
}

@test "setup: a dangling work/ symlink with NO backing image dies with a clear message" {
	# Same dangling symlink, but the image itself is also missing (moved,
	# deleted by hand, corrupted state) -- refuse with something actionable
	# rather than the raw mkdir ENOENT this bug used to produce.
	mkdir -p "$TESTDIR/root"
	ln -s "/Volumes/mackas-workspace-does-not-exist-$$" "$TESTDIR/root/work"
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'dangling symlink'
	printf '%s\n' "$output" | grep -qF 'no workspace image exists'
	! printf '%s\n' "$output" | grep -qiF 'unbound variable'
}

@test "setup: a pre-existing work/ checkout is moved aside before the image is offered" {
	# Real content already sitting in work/ (predates this gate, or a
	# hand-set-up root) must never be silently shadowed by the new mount.
	mkdir -p "$TESTDIR/root/work/some-layer"
	: > "$TESTDIR/root/work/some-layer/a-real-file"
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	printf '%s\n' "$output" | grep -qF 'moved the existing work/ aside'
	printf '%s\n' "$output" | grep -qF 'work.pre-workspace-'
	printf '%s\n' "$output" | grep -qF 'rsync -a'
	printf '%s\n' "$output" | grep -qF 'copied the preserved checkout'
}

@test "setup: MACKAS_REQUIRE_CASE_SENSITIVE=0 is the explicit escape hatch" {
	# Same case-insensitive root, gate explicitly disabled: must NOT hit the
	# case-sensitivity die. (It may still fail/stop for unrelated dry-run
	# reasons; the point is which failure, if any, this specific one is absent.)
	MACKAS_REQUIRE_CASE_SENSITIVE=0 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$TESTDIR/root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	! printf '%s\n' "$output" | grep -qF 'CASE-INSENSITIVE filesystem'
}

@test "setup: a case-sensitive root is not refused" {
	# Probe for a real case-sensitive volume on THIS host rather than assume
	# one exists (CI/other Macs may have none) -- skip rather than false-fail.
	local cs_root="" d t
	for d in /Volumes/*; do
		[ -d "$d" ] && [ -w "$d" ] || continue
		t="$(mktemp -d "$d/.mackas-cstest.XXXXXX" 2>/dev/null)" || continue
		: > "$t/x" 2>/dev/null
		if [ ! -e "$t/X" ]; then cs_root="$d"; fi
		rm -rf "$t"
		[ -n "$cs_root" ] && break
	done
	[ -n "$cs_root" ] || skip "no writable case-sensitive volume found on this host"

	local root="$cs_root/mackas-cstest-$$"
	MACKAS_REQUIRE_CASE_SENSITIVE=1 run "$MACKAS" --dry-run -y \
		--set "MACKAS_ROOT=$root" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		setup
	! printf '%s\n' "$output" | grep -qF 'CASE-INSENSITIVE filesystem'
	rm -rf "$root" 2>/dev/null
}
