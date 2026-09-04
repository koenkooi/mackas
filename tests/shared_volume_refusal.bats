#!/usr/bin/env bats
#
# M3 slice 3 (issue #77), part B: `destroy` and `clean`'s downloads/sstate
# targets refuse to touch a SHARED volume -- one more than one pinned
# project's config (projects_dir()/*.conf) resolves to -- under an active
# project selector. #72:
#
#   "mackas destroy under a project selector destroys only that project's
#    PRIVATE volumes. A shared volume is refused with the list of pinned
#    projects referencing it, and requires the explicit
#    `mackas volume destroy <name>` form."
#
# `volume destroy <name>` (naming a volume outright) and `volume destroy
# --all` under NO selector stay exactly as before -- the escape hatch, and
# the pre-M3 behaviour respectively. `volume destroy --all` UNDER a selector
# gets the same guard as `destroy`, for the same reason: it is not "naming a
# volume outright" either, it is the same tmp/dl/sstate/legacy-by-current-
# resolution shape `destroy` (bare) is.
#
# tests/adopt.bats covers part A (adopt_unique_volume_name()'s probe fix) --
# these are part B only.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

VOLDIR() { printf '%s/Library/Application Support/com.apple.container/volumes' "$HOME"; }

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY MACKAS_CPUS
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR
	export HOME="$TESTDIR/home"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"

	ROOT="$TESTDIR/oe"

	# name<TAB>size, one per line: the volumes the fake engine knows about.
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"

	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
voldir="$HOME/Library/Application Support/com.apple.container/volumes"
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"system stop") exit 0 ;;
	"volume ls")
		echo "NAME TYPE DRIVER OPTIONS"
		while IFS="$(printf '\t')" read -r n s; do
			[ -n "$n" ] || continue
			printf '%s named local size=%s\n' "$n" "$s"
		done < "$VSTATE"
		exit 0 ;;
	"volume create")
		eval "name=\${$#}"
		printf '%s\t120G\n' "$name" >> "$VSTATE"
		mkdir -p "$voldir/$name"
		dd if=/dev/zero of="$voldir/$name/volume.img" bs=1024 count=8 2>/dev/null
		exit 0 ;;
	"volume delete"|"volume rm")
		name="$3"
		grep -v -e "^$name	" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		rm -rf "$voldir/$name"
		exit 0 ;;
	"ls "*|"ls")
		echo "ID"
		[ -n "${MOCK_INUSE:-}" ] && echo "runner1"
		exit 0 ;;
	"inspect "*)
		[ -n "${MOCK_INUSE:-}" ] && \
			printf '[ { "mounts" : [ { "name" : "%s" } ] } ]\n' "$MOCK_INUSE"
		exit 0 ;;
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

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# Register a volume with the fake engine, with an on-disk volume.img.
have_volume() {
	local name="$1"
	printf '%s\t120G\n' "$name" >> "$VSTATE"
	mkdir -p "$(VOLDIR)/$name"
	dd if=/dev/zero of="$(VOLDIR)/$name/volume.img" bs=1024 count=8 2>/dev/null
}

exists_now() {
	cut -f1 "$VSTATE" | grep -qxF "$1"
}

mk() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		-y "$@"
}

# ---------------------------------------------------------------------------
# destroy
# ---------------------------------------------------------------------------

@test "destroy: refuses a shared dl volume, naming the other pinned project" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas-foo-dl'
	printf '%s\n' "$output" | grep -qF 'shared'
	printf '%s\n' "$output" | grep -qF 'bar'
	printf '%s\n' "$output" | grep -qF 'volume destroy mackas-foo-dl'
	# The selected project itself is never listed as an "other" claimant:
	# the sharer list is exactly "bar", not "bar foo" or "foo".
	printf '%s\n' "$output" | grep -qF 'is shared with bar --'
	# Refused before anything was touched.
	exists_now mackas-foo-tmp
	exists_now mackas-foo-dl
	exists_now mackas-foo-sstate
}

@test "destroy: refuses a shared sstate volume, naming the other pinned project" {
	pin foo <<-'EOF'
	EOF
	pin baz <<-'EOF'
	MACKAS_VOLUME_SSTATE_NAME="mackas-foo-sstate"
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas-foo-sstate'
	printf '%s\n' "$output" | grep -qF 'baz'
}

@test "destroy: proceeds when nothing else references its volumes (private)" {
	pin foo <<-'EOF'
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-tmp
	assert_fails exists_now mackas-foo-dl
	assert_fails exists_now mackas-foo-sstate
}

@test "destroy: two projects that each explicitly, deliberately share oe-build-* are unaffected when UNSELECTED" {
	# Migration path B, twice over: legacy behaviour, no selector involved at
	# all -- must stay byte-identical to before M3 existed.
	pin foo <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	have_volume oe-build-tmp
	have_volume oe-build-dl
	have_volume oe-build-sstate

	mk destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now oe-build-tmp
}

@test "destroy: with no pinned configs at all (directory absent), unselected destroy is unaffected" {
	rmdir "$PROJDIR"
	have_volume oe-build-tmp
	have_volume oe-build-dl
	have_volume oe-build-sstate

	mk destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now oe-build-dl
}

@test "destroy: a project's OWN explicit override on its own dl is never 'shared with itself'" {
	pin foo <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-dl
}

# ---------------------------------------------------------------------------
# the detector itself: things that are not a second claimant
# ---------------------------------------------------------------------------

@test "destroy: a directory named <name>.conf under projects_dir() is not a claimant" {
	pin foo <<-'EOF'
	EOF
	mkdir -p "$PROJDIR/bogus.conf"
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-dl
}

@test "destroy: a dangling symlink named <name>.conf under projects_dir() is not a claimant" {
	pin foo <<-'EOF'
	EOF
	ln -s "$PROJDIR/nowhere" "$PROJDIR/dangling.conf"
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-dl
}

@test "destroy: sharing is per-volume -- a dl-only share never blocks sstate" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-dl

	mk --project foo clean sstate
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'Nothing to clean'
}

@test "destroy: cannot tell if a volume is shared when a pinned config is unreadable -- fails CLOSED" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	chmod 000 "$PROJDIR/bar.conf"
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo destroy
	local rc="$status"
	chmod 600 "$PROJDIR/bar.conf"
	[ "$rc" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'cannot tell'
	printf '%s\n' "$output" | grep -qF 'bar.conf'
	# Refused before anything was touched -- fail closed, not fail open.
	exists_now mackas-foo-tmp
	exists_now mackas-foo-dl
	exists_now mackas-foo-sstate
}

@test "clean downloads: an unreadable, UNRELATED pinned config still fails closed" {
	# 'unrelated' on paper -- foo cannot prove that without reading it, which
	# is exactly the point: an unreadable config is an unknown, not a no.
	pin foo <<-'EOF'
	EOF
	pin unrelated <<-'EOF'
	MACKAS_VOLUME_NAME="something-else-entirely"
	EOF
	chmod 000 "$PROJDIR/unrelated.conf"
	have_volume mackas-foo-dl

	mk --project foo clean downloads
	local rc="$status"
	chmod 600 "$PROJDIR/unrelated.conf"
	[ "$rc" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'cannot tell'
	exists_now mackas-foo-dl
}

@test "destroy: an unreadable pinned config does not block an UNSELECTED destroy" {
	# The guard is gated on PROJECT_SELECTED at all -- an unreadable stray
	# file must not turn into a new failure mode for the pre-M3 default path.
	pin foo <<-'EOF'
	EOF
	chmod 000 "$PROJDIR/foo.conf"
	have_volume oe-build-tmp
	have_volume oe-build-dl
	have_volume oe-build-sstate

	mk destroy
	local rc="$status"
	chmod 600 "$PROJDIR/foo.conf"
	[ "$rc" -eq 0 ]
	assert_fails exists_now oe-build-dl
}

# ---------------------------------------------------------------------------
# clean downloads / sstate
# ---------------------------------------------------------------------------

@test "clean downloads: refuses a shared dl volume" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-dl

	mk --project foo clean downloads
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas-foo-dl'
	printf '%s\n' "$output" | grep -qF 'bar'
	printf '%s\n' "$output" | grep -qF 'volume destroy mackas-foo-dl'
	exists_now mackas-foo-dl
}

@test "clean sstate: refuses a shared sstate volume" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_SSTATE_NAME="mackas-foo-sstate"
	EOF
	have_volume mackas-foo-sstate

	mk --project foo clean sstate
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas-foo-sstate'
	printf '%s\n' "$output" | grep -qF 'bar'
}

@test "clean downloads: proceeds when the dl volume is private" {
	pin foo <<-'EOF'
	EOF
	have_volume mackas-foo-dl

	mk --project foo clean downloads
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'cleaned'
}

@test "clean: bare (tmp+legacy volume only) is never guarded, even with a shared dl pinned elsewhere" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-tmp

	mk --project foo clean
	[ "$status" -eq 0 ]
}

@test "clean tmp+deploy: never guarded either -- tmp has no sharing knob" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	# No tmp volume at all -- clean_tmp_deploy's own "nothing to clean" path,
	# proof that it never even reaches (and is never refused by) the shared
	# check that would apply to dl/sstate.
	mk --project foo clean tmp+deploy
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'Nothing to clean'
}

# ---------------------------------------------------------------------------
# volume destroy -- the explicit escape hatch
# ---------------------------------------------------------------------------

@test "volume destroy <name>: still deletes a shared volume when named directly (the escape hatch)" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-dl

	mk --project foo volume destroy mackas-foo-dl
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-dl
}

@test "volume destroy --all: refuses when the dl volume is shared, same as bare destroy" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="mackas-foo-dl"
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo volume destroy --all
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas-foo-dl'
	printf '%s\n' "$output" | grep -qF 'bar'
	exists_now mackas-foo-tmp
}

@test "volume destroy --all: proceeds when private, exactly as before" {
	pin foo <<-'EOF'
	EOF
	have_volume mackas-foo-tmp
	have_volume mackas-foo-dl
	have_volume mackas-foo-sstate

	mk --project foo volume destroy --all
	[ "$status" -eq 0 ]
	assert_fails exists_now mackas-foo-dl
}

@test "volume destroy --all: unselected, with a shared config pinned elsewhere, is unaffected" {
	pin foo <<-'EOF'
	EOF
	pin bar <<-'EOF'
	MACKAS_VOLUME_DL_NAME="oe-build-dl"
	EOF
	have_volume oe-build-tmp
	have_volume oe-build-dl
	have_volume oe-build-sstate

	mk volume destroy --all
	[ "$status" -eq 0 ]
	assert_fails exists_now oe-build-dl
}
