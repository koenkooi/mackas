#!/usr/bin/env bats
#
# Tests for the commands that manage the three ext4 volumes -- setup, clean and
# destroy -- and for what mackas actually hands to kas-container.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas` as a subprocess with a fake `container` (and, where it
# matters, a fake `kas-container`) on PATH, both of which record their argv.
# Nothing here touches the real Apple container runtime, the build SSD or the
# network -- the fakes are the only engine present.
#
# Contrast with volumes.bats, which sources mackas with MACKAS_LIB_ONLY=1 to
# test the pure string-building. This file is about the commands.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	CLOG="$TESTDIR/container.log"
	export CLOG

	# A `container` that records every invocation, one argument per line, and
	# keeps a real (if tiny) notion of which volumes exist: `volume create`
	# adds one, `volume delete` removes one, `volume ls` lists them. A static
	# list would lie to any command that deletes and recreates in one run --
	# `clean` does exactly that.
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"

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
		;;
	"volume create")
		# ... -s SIZE NAME
		eval "name=\${$#}"
		printf '%s\n' "$name" >> "$VSTATE"
		;;
	"volume delete"|"volume rm")
		# MOCK_UNDELETABLE names a volume that refuses to go, under BOTH
		# spellings of the subcommand -- which is what a busy volume really
		# does. It stays in VSTATE, so a later `volume ls` still reports it as
		# present, exactly as the real engine would.
		if [ -n "${MOCK_UNDELETABLE:-}" ] && [ "$3" = "$MOCK_UNDELETABLE" ]; then
			echo "mock: volume '$3' is in use by a running container" >&2
			exit 1
		fi
		grep -vxF "$3" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		# Mirror reality: the runtime also removes the volume's on-disk
		# directory (under the container volumes dir, which may be a symlink
		# onto the SSD). Foreign volumes and undeletable ones stay put.
		rm -rf "$HOME/Library/Application Support/com.apple.container/volumes/$3" 2>/dev/null || true
		;;
	"system status") echo "status running" ;;
	"image ls")
		# MOCK_NO_IMAGE simulates a fresh machine where the kas image has not
		# been pulled yet, so `check` must not boot-probe (which auto-fetches).
		echo "NAME TAG"
		[ -n "${MOCK_NO_IMAGE:-}" ] || echo "ghcr.io/siemens/kas/kas 5.4"
		;;
	"--version "*|"--version") echo "container CLI version 1.1.0" ;;
	"ls "*|"ls")
		# Running containers. MOCK_INUSE names a volume whose backing build is
		# still up: it shows one running container, and `inspect` below reports
		# that container as mounting the named volume.
		echo "ID"
		[ -n "${MOCK_INUSE:-}" ] && echo "runner1"
		;;
	"inspect "*)
		[ -n "${MOCK_INUSE:-}" ] && printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_INUSE"
		;;
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

# Seed the fake engine: these volumes already exist.
have_volumes() {
	printf '%s\n' "$@" > "$VSTATE"
}

mackas_setup() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

# Assert the container mock was called with a line containing $1.
assert_call() {
	if ! grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected a `container` call containing:\n  %s\n--- calls made ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

refute_call() {
	if grep -qF -- "$1" "$CLOG" 2>/dev/null; then
		printf 'expected NO `container` call containing:\n  %s\n--- calls made ---\n%s\n' \
			"$1" "$(cat "$CLOG" 2>/dev/null)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# setup creates and chowns all three volumes
# ---------------------------------------------------------------------------

@test "setup: creates three volumes at their configured sizes" {
	mackas_setup setup
	assert_call "[volume] [create] [-s] [120G] [oe-build-tmp]"
	assert_call "[volume] [create] [-s] [40G] [oe-build-dl]"
	assert_call "[volume] [create] [-s] [40G] [oe-build-sstate]"
}

@test "setup: chowns each fresh volume to the invoking user, as root (bug 3 + bug 4)" {
	# A fresh ext4 volume's root is root:root -- real Linux ownership, not
	# masked by virtiofs as a bind mount would be. kas drops to USER_ID and
	# then cannot create /build/CACHEDIR.TAG. One chown at create time fixes
	# it forever -- PROVIDED the chown itself can run: the kas image's default
	# user is uid 30000 (builder), which cannot chown anything, so the chown
	# container run must add -u 0:0 or it dies with "Operation not permitted".
	want="$(id -u):$(id -g)"
	mackas_setup setup
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-dl:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-sstate:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
}

@test "setup: chowns volumes that ALREADY existed too, not only ones it just created (bug 4)" {
	# Regression guard for the fix in this commit: a crash (or a failing
	# chown) between `volume create` and the chown used to leave a
	# root-owned volume that 'exists', so the old code -- which chowned only
	# in the 'just created' branch -- would skip it forever. The chown is
	# idempotent, so it must run unconditionally, every 'setup', existing
	# volumes included.
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	want="$(id -u):$(id -g)"
	mackas_setup setup
	refute_call "[volume] [create]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-dl:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-sstate:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
}

@test "setup: the chown is computed, never a hardcoded uid:gid" {
	# Asserted against the SOURCE, not the mock's argv, and deliberately so:
	# `id -u`:`id -g` on the developer's own machine is some concrete pair, so
	# an argv assertion would pass just as happily against a hardcoded literal
	# of that pair and prove nothing. Grepping the source is the only honest way
	# to catch it without a second uid to run as.
	! grep -nE 'chown[^|]*\b[0-9]+:[0-9]+' "$MACKAS"
	grep -qF 'chown "$(id -u):$(id -g)" /mnt' "$MACKAS"
}

@test "setup: the chown container run runs as root (bug 4: builder uid 30000 cannot chown)" {
	# Asserted against the SOURCE for the same reason as the test above: this
	# machine's uid is not 0, so an argv assertion that merely matched "-u 0:0
	# appears somewhere" could not distinguish "present and correct" from
	# "present on the wrong command". Pin it to the exact invocation. It is now
	# the argument to spin() (elapsed feedback for the VM boot) rather than to
	# run(), but the -u 0:0 chown itself is verbatim.
	grep -qF 'container run --rm -u 0:0 -v "$name:/mnt" "$KAS_IMAGE" chown "$(id -u):$(id -g)" /mnt' "$MACKAS"
	# ...and it really is wrapped in spin, not left as a bare/`run` call.
	grep -qF 'spin "chowning' "$MACKAS"
}

@test "setup: does not recreate volumes that already exist" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mackas_setup setup
	refute_call "[volume] [create]"
}

# ---------------------------------------------------------------------------
# A7: attaching a busy volume is a SECOND attach. The runtime refuses it, and
# under set -e that aborts the whole command. setup's chown and check's
# ownership probe both attach, so both must skip a volume a running build still
# holds rather than fight the one-VM rule.
# ---------------------------------------------------------------------------

@test "setup: skips the chown for a volume a running build still holds (A7)" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	want="$(id -u):$(id -g)"
	MOCK_INUSE=oe-build-tmp mackas_setup setup
	[ "$status" -eq 0 ]
	# The held volume must NOT be attached for a chown...
	refute_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	# ...but the other two still are.
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-dl:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	assert_call "[run] [--rm] [-u] [0:0] [-v] [oe-build-sstate:/mnt] [ghcr.io/siemens/kas/kas:5.4] [chown] [$want] [/mnt]"
	printf '%s\n' "$output" | grep -qi "attached to a running build; skipping the chown"
}

@test "check: reports a busy volume instead of misreading its ownership (A7)" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	MOCK_INUSE=oe-build-tmp run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 check
	# The held volume is called out, not attached...
	printf '%s\n' "$output" | grep -qi "oe-build-tmp.*attached to a running build; skipping the ownership probe"
	refute_call "[run] [--rm] [-v] [oe-build-tmp:/mnt] [ghcr.io/siemens/kas/kas:5.4] [stat]"
	# ...and it must NOT emit the old misleading warning for it.
	if printf '%s\n' "$output" | grep -qi "could not read the ownership of volume 'oe-build-tmp'"; then
		printf 'check warned about ownership of a busy volume instead of skipping:\n%s\n' "$output" >&2
		return 1
	fi
}

@test "setup: reports a leftover volume from the old single-volume scheme" {
	# Migration: the pre-split 'oe-build' volume is not used any more and a
	# stale 200G image is exactly what this disk cannot spare. Report it and
	# say how to remove it -- never delete it behind the user's back.
	have_volumes oe-build
	mackas_setup setup
	printf '%s\n' "$output" | grep -qF "container volume delete oe-build"
	refute_call "[volume] [delete] [oe-build]"
}

@test "setup: refuses a volume name containing whitespace" {
	# kas-container word-splits --runtime-args, so 'oe build:/build' would
	# become two arguments and mount something absurd.
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_VOLUME_NAME=oe build" setup
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'whitespace'
}

@test "setup: creates no host-side build/downloads/sstate directories" {
	# If these exist, someone is about to point KAS_BUILD_DIR at one and put
	# TMPDIR back on APFS. They are volumes now.
	mackas_setup setup
	[ ! -e "$ROOT/build" ]
	[ ! -e "$ROOT/downloads" ]
	[ ! -e "$ROOT/sstate" ]
}

# ---------------------------------------------------------------------------
# clean keeps the caches; destroy takes everything
# ---------------------------------------------------------------------------

@test "clean: drops the TMPDIR volume and KEEPS the cache volumes" {
	# This is the entire reason the volumes are split.
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mackas_setup clean
	assert_call "[volume] [delete] [oe-build-tmp]"
	refute_call "[volume] [delete] [oe-build-dl]"
	refute_call "[volume] [delete] [oe-build-sstate]"
}

@test "clean: recreates the TMPDIR volume, chowned, ready to build" {
	# Deleting it and stopping would leave the next build with no /build at all.
	have_volumes oe-build-tmp
	mackas_setup clean
	assert_call "[volume] [create] [-s] [120G] [oe-build-tmp]"
	assert_call "[chown] [$(id -u):$(id -g)] [/mnt]"
}

@test "destroy: removes all three volumes" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mackas_setup destroy
	assert_call "[volume] [delete] [oe-build-tmp]"
	assert_call "[volume] [delete] [oe-build-dl]"
	assert_call "[volume] [delete] [oe-build-sstate]"
}

@test "destroy: also removes a leftover volume from the old scheme" {
	have_volumes oe-build oe-build-tmp oe-build-dl oe-build-sstate
	mackas_setup destroy
	assert_call "[volume] [delete] [oe-build]"
}

@test "clean: does not remove the old-scheme volume behind the user's back" {
	have_volumes oe-build oe-build-tmp
	mackas_setup clean
	refute_call "[volume] [delete] [oe-build]"
}

# ---------------------------------------------------------------------------
# A FAILED deletion must not be reported as a success.
#
# delete_volume ended with:
#
#     run container volume delete "$name" || \
#         run container volume rm "$name" || \
#         warn "could not delete volume..."
#     did "removed volume '$name'"
#
# warn returns 0, and `did` was on its own line, so "removed volume" printed
# unconditionally -- directly after the warning saying it had not been. During
# destroy the user was told everything was gone while a busy volume, and the
# tens of gigabytes in it, quietly survived.
# ---------------------------------------------------------------------------

@test "destroy: does not claim it removed a volume that could not be removed" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	MOCK_UNDELETABLE=oe-build-sstate mackas_setup destroy
	# Both spellings were tried -- that fallback is worth keeping.
	assert_call "[volume] [delete] [oe-build-sstate]"
	assert_call "[volume] [rm] [oe-build-sstate]"
	# ...and then it must NOT say it removed it.
	if printf '%s\n' "$output" | grep -qF "removed volume 'oe-build-sstate'"; then
		printf 'destroy claimed to have removed a volume that survived:\n%s\n' "$output" >&2
		return 1
	fi
	printf '%s\n' "$output" | grep -qi "could not delete volume 'oe-build-sstate'"
}

@test "destroy: exits non-zero when a volume survives" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	MOCK_UNDELETABLE=oe-build-sstate mackas_setup destroy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'survive'
	# And it must say what to do next, like every other failure here.
	printf '%s\n' "$output" | grep -q 'next:'
}

@test "destroy: still reports the volumes it DID remove" {
	# The fix must not swing the other way and go silent on success.
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	MOCK_UNDELETABLE=oe-build-sstate mackas_setup destroy
	printf '%s\n' "$output" | grep -qF "removed volume 'oe-build-tmp'"
	printf '%s\n' "$output" | grep -qF "removed volume 'oe-build-dl'"
}

@test "destroy: succeeds and reports every volume when all deletions work" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mackas_setup destroy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "removed volume 'oe-build-tmp'"
	printf '%s\n' "$output" | grep -qF "removed volume 'oe-build-sstate'"
}

# ---------------------------------------------------------------------------
# A1 [CRITICAL -- data loss]: with MACKAS_RELOCATE_VOLUMES=1 the container
# volumes dir is a symlink onto $MACKAS_ROOT, so the LIVE backing images live
# inside $MACKAS_ROOT/container-volumes -- including any FOREIGN volumes that
# setup_relocate_volumes rsync'd in. destroy used to remove that symlink and
# rm -rf $MACKAS_ROOT BEFORE checking whether every volume actually went, so a
# single undeletable (busy) volume meant rm -rf erased its live image, and the
# foreign volumes with it. The survivor check must run first and abort.
# ---------------------------------------------------------------------------

# Drive destroy with relocation ON, as a real relocated install would be.
mackas_reloc() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=1 "$@"
}

# Build the relocated layout: real dir on the "SSD", symlinked from the
# container volumes dir, holding our three volumes plus one FOREIGN volume.
seed_relocated() {
	CVDIR="$HOME/Library/Application Support/com.apple.container/volumes"
	RELOC="$ROOT/container-volumes"
	export CVDIR RELOC
	local v
	for v in oe-build-tmp oe-build-dl oe-build-sstate foreign-vol; do
		mkdir -p "$RELOC/$v"
		: > "$RELOC/$v/volume.img"
	done
	mkdir -p "$(dirname "$CVDIR")"
	ln -s "$RELOC" "$CVDIR"
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
}

@test "destroy: aborts before rm -rf when a relocated volume survives (A1)" {
	seed_relocated
	MOCK_UNDELETABLE=oe-build-sstate mackas_reloc destroy
	# It refuses, loudly, and points somewhere useful.
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'survive'
	printf '%s\n' "$output" | grep -qi 'refusing to remove'
	printf '%s\n' "$output" | grep -q 'next:'
	# NOTHING destructive happened: the symlink, $MACKAS_ROOT, the surviving
	# volume's live image and the FOREIGN volume are all still there.
	[ -L "$CVDIR" ]
	[ -d "$ROOT" ]
	[ -e "$RELOC/oe-build-sstate/volume.img" ]
	[ -e "$RELOC/foreign-vol/volume.img" ]
	# It must have aborted BEFORE the symlink-restore / foreign-move stage.
	if printf '%s\n' "$output" | grep -qiE 'restored .* to a real directory|foreign volume'; then
		printf 'destroy reached the symlink-restore stage despite a survivor:\n%s\n' "$output" >&2
		return 1
	fi
}

@test "destroy: moves foreign volumes back before removing MACKAS_ROOT (A1)" {
	# Happy path with relocation: all OUR volumes delete, but a foreign volume
	# remains in the relocated dir. destroy must move it back to the internal
	# disk, never rm -rf it along with $MACKAS_ROOT.
	seed_relocated
	mackas_reloc destroy
	[ "$status" -eq 0 ]
	# MACKAS_ROOT is gone...
	[ ! -d "$ROOT" ]
	# ...the symlink was replaced by a real directory...
	[ ! -L "$CVDIR" ]
	[ -d "$CVDIR" ]
	# ...and the FOREIGN volume survived, on the internal disk.
	[ -e "$CVDIR/foreign-vol/volume.img" ]
	printf '%s\n' "$output" | grep -qi 'foreign volume'
}

@test "destroy: restores an EMPTY relocated dir to a plain directory (A1)" {
	# Relocation on, but no foreign volumes: after our three delete, the dir is
	# empty. It should become a plain empty directory again, and MACKAS_ROOT go.
	CVDIR="$HOME/Library/Application Support/com.apple.container/volumes"
	RELOC="$ROOT/container-volumes"
	local v
	for v in oe-build-tmp oe-build-dl oe-build-sstate; do
		mkdir -p "$RELOC/$v"; : > "$RELOC/$v/volume.img"
	done
	mkdir -p "$(dirname "$CVDIR")"
	ln -s "$RELOC" "$CVDIR"
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	mackas_reloc destroy
	[ "$status" -eq 0 ]
	[ ! -d "$ROOT" ]
	[ ! -L "$CVDIR" ]
	[ -d "$CVDIR" ]
	printf '%s\n' "$output" | grep -qi 'restored .* to a real directory'
}

@test "clean: refuses to report a cleaned TMPDIR when the volume would not go" {
	# clean deletes and recreates. If the delete fails, ensure_volume finds
	# the volume still there, skips creating it, and the old contents are
	# still in it -- so "cleaned TMPDIR" would be a lie.
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	MOCK_UNDELETABLE=oe-build-tmp mackas_setup clean
	[ "$status" -ne 0 ]
	if printf '%s\n' "$output" | grep -qi 'cleaned TMPDIR'; then
		printf 'clean claimed success over a volume that survived:\n%s\n' "$output" >&2
		return 1
	fi
	printf '%s\n' "$output" | grep -q 'next:'
}

# ---------------------------------------------------------------------------
# A3: `check` is documented "Preflight only. Changes nothing." Apple's
# `container run` AUTO-FETCHES a missing image (~1GB), so the kernel boot probe
# must be gated on image_present -- otherwise `check` on a fresh machine
# silently downloads the whole kas image.
# ---------------------------------------------------------------------------

mackas_check() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 check
}

@test "check: does not boot-probe (auto-pull) a missing image (A3)" {
	MOCK_NO_IMAGE=1 mackas_check
	# The boot probe would fetch the image; with it absent, it must be skipped.
	refute_call "[run] [--rm] [ghcr.io/siemens/kas/kas:5.4] [true]"
	printf '%s\n' "$output" | grep -qi 'kernel not probed'
}

@test "check: DOES boot-probe when the image is already present (A3)" {
	# The gate must not suppress the probe when the image is there -- that is
	# the case it exists to check.
	mackas_check
	assert_call "[run] [--rm] [ghcr.io/siemens/kas/kas:5.4] [true]"
}

# ---------------------------------------------------------------------------
# What reaches kas-container
# ---------------------------------------------------------------------------

# Stand a fake kas-container in place of the real one and have `shell` invoke
# it. It records its argv AND the three environment variables that decide
# whether kas bind-mounts a host directory over our volumes.
install_fake_kas() {
	mkdir -p "$ROOT/bin" "$ROOT/work/meta-ai/.git" "$ROOT/work/meta-ai/kas"
	touch "$ROOT/work/meta-ai/kas/macos-local.yml"
	cat > "$ROOT/bin/kas-container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'ARGV:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
	printf 'ENV:KAS_BUILD_DIR=[%s]\n' "${KAS_BUILD_DIR-<unset>}"
	printf 'ENV:DL_DIR=[%s]\n' "${DL_DIR-<unset>}"
	printf 'ENV:SSTATE_DIR=[%s]\n' "${SSTATE_DIR-<unset>}"
	printf 'ENV:KAS_EXTRA_RUNTIME_ARGS=[%s]\n' "${KAS_EXTRA_RUNTIME_ARGS-<unset>}"
	printf 'ENV:KAS_CONTAINER_IMAGE=[%s]\n' "${KAS_CONTAINER_IMAGE-<unset>}"
	printf 'ENV:GITCONFIG_FILE=[%s]\n' "${GITCONFIG_FILE-<unset>}"
} >> "$KLOG"
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container"
	KLOG="$TESTDIR/kas.log"
	export KLOG
}

@test "shell: passes the volumes and limits via --runtime-args, not the environment" {
	install_fake_kas
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_CPUS=6 --set MACKAS_MEMORY=12g shell
	[ "$status" -eq 0 ]
	grep -qF -- '[--runtime-args] [-c 6 -m 12g -v oe-build-tmp:/build -e KAS_BUILD_DIR=/build -v oe-build-dl:/downloads -e DL_DIR=/downloads -v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate]' "$KLOG"
}

@test "shell: leaves KAS_BUILD_DIR/DL_DIR/SSTATE_DIR empty in kas' environment (bug 1)" {
	# kas-container's forward_dir() bind-mounts whatever host directory these
	# name, and returns early only when they are EMPTY. A non-empty value here
	# is TMPDIR back on APFS/virtiofs.
	install_fake_kas
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF 'ENV:KAS_BUILD_DIR=[]' "$KLOG"
	grep -qxF 'ENV:DL_DIR=[]' "$KLOG"
	grep -qxF 'ENV:SSTATE_DIR=[]' "$KLOG"
}

@test "shell: a stale KAS_BUILD_DIR in the user's environment cannot leak through" {
	# Sourcing an old env.sh must not silently put TMPDIR back on APFS.
	install_fake_kas
	mkdir -p "$TESTDIR/apfs"
	KAS_BUILD_DIR="$TESTDIR/apfs" DL_DIR="$TESTDIR/apfs" SSTATE_DIR="$TESTDIR/apfs" \
		run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF 'ENV:KAS_BUILD_DIR=[]' "$KLOG"
	! grep -qF "$TESTDIR/apfs" "$KLOG"
}

@test "shell: does not set KAS_EXTRA_RUNTIME_ARGS (bug 2: kas blanks it anyway)" {
	install_fake_kas
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF 'ENV:KAS_EXTRA_RUNTIME_ARGS=[<unset>]' "$KLOG"
}

@test "shell: pins the image with its tag" {
	install_fake_kas
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF 'ENV:KAS_CONTAINER_IMAGE=[ghcr.io/siemens/kas/kas:5.4]' "$KLOG"
}

@test "shell: forwards GITCONFIG_FILE pointing at the generated gitconfig (bug 5: dubious ownership)" {
	# THE blocker: without this, git inside the container refuses /repo with
	# "detected dubious ownership", and kas's get_root_path() silently falls
	# back to the wrong directory instead of failing loudly. kas-container
	# only forwards GITCONFIG_FILE if it names a file that exists, so this
	# also proves 'setup' must run first for the real thing to work -- this
	# test only pins that mackas PASSES the variable, not that the file exists.
	install_fake_kas
	unset GITCONFIG_FILE
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF "ENV:GITCONFIG_FILE=[$ROOT/gitconfig]" "$KLOG"
}

@test "shell: a GITCONFIG_FILE already in the environment is forwarded as-is, never overridden" {
	# setup_gitconfig() never overwrites a GITCONFIG_FILE the user already
	# has; run_kas() must honour that same rule when it invokes kas-container.
	install_fake_kas
	GITCONFIG_FILE="$TESTDIR/mine.gitconfig" \
		run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 shell
	grep -qxF "ENV:GITCONFIG_FILE=[$TESTDIR/mine.gitconfig]" "$KLOG"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status: shows all three volumes and the effective runtime args" {
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'oe-build-tmp'
	printf '%s\n' "$output" | grep -q 'oe-build-dl'
	printf '%s\n' "$output" | grep -q 'oe-build-sstate'
	printf '%s\n' "$output" | grep -qF -- '-e KAS_BUILD_DIR=/build'
}

@test "status: says <none> when no docker resolves, and names it when one does" {
	# The old form was `$(resolved_docker || echo '<none>')`, and
	# resolved_docker ends in `|| true` -- so it always exits 0, the fallback
	# could never fire, and a missing docker printed an empty value instead.
	#
	# PATH here is fakebin plus the system tool directories only: mackas needs
	# awk/sed/id to run at all, but this machine's real docker lives in
	# /usr/local/bin, which is deliberately left out.
	have_volumes oe-build-tmp
	local nodocker="$TESTDIR/fakebin:/usr/bin:/bin"

	PATH="$nodocker" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE 'docker resolves to +<none>'

	# ...and with a docker on PATH it must name that instead of <none>.
	: > "$TESTDIR/fakebin/docker"
	chmod +x "$TESTDIR/fakebin/docker"
	PATH="$nodocker" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/fakebin/docker"
	! printf '%s\n' "$output" | grep -qE 'docker resolves to +<none>'
}

@test "status: flags a leftover volume from the old scheme" {
	have_volumes oe-build
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" status
	printf '%s\n' "$output" | grep -qF "container volume delete oe-build"
}
