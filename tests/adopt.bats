#!/usr/bin/env bats
#
# Tests for `mackas adopt <path>` -- bringing a foreign MACKAS_ROOT (another
# Mac's mackas set it up) back to a working build on THIS Mac.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hermetic seams, the same ones setup_e2e.bats already established: a fake
# `container` on PATH (system up, everything else a recorded no-op, nothing
# running); a fake `curl` that writes a recorder kas-container to the
# download path; a fake `shasum` that reports the pinned sum so the sha256
# gate passes; a real local `git init` fixture repo, cloned by real git.
# Nothing here touches the real Apple container runtime, the network, or the
# build SSD.
#
# The per-volume-placement tests at the bottom add two more seams, both of
# which stay dormant for every other test here: the fake `container` models the
# apiserver's index only being (re)built at `system start` (and records its
# argv when MOCK_CONTAINER_LOG is set), and `mdfind` is replaced via the
# MACKAS_MDFIND seam so `volume recover` searches the test tree instead of the
# real Spotlight index.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN MACKAS_FSTRIM_AUTO
	export HOME="$TESTDIR"

	FOREIGN="$TESTDIR/foreign-oe"
	PINNED_SHA="$(grep '^KAS_CONTAINER_SHA256=' "$MACKAS" | cut -d'"' -f2)"

	# A real local fixture repo, cloned by real git as the adopted project.
	FIXTURE="$TESTDIR/fixture.git"
	mkdir -p "$FIXTURE"
	(
		cd "$FIXTURE"
		git init -q -b testbranch
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		mkdir kas
		echo "# base layer stub" > kas/base.yml
		git add -A
		git -c user.email=t@t -c user.name=t commit -q -m base
	)

	mkdir -p "$TESTDIR/fakebin"

	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
[ -n "${MOCK_CONTAINER_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_CONTAINER_LOG"
case "$1" in --version) echo "container CLI 0.0-fake"; exit 0 ;; esac
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"system stop") exit 0 ;;
	"system start")
		# The real apiserver scans volumes/*/entity.json into its in-memory
		# index once, at ITS OWN startup, so a volume tree carried in from
		# another Mac is invisible until it restarts (refuse_if_stale_entity's
		# whole reason to exist). Model that: after a restart, and only then,
		# what is on disk shows up in 'volume ls' too.
		: > "$HOME/.fake-container-restarted"
		exit 0
		;;
	"image ls")      echo "NAME TAG"; exit 0 ;;
	"volume ls")
		echo "NAME"
		for v in ${MOCK_EXISTING_VOLUMES:-}; do echo "$v"; done
		if [ -f "$HOME/.fake-container-restarted" ]; then
			for e in "$HOME/Library/Application Support/com.apple.container/volumes"/*/entity.json; do
				[ -f "$e" ] || continue
				basename "$(dirname "$e")"
			done
		fi
		exit 0
		;;
	"container ls"|"ls "*|"ls") echo "ID"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"

	cat > "$TESTDIR/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$out" ] || exit 1
cat > "$out" <<'REC'
#!/usr/bin/env bash
exit 0
REC
EOF
	chmod +x "$TESTDIR/fakebin/curl"

	cat > "$TESTDIR/fakebin/shasum" <<EOF
#!/usr/bin/env bash
f="\${@: -1}"
printf '%s  %s\n' "$PINNED_SHA" "\$f"
EOF
	chmod +x "$TESTDIR/fakebin/shasum"

	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# A foreign root with exactly one checkout under work/, cloned for real from
# the local fixture -- a genuine .git, no fake.
make_foreign_root_with_project() {
	mkdir -p "$FOREIGN/work" "$FOREIGN/bin"
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-ai"
}

mk() {
	run "$MACKAS" -y \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_CPUS=6 \
		--set MACKAS_MEMORY=12g \
		"$@"
}

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

@test "adopt: refuses a path that does not look like a mackas root" {
	mkdir -p "$TESTDIR/just-a-dir"
	mk adopt "$TESTDIR/just-a-dir"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not look like a mackas root'
}

@test "adopt: refuses a path that is already this Mac's own MACKAS_ROOT" {
	make_foreign_root_with_project
	mk --set "MACKAS_ROOT=$FOREIGN" adopt "$FOREIGN"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'already this Mac'\''s own MACKAS_ROOT'
}

@test "adopt: refuses a nonexistent path" {
	mk adopt "$TESTDIR/does-not-exist"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a directory'
}

@test "adopt: with no path at all, refuses with a clear usage error" {
	mk adopt
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a path'
}

# ---------------------------------------------------------------------------
# Project introspection
# ---------------------------------------------------------------------------

@test "adopt: introspects the single checkout's remote URL and branch" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "project    : meta-ai"
	printf '%s\n' "$output" | grep -qF "url      : $FIXTURE"
	printf '%s\n' "$output" | grep -qF "branch   : testbranch"
	grep -qxF "MACKAS_PROJECT_URL='$FIXTURE'" "$TESTDIR/newconfig.conf"
	grep -qxF "MACKAS_PROJECT_BRANCH='testbranch'" "$TESTDIR/newconfig.conf"
	grep -qxF "MACKAS_PROJECT_DIR='meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: zero checkouts under work/ adopts infra only, no project" {
	mkdir -p "$FOREIGN/work" "$FOREIGN/bin"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'adopting infra only'
	! grep -q "MACKAS_PROJECT_URL" "$TESTDIR/newconfig.conf"
	printf '%s\n' "$output" | grep -qi 'no project configured'
}

@test "adopt: more than one checkout requires --project-dir" {
	make_foreign_root_with_project
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-second"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs to know which one'
	printf '%s\n' "$output" | grep -qF 'meta-ai'
	printf '%s\n' "$output" | grep -qF 'meta-second'
}

@test "adopt: --project-dir picks one of several checkouts explicitly" {
	make_foreign_root_with_project
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-second"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf" --project-dir meta-second
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_PROJECT_DIR='meta-second'" "$TESTDIR/newconfig.conf"
}

@test "adopt: --project-dir naming a nonexistent checkout is refused" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf" --project-dir nope
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'no git checkout at'
}

# ---------------------------------------------------------------------------
# Distinct identity: volume name and short link never collide
# ---------------------------------------------------------------------------

@test "adopt: derives a distinct MACKAS_VOLUME_NAME from the project name" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='mackas-meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: disambiguates the volume name when one already exists for something else" {
	make_foreign_root_with_project
	MOCK_EXISTING_VOLUMES="mackas-meta-ai-tmp mackas-meta-ai-dl mackas-meta-ai-sstate" \
		mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='mackas-meta-ai-2'" "$TESTDIR/newconfig.conf"
}

@test "adopt: derives a distinct MACKAS_SHORT_LINK from the project name" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: disambiguates the short link when one already exists for something else" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/some-other-root"
	ln -s "$TESTDIR/some-other-root" "$HOME/oe-meta-ai"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai-2'" "$TESTDIR/newconfig.conf"
}

@test "adopt: re-adopting the same root reuses its existing short link, no new suffix" {
	make_foreign_root_with_project
	ln -s "$FOREIGN" "$HOME/oe-meta-ai"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai'" "$TESTDIR/newconfig.conf"
}

# ---------------------------------------------------------------------------
# Config file handling
# ---------------------------------------------------------------------------

@test "adopt: defaults the config file under ~/.config/mackas/projects/" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN"
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/mackas/projects/meta-ai.conf" ]
}

@test "adopt: an existing config file at the target requires confirmation" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/existing"
	echo "MACKAS_ROOT='/somewhere/else'" > "$TESTDIR/existing/c.conf"
	run "$MACKAS" --set MACKAS_RELOCATE_VOLUMES=0 \
		adopt "$FOREIGN" --write-config "$TESTDIR/existing/c.conf" <<< "n"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	grep -qxF "MACKAS_ROOT='/somewhere/else'" "$TESTDIR/existing/c.conf"
}

@test "adopt: accepting the overwrite confirmation replaces the existing config" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/existing"
	echo "MACKAS_ROOT='/somewhere/else'" > "$TESTDIR/existing/c.conf"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/existing/c.conf"
	[ "$status" -eq 0 ]
	# Compared resolved: on macOS /var/folders/... is itself a symlink to
	# /private/var/folders/..., and adopt correctly stores the canonical form.
	grep -qxF "MACKAS_ROOT='$(cd "$FOREIGN" && pwd -P)'" "$TESTDIR/existing/c.conf"
}

# ---------------------------------------------------------------------------
# Hands off to setup
# ---------------------------------------------------------------------------

@test "adopt: hands off to setup, which completes for real" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas setup'
	printf '%s\n' "$output" | grep -qi '^Done$'
	[ -f "$FOREIGN/env.sh" ]
	[ -f "$FOREIGN/gitconfig" ]
	[ -f "$FOREIGN/work/meta-ai/kas/macos-local.yml" ]
	printf '%s\n' "$output" | grep -qF "Adopted"
	printf '%s\n' "$output" | grep -qF "$TESTDIR/newconfig.conf"
}

# ---------------------------------------------------------------------------
# Per-volume placement: TMPDIR/sstate/downloads each on their own drive
#
# `mackas volume move <name> <dir>` leaves the volume's image tree on another
# drive and a per-volume SYMLINK at the runtime location pointing at it -- the
# symlink IS the record of where the volume lives (volume_real_dir()). Adopting
# a root whose volumes were split across drives that way must not undo it:
# setup_volumes() creating a fresh, empty volume over the top would reformat a
# perfectly good image. cmd_adopt() calls volume_recover() before setup for
# exactly this reason.
# ---------------------------------------------------------------------------

# Where the runtime keeps its volumes for this test's fake $HOME.
cvol_dir() {
	printf '%s/Library/Application Support/com.apple.container/volumes' "$HOME"
}

# Plant the on-disk shape a `volume move <name> <drive>` leaves behind: the
# image tree on $2, a per-volume symlink at the runtime location. The image
# content is a recognizable marker so a test can prove it was never rewritten.
plant_moved_volume() {
	local name="$1" drive="$2"
	mkdir -p "$drive/$name" "$(cvol_dir)"
	printf 'PRECIOUS-%s\n' "$name" > "$drive/$name/volume.img"
	printf '{"id":"%s"}\n' "$name" > "$drive/$name/entity.json"
	ln -s "$drive/$name" "$(cvol_dir)/$name"
}

# The Spotlight seam (MACKAS_MDFIND). volume_spotlight_find() only needs a list
# of volume.img paths and does its own structural filtering, so `find` over the
# test tree is a faithful stand-in that can never reach the real index. find
# does not follow symlinks, so it reports the image at its REAL location on the
# fake drive -- exactly what mdfind reports for a moved volume.
fake_mdfind() {
	cat > "$TESTDIR/fakebin/mdfind" <<EOF
#!/usr/bin/env bash
find "$TESTDIR" -name volume.img 2>/dev/null
EOF
	chmod +x "$TESTDIR/fakebin/mdfind"
	export MACKAS_MDFIND="$TESTDIR/fakebin/mdfind"
}

# Like mk, but with the whole-dir relocation ON -- the default in real use.
mk_reloc() {
	run "$MACKAS" -y \
		--set MACKAS_RELOCATE_VOLUMES=1 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_CPUS=6 \
		--set MACKAS_MEMORY=12g \
		"$@"
}

@test "adopt: a volume already moved to another drive is adopted in place, not re-created" {
	make_foreign_root_with_project
	fake_mdfind
	export MOCK_CONTAINER_LOG="$TESTDIR/container.log"
	local drive="$TESTDIR/nvme"
	plant_moved_volume mackas-meta-ai-tmp "$drive"

	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]

	# The symlink is still the record, still pointing at the separate drive.
	[ -L "$(cvol_dir)/mackas-meta-ai-tmp" ]
	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-tmp")" = "$drive/mackas-meta-ai-tmp" ]
	# And the image behind it is byte-for-byte the one that was there.
	grep -qxF 'PRECIOUS-mackas-meta-ai-tmp' "$drive/mackas-meta-ai-tmp/volume.img"
	# No 'volume create' for it: that is what would reformat the image
	# (refuse_if_stale_entity spots the entity.json through the symlink and
	# restarts the daemon to pick the volume up instead).
	assert_fails grep -q 'volume create .*mackas-meta-ai-tmp' "$TESTDIR/container.log"
	printf '%s\n' "$output" | grep -qi "index doesn't know about"
	# The two that were never moved are created normally.
	grep -q 'volume create .*mackas-meta-ai-dl' "$TESTDIR/container.log"
	grep -q 'volume create .*mackas-meta-ai-sstate' "$TESTDIR/container.log"
}

@test "adopt: re-points a per-volume symlink left dangling by the other Mac's path" {
	make_foreign_root_with_project
	fake_mdfind
	export MOCK_CONTAINER_LOG="$TESTDIR/container.log"
	local drive="$TESTDIR/nvme"
	plant_moved_volume mackas-meta-ai-tmp "$drive"
	# The other Mac's own path for the same drive: the image is right here, but
	# the symlink carried over from that machine points somewhere that does not
	# exist on this one.
	ln -sfn "/Volumes/gone-nvme/mackas-meta-ai-tmp" "$(cvol_dir)/mackas-meta-ai-tmp"

	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]

	printf '%s\n' "$output" | grep -qi "does not resolve to a volume.img"
	printf '%s\n' "$output" | grep -qF "recovered 'mackas-meta-ai-tmp' -> $drive/mackas-meta-ai-tmp"
	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-tmp")" = "$drive/mackas-meta-ai-tmp" ]
	grep -qxF 'PRECIOUS-mackas-meta-ai-tmp' "$drive/mackas-meta-ai-tmp/volume.img"
	assert_fails grep -q 'volume create .*mackas-meta-ai-tmp' "$TESTDIR/container.log"
}

@test "adopt: three volumes on three different drives all keep their own placement" {
	make_foreign_root_with_project
	fake_mdfind
	export MOCK_CONTAINER_LOG="$TESTDIR/container.log"
	plant_moved_volume mackas-meta-ai-tmp    "$TESTDIR/nvme"
	plant_moved_volume mackas-meta-ai-sstate "$TESTDIR/sata-ssd"
	plant_moved_volume mackas-meta-ai-dl     "$TESTDIR/spinning-rust"

	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]

	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-tmp")"    = "$TESTDIR/nvme/mackas-meta-ai-tmp" ]
	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-sstate")" = "$TESTDIR/sata-ssd/mackas-meta-ai-sstate" ]
	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-dl")"     = "$TESTDIR/spinning-rust/mackas-meta-ai-dl" ]
	grep -qxF 'PRECIOUS-mackas-meta-ai-dl' "$TESTDIR/spinning-rust/mackas-meta-ai-dl/volume.img"
	assert_fails grep -q 'volume create ' "$TESTDIR/container.log"
}

# A volume moved onto a drive that is NOT mounted leaves its per-volume
# symlink dangling. refuse_if_stale_entity's entity.json probe cannot see that
# by itself -- `-e` follows symlinks, so it is false through a dangling one and
# reads as "nothing here, safe to create" -- which used to let setup run
# 'container volume create' straight over the link, orphaning whatever was on
# the absent drive and handing back an empty volume (a mysteriously cold cache
# for sstate or downloads). It now refuses instead: the symlink is the only
# record of where that volume lives, and choosing to discard it is the user's
# call, not mackas's.
@test "adopt: an unmounted drive is refused, never created over" {
	make_foreign_root_with_project
	fake_mdfind
	export MOCK_CONTAINER_LOG="$TESTDIR/container.log"
	mkdir -p "$(cvol_dir)"
	ln -s "/Volumes/unplugged-nvme/mackas-meta-ai-tmp" "$(cvol_dir)/mackas-meta-ai-tmp"

	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -ne 0 ]

	# recover reports it and cannot fix it: the image is on a disk that is not
	# there, so Spotlight has nothing to find.
	printf '%s\n' "$output" | grep -qi "does not resolve to a volume.img"
	# The refusal names the drive, and says what to do about it.
	printf '%s\n' "$output" | grep -qi "not currently mounted"
	printf '%s\n' "$output" | grep -qF "/Volumes/unplugged-nvme/mackas-meta-ai-tmp"
	printf '%s\n' "$output" | grep -qi "plug the drive in"
	# The symlink is left exactly as it was -- nothing guesses at it.
	[ "$(readlink "$(cvol_dir)/mackas-meta-ai-tmp")" = "/Volumes/unplugged-nvme/mackas-meta-ai-tmp" ]
	# ...and NOTHING was created over it.
	assert_fails grep -q 'volume create .*mackas-meta-ai-tmp' "$TESTDIR/container.log"
}

@test "adopt: whole-dir relocation composes with a per-volume move, never flattens it" {
	# MACKAS_RELOCATE_VOLUMES=1 symlinks the WHOLE volumes dir onto MACKAS_ROOT.
	# A volume already moved to its own drive must survive that as a symlink
	# INSIDE the relocated dir (setup_relocate_volumes rsyncs with -a, which
	# copies symlinks AS symlinks rather than dereferencing them), leaving two
	# hops: runtime dir -> MACKAS_ROOT/container-volumes -> the other drive.
	make_foreign_root_with_project
	fake_mdfind
	export MOCK_CONTAINER_LOG="$TESTDIR/container.log"
	local drive="$TESTDIR/nvme"
	plant_moved_volume mackas-meta-ai-tmp "$drive"

	mk_reloc adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]

	local root; root="$(cd "$FOREIGN" && pwd -P)"
	[ -L "$(cvol_dir)" ]
	[ "$(readlink "$(cvol_dir)")" = "$root/container-volumes" ]
	[ -L "$root/container-volumes/mackas-meta-ai-tmp" ]
	[ "$(readlink "$root/container-volumes/mackas-meta-ai-tmp")" = "$drive/mackas-meta-ai-tmp" ]
	# The image is still on the other drive, not copied into MACKAS_ROOT.
	grep -qxF 'PRECIOUS-mackas-meta-ai-tmp' "$drive/mackas-meta-ai-tmp/volume.img"
	assert_fails grep -q 'volume create .*mackas-meta-ai-tmp' "$TESTDIR/container.log"
	# The unmoved volumes land in the relocated dir on MACKAS_ROOT's disk.
	grep -q 'volume create .*mackas-meta-ai-dl' "$TESTDIR/container.log"
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "adopt --dry-run writes no config file and mutates nothing" {
	make_foreign_root_with_project
	mk --dry-run adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	[ ! -f "$TESTDIR/newconfig.conf" ]
	[ ! -f "$FOREIGN/env.sh" ]
	[ ! -L "$HOME/oe-meta-ai" ]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "adopt --help prints usage and does nothing" {
	mk adopt --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'bring a foreign MACKAS_ROOT'
	[ ! -d "$HOME/.config/mackas" ]
}
