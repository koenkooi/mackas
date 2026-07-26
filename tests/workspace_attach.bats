#!/usr/bin/env bats
#
# The fail-closed workspace-image attach guard (TODO item 19, phase 1).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# What this guards, in one sentence: `hdiutil attach` does not survive a
# reboot, so a Mac that restarts leaves $MACKAS_ROOT/work as an ordinary EMPTY
# directory on the (case-insensitive) drive -- and if a build falls through to
# it, kas re-clones oe-core onto case-insensitive APFS, which is exactly the
# corruption the setup-time gate exists to prevent, silent this time because
# that gate already passed. So "cannot attach" must mean "refuse to build",
# never "carry on".
#
# Hermetic: hdiutil is stubbed. tests/workspace_image_real.bats covers the
# same mechanism against a REAL hdiutil, opt-in behind MACKAS_REAL_RUNTIME=1.
#
# NOTE: bats' own `run` helper must not be used in the lib-mode tests here --
# mackas defines a run() of its own and sourcing the script shadows bats'
# version (same reason/pattern as check_discard_support.bats and units.bats).
# Exit status is captured with an explicit `set +e` + command substitution.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	export HOME="$TESTDIR"          # record_workspace_image writes ~/.mackas.conf
	unset MACKAS_CONF MACKAS_ROOT MACKAS_WORKSPACE_IMAGE

	# Stub hdiutil. The mount point it reports must contain "/Volumes/",
	# because attach_workspace_image() parses hdiutil's real table output by
	# picking the line that has one -- so the fake mount lives under
	# $TESTDIR/Volumes rather than being an arbitrary tmp path.
	FAKE_MOUNT="$TESTDIR/Volumes/mackas-workspace"
	HDIUTIL_LOG="$TESTDIR/hdiutil.log"
	export FAKE_MOUNT HDIUTIL_LOG
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/hdiutil" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HDIUTIL_LOG"
if [ "$1" = "attach" ]; then
	[ -f "$2" ] || { echo "hdiutil: attach failed - no such file or directory"; exit 1; }
	if [ -n "${FAKE_HDIUTIL_ATTACH_FAILS:-}" ]; then
		echo "hdiutil: attach failed - insufficient privileges"; exit 1
	fi
	mkdir -p "$FAKE_MOUNT"
	printf '/dev/disk9\tGUID_partition_scheme\t\n'
	printf '/dev/disk9s1\tEFI\t\n'
	printf '/dev/disk9s2\tApple_APFS\t%s\n' "$FAKE_MOUNT"
	exit 0
fi
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/hdiutil"
	PATH="$TESTDIR/fakebin:$PATH"

	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR/root"
	MACKAS_SHORT_LINK="$TESTDIR/nonexistent-short-link-xyzzy"
	mkdir -p "$MACKAS_ROOT"
	derive_paths
	DRY_RUN=0
	ASSUME_YES=1
	VERBOSE=0
	IMG="$MACKAS_ROOT/workspace.sparseimage"
}

teardown() {
	rm -rf "$TESTDIR"
}

# An image file that hdiutil will accept. Its contents are irrelevant to the
# guard -- only its existence is ever tested on the host side.
make_image() { : > "$IMG"; }

# Pretend work/ is a mount: the guard compares st_dev of work/ against
# MACKAS_ROOT's, and a hermetic test cannot conjure a second filesystem. This
# overrides the one-line seam (path_device), never the decision logic on top
# of it -- and only in the two tests that genuinely need a mounted work/.
fake_work_is_a_mount() {
	path_device() {
		case "$1" in
			*/work) printf '4242\n' ;;
			*)      printf '1\n' ;;
		esac
	}
}

# ---------------------------------------------------------------------------
# The guard itself
# ---------------------------------------------------------------------------

@test "attach guard: no image configured is a pure no-op" {
	# The overwhelmingly common case -- a genuinely case-sensitive root -- and
	# it must cost nothing and touch nothing.
	mkdir -p "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE=""
	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -eq 0 ]
	[ -z "$out" ]
	[ ! -e "$HDIUTIL_LOG" ]
	[ -d "$MACKAS_ROOT/work" ] && [ ! -L "$MACKAS_ROOT/work" ]
}

@test "attach guard: configured but not attached -- attaches and re-points work/" {
	# The post-reboot state: the image is still on disk, work/ is the dangling
	# symlink the previous attach left behind.
	make_image
	ln -s "/Volumes/mackas-workspace-gone-$$" "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"

	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -eq 0 ]
	grep -qF "attach $IMG -nobrowse" "$HDIUTIL_LOG"
	[ "$(readlink "$MACKAS_ROOT/work")" = "$FAKE_MOUNT" ]
	printf '%s\n' "$out" | grep -qF 'reattach'
}

@test "attach guard: the attach writes the sentinel at the image root" {
	make_image
	ln -s "/Volumes/mackas-workspace-gone-$$" "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	ensure_workspace_attached >/dev/null 2>&1
	[ -f "$FAKE_MOUNT/.mackas-workspace" ]
	# Its content is never parsed, only its presence -- but it must explain
	# itself to whoever finds it in a directory listing.
	grep -qi 'do not delete' "$FAKE_MOUNT/.mackas-workspace"
}

@test "attach guard: already attached -- skips, without calling hdiutil at all" {
	make_image
	mkdir -p "$MACKAS_ROOT/work"
	: > "$MACKAS_ROOT/work/.mackas-workspace"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	fake_work_is_a_mount

	local rc; set +e; ensure_workspace_attached >/dev/null 2>&1; rc=$?; set -e
	[ "$rc" -eq 0 ]
	[ ! -e "$HDIUTIL_LOG" ]
	# Idempotent in the ensure_volume sense: still a plain directory, not
	# rm -rf'd and replaced by a symlink.
	[ ! -L "$MACKAS_ROOT/work" ]
}

@test "attach guard: a mount that is NOT ours (no sentinel) is refused, not mounted over" {
	# Some other volume happened to land on work/ -- a leftover DMG, a USB
	# stick, a second workspace image. st_dev alone would read that as
	# "attached, carry on" and hand bitbake a filesystem nobody vetted; worse,
	# reattaching over it would rm -rf the contents of someone else's mount.
	make_image
	mkdir -p "$MACKAS_ROOT/work"
	: > "$MACKAS_ROOT/work/somebody-elses-file"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	fake_work_is_a_mount

	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF '.mackas-workspace'
	[ ! -e "$HDIUTIL_LOG" ]
	[ -f "$MACKAS_ROOT/work/somebody-elses-file" ]
}

@test "attach guard: a MISSING image file dies rather than proceeding" {
	# Drive unplugged, image moved or deleted by hand. Falling through here is
	# the whole bug: work/ is a perfectly ordinary case-insensitive directory
	# and the build would succeed at first.
	MACKAS_WORKSPACE_IMAGE="$MACKAS_ROOT/gone.sparseimage"
	mkdir -p "$MACKAS_ROOT/work"

	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF 'does not exist'
	printf '%s\n' "$out" | grep -qF 'mdfind'
	[ ! -L "$MACKAS_ROOT/work" ]
}

@test "attach guard: an UNATTACHABLE image dies rather than proceeding" {
	make_image
	ln -s "/Volumes/mackas-workspace-gone-$$" "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"

	local out; set +e
	out="$(FAKE_HDIUTIL_ATTACH_FAILS=1 ensure_workspace_attached 2>&1)"
	local rc=$?; set -e
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qF 'hdiutil attach failed'
	# work/ must be left exactly as it was -- still the dangling symlink, never
	# a fresh empty directory a later command could write into.
	[ -L "$MACKAS_ROOT/work" ]
	[ "$(readlink "$MACKAS_ROOT/work")" != "$FAKE_MOUNT" ]
}

@test "attach guard: a NON-EMPTY plain work/ is refused, and its contents survive" {
	# Something already wrote checkouts onto the case-insensitive drive while
	# the image was detached. That content may be corrupt, but it is the
	# user's -- refuse and explain; never rm -rf it to make room for the mount.
	make_image
	mkdir -p "$MACKAS_ROOT/work/oe-core"
	: > "$MACKAS_ROOT/work/oe-core/precious"
	MACKAS_WORKSPACE_IMAGE="$IMG"

	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'non-empty directory'
	printf '%s\n' "$out" | grep -qF 'setup'
	[ -f "$MACKAS_ROOT/work/oe-core/precious" ]
	[ ! -e "$HDIUTIL_LOG" ]
}

@test "attach guard: --dry-run mutates nothing" {
	make_image
	ln -s "/Volumes/mackas-workspace-gone-$$" "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	DRY_RUN=1

	local out; set +e; out="$(ensure_workspace_attached 2>&1)"; local rc=$?; set -e
	[ "$rc" -eq 0 ]
	printf '%s\n' "$out" | grep -qF 'hdiutil attach'
	printf '%s\n' "$out" | grep -qF -- '-nobrowse'
	# Nothing executed: no real hdiutil call, no re-pointed symlink, no
	# sentinel, no config file written.
	[ ! -e "$HDIUTIL_LOG" ]
	[ "$(readlink "$MACKAS_ROOT/work")" = "/Volumes/mackas-workspace-gone-$$" ]
	[ ! -e "$FAKE_MOUNT/.mackas-workspace" ]
	[ ! -e "$HOME/.mackas.conf" ]
}

# ---------------------------------------------------------------------------
# The recorded setting
# ---------------------------------------------------------------------------

@test "attach guard: attaching records MACKAS_WORKSPACE_IMAGE in the config file" {
	# Without the record, the NEXT run has no way to know work/ was ever
	# supposed to be a mount -- the knob is the whole lifecycle.
	make_image
	ln -s "/Volumes/mackas-workspace-gone-$$" "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE=""
	CONFIG_FILE_USED=""
	reattach_workspace_image "$IMG" >/dev/null 2>&1

	[ -f "$HOME/.mackas.conf" ]
	grep -qF "MACKAS_WORKSPACE_IMAGE='$IMG'" "$HOME/.mackas.conf"
	[ "$MACKAS_WORKSPACE_IMAGE" = "$IMG" ]
}

@test "MACKAS_WORKSPACE_IMAGE: is a real setting, settable and defaulting to empty" {
	is_setting_name MACKAS_WORKSPACE_IMAGE
	set_defaults
	[ -z "$MACKAS_WORKSPACE_IMAGE" ]
}

# ---------------------------------------------------------------------------
# Reporting: check and status only LOOK -- they never attach
# ---------------------------------------------------------------------------

@test "check: reports a configured-but-detached workspace image as a FAIL" {
	make_image
	mkdir -p "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"

	local out; out="$(check_target_volume 2>&1)"
	printf '%s\n' "$out" | grep -F 'workspace image' | grep -qF '[FAIL]'
	printf '%s\n' "$out" | grep -qF 'NOT attached'
	# check creates nothing and mounts nothing, ever.
	[ ! -e "$HDIUTIL_LOG" ]
	[ ! -L "$MACKAS_ROOT/work" ]
}

@test "check: reports a missing image file distinctly from a detached one" {
	MACKAS_WORKSPACE_IMAGE="$MACKAS_ROOT/gone.sparseimage"
	mkdir -p "$MACKAS_ROOT/work"
	local out; out="$(check_target_volume 2>&1)"
	printf '%s\n' "$out" | grep -qF 'no such file exists'
	[ ! -e "$HDIUTIL_LOG" ]
}

@test "check: an attached image PASSes, and says nothing when none is configured" {
	make_image
	mkdir -p "$MACKAS_ROOT/work"
	: > "$MACKAS_ROOT/work/.mackas-workspace"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	fake_work_is_a_mount
	local out; out="$(check_target_volume 2>&1)"
	printf '%s\n' "$out" | grep -F 'workspace image' | grep -qF '[PASS]'

	MACKAS_WORKSPACE_IMAGE=""
	out="$(check_target_volume 2>&1)"
	! printf '%s\n' "$out" | grep -qF 'workspace image'
}

@test "status: shows the image and whether it is attached, without attaching it" {
	make_image
	mkdir -p "$MACKAS_ROOT/work"
	MACKAS_WORKSPACE_IMAGE="$IMG"
	local out; out="$(cmd_status 2>&1)"
	printf '%s\n' "$out" | grep -qF 'Workspace image'
	printf '%s\n' "$out" | grep -qF "$IMG"
	printf '%s\n' "$out" | grep -A3 'Workspace image' | grep -qF 'attached'
	[ ! -e "$HDIUTIL_LOG" ]
}

# ---------------------------------------------------------------------------
# Wired into the real commands (whole-binary, still hermetic: the guard dies
# before anything reaches hdiutil or the container runtime)
# ---------------------------------------------------------------------------

@test "shell/smoketest: refuse to run when the configured image cannot be attached" {
	local cmd out rc
	for cmd in shell smoketest; do
		set +e
		# MACKAS_LIB_ONLY=0: setup() exported it as 1 to source the script
		# here, and the child would otherwise define its functions and exit
		# without ever running main().
		out="$(MACKAS_LIB_ONLY=0 "$MACKAS" -y \
			--set "MACKAS_ROOT=$MACKAS_ROOT" \
			--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
			--set "MACKAS_WORKSPACE_IMAGE=$MACKAS_ROOT/gone.sparseimage" \
			"$cmd" 2>&1)"
		rc=$?
		set -e
		[ "$rc" -ne 0 ]
		printf '%s\n' "$out" | grep -qF 'does not exist'
		# It must be THIS refusal, not a later, murkier one.
		! printf '%s\n' "$out" | grep -qF 'kas-container not installed'
		! printf '%s\n' "$out" | grep -qiF 'unbound variable'
	done
}
