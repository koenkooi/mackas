#!/usr/bin/env bats
#
# Tests for #78 (M4) tier 3: deriving a project SELECTION from physical $PWD,
# the third tier between the explicit selectors (--project/$MACKAS_PROJECT_
# SELECT and --config/$MACKAS_CONF, M2) and the default search path.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The rule (see derive_project_candidates()/load_config() in mackas): compute
# `pwd -P` (physical on BOTH sides -- this is what defuses a ~/oe-style
# short-link symlink); enumerate ~/.config/mackas/projects/*.conf and GREP
# (never source) MACKAS_ROOT out of each; form <root>/work/<name>, resolved
# physically too; prefix-match against $PWD. Zero matches falls through to
# the default search path, byte-identically (tests/implicit_select_compat.
# bats is that contract, in full, and is not touched here). Exactly one match
# selects it through the exact same strict sequence --project always has.
# More than one dies, listing every candidate. Selection never guesses and
# never creates an identity -- it only ever picks among ones already pinned.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR
	export HOME="$TESTDIR/home"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"

	# name<TAB>size, one per line: the volumes the fake engine knows about --
	# same stateful fake destroy/clean's own tests use (shared_volume_
	# refusal.bats), needed here too since a couple of tests below reuse
	# that setup to prove destroy/clean's shared-volume refusal fires
	# identically under a DERIVED selection.
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
		exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/work"
}

teardown() {
	cd /
	chmod -R u+rwX "$TESTDIR" 2>/dev/null || true
	rm -rf "$TESTDIR"
}

# Read one setting out of `mackas status` output.
setting() {
	printf '%s\n' "$output" | awk -v k="$1" '$1 == k { $1=""; sub(/^ +/,""); print; exit }'
}

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

VOLDIR() { printf '%s/Library/Application Support/com.apple.container/volumes' "$HOME"; }

have_volume() {
	local name="$1"
	printf '%s\t120G\n' "$name" >> "$VSTATE"
	mkdir -p "$(VOLDIR)/$name"
	dd if=/dev/zero of="$(VOLDIR)/$name/volume.img" bs=1024 count=8 2>/dev/null
}

exists_now() {
	cut -f1 "$VSTATE" | grep -qxF "$1"
}

assert_volume_names() {
	local stem="$1"
	printf '%s\n' "$output" | grep -qF -- "-v ${stem}-tmp:/build -e KAS_BUILD_DIR=/build"
	printf '%s\n' "$output" | grep -qF -- "-v ${stem}-dl:/downloads -e DL_DIR=/downloads"
	printf '%s\n' "$output" | grep -qF -- "-v ${stem}-sstate:/sstate -e SSTATE_DIR=/sstate"
}

# ---------------------------------------------------------------------------
# The happy path: root and a nested subdirectory both derive
# ---------------------------------------------------------------------------

@test "derive: from the workspace root selects the pinned project" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  project selected +proj$'
}

@test "derive: from a directory NESTED inside the workspace also selects it" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj/build/tmp/deep"
	cd "$ROOT/work/proj/build/tmp/deep"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  project selected +proj$'
}

# ---------------------------------------------------------------------------
# Symlinks: physical on BOTH sides is what makes these agree
# ---------------------------------------------------------------------------

@test "derive: root pinned PHYSICAL, cwd reached through a symlink -- still matches" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	ln -s "$ROOT" "$HOME/oe-link"
	cd "$HOME/oe-link/work/proj"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  project selected +proj$'
}

@test "derive: root pinned VIA a symlink, cwd reached physically -- still matches" {
	ln -s "$ROOT" "$HOME/oe-link"
	pin proj <<-EOF
	MACKAS_ROOT="$HOME/oe-link"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  project selected +proj$'
}

# ---------------------------------------------------------------------------
# Zero matches: byte-identical fall-through (see tests/implicit_select_compat
# .bats for the exhaustive version of this contract; this is a light sanity
# check specific to this file's own fixtures).
# ---------------------------------------------------------------------------

@test "derive: zero matches falls through to the default search path" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	echo 'MACKAS_KAS_CONFIG="from-search-path"' > "$HOME/.mackas.conf"
	chmod 600 "$HOME/.mackas.conf"
	cd "$TESTDIR"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-search-path" ]
}

@test "derive: an UNPINNED sibling checkout under the same root derives nothing" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj" "$ROOT/work/legacy-checkout"
	cd "$ROOT/work/legacy-checkout"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
}

@test "derive: a moved/renamed workspace derives nothing -- identity is never re-minted" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	mv "$ROOT/work/proj" "$ROOT/work/proj-renamed"
	cd "$ROOT/work/proj-renamed"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
}

# ---------------------------------------------------------------------------
# More than one candidate: die, listing both
# ---------------------------------------------------------------------------

@test "derive: nested candidates (adopted root inside another project's work/) die listing both" {
	rootA="$TESTDIR/rootA"
	rootB="$rootA/work/foo"
	mkdir -p "$rootB/work/bar/sub"
	pin foo <<-EOF
	MACKAS_ROOT="$rootA"
	EOF
	pin bar <<-EOF
	MACKAS_ROOT="$rootB"
	EOF
	cd "$rootB/work/bar/sub"
	run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'foo'
	printf '%s\n' "$output" | grep -qF 'bar'
	printf '%s\n' "$output" | grep -qi 'more than one'
	printf '%s\n' "$output" | grep -qF -- '--project'
}

# ---------------------------------------------------------------------------
# An unreadable pinned config: fail closed, but only while tier 3 is actually
# being evaluated -- an explicit selector skips it entirely.
# ---------------------------------------------------------------------------

@test "derive: an unreadable pinned config dies naming it" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	chmod 000 "$PROJDIR/proj.conf"
	run "$MACKAS" status
	local rc="$status"
	chmod 600 "$PROJDIR/proj.conf"
	[ "$rc" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'proj.conf'
	printf '%s\n' "$output" | grep -qi 'cannot tell'
}

@test "derive: an unreadable pinned config does NOT die when --project is given -- tier 3 is never evaluated" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	pin other <<-'EOF'
	MACKAS_KAS_CONFIG="from-other"
	EOF
	chmod 000 "$PROJDIR/proj.conf"
	run "$MACKAS" --project other status
	local rc="$status"
	chmod 600 "$PROJDIR/proj.conf"
	[ "$rc" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-other" ]
}

# ---------------------------------------------------------------------------
# A MACKAS_ROOT that is not an absolute path is simply not a candidate --
# never eval'd or expanded, proven with a planted sentinel side effect.
# ---------------------------------------------------------------------------

@test "derive: non-absolute MACKAS_ROOT shapes (relative, ~, \$HOME, command substitution) are never candidates and never evaluated" {
	local shape sentinel
	for shape in 'relative-oe' '~/oe' '$HOME/oe' '$(touch SENTINEL_RAN)/oe'; do
		sentinel="$TESTDIR/SENTINEL_RAN"
		rm -f "$TESTDIR/SENTINEL_RAN" "$HOME/SENTINEL_RAN" ./SENTINEL_RAN 2>/dev/null || true
		pin "shape$(printf '%s' "$shape" | tr -c 'A-Za-z0-9' -)" <<-EOF
		MACKAS_ROOT="$shape"
		EOF
	done
	cd "$TESTDIR"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
	[ ! -e "$TESTDIR/SENTINEL_RAN" ]
	[ ! -e "$HOME/SENTINEL_RAN" ]
	[ ! -e "./SENTINEL_RAN" ]
}

# ---------------------------------------------------------------------------
# The winner is still held to config_file_is_safe() -- dies, never
# warn-and-fall-through (the search path's own, looser rule).
# ---------------------------------------------------------------------------

@test "derive: a group-writable winning config DIES rather than falling through with a warning" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod g+w "$PROJDIR/proj.conf"
	echo 'MACKAS_KAS_CONFIG="from-search-path"' > "$HOME/.mackas.conf"
	chmod 600 "$HOME/.mackas.conf"
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
	! printf '%s\n' "$output" | grep -q 'from-search-path'
}

# ---------------------------------------------------------------------------
# Downstream of selection: volume naming follows PROJECT_SELECTED exactly as
# for --project (derive_volume_names doesn't special-case the tier).
# ---------------------------------------------------------------------------

@test "derive: a derived selection yields mackas-<name>-* volumes" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" runtime-args
	[ "$status" -eq 0 ]
	assert_volume_names "mackas-proj"
}

@test "derive: an explicit MACKAS_VOLUME_NAME in the derived config still wins over the mackas-<name> default" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_VOLUME_NAME="oe-build"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_NAME)" = "oe-build" ]
	# The M3 precedence-and-warn note still fires for a derived selection,
	# exactly as it would under --project.
	printf '%s\n' "$output" | grep -qi 'an explicit volume name is set'
}

# ---------------------------------------------------------------------------
# set / get / unset follow derivation, and echo the file
# ---------------------------------------------------------------------------

@test "derive: set from inside a derived workspace writes the derived project's file and echoes it" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" set MACKAS_MEMORY 24g
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$PROJDIR/proj.conf"
	grep -qF "MACKAS_MEMORY='24g'" "$PROJDIR/proj.conf"
}

@test "derive: get from inside a derived workspace reads back through the derived file" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_MEMORY="16g"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	# --separate-stderr: the tier-3 resolution note (once it exists) lands on
	# stderr and would otherwise merge into $output, right alongside the
	# value 'get' prints.
	run --separate-stderr "$MACKAS" get MACKAS_MEMORY
	[ "$status" -eq 0 ]
	[ "$output" = "16g" ]
}

@test "derive: unset from inside a derived workspace removes the line and echoes the file" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_MEMORY="16g"
	MACKAS_KAS_CONFIG="keep-me"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" unset MACKAS_MEMORY
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$PROJDIR/proj.conf"
	assert_fails grep -q '^MACKAS_MEMORY=' "$PROJDIR/proj.conf"
	grep -q 'keep-me' "$PROJDIR/proj.conf"
}

# ---------------------------------------------------------------------------
# status names the tier/source
# ---------------------------------------------------------------------------

@test "derive: status names the source as 'derived from \$PWD', and only then" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  selected via +derived from \$PWD$'

	run "$MACKAS" --project proj status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  selected via +--project$'

	MACKAS_PROJECT_SELECT=proj run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  selected via +\$MACKAS_PROJECT_SELECT$'
}

# ---------------------------------------------------------------------------
# The one-line stderr resolution note: exactly once, and not for status/help
# ---------------------------------------------------------------------------

@test "derive: the resolution note prints exactly once on stderr for runtime-args" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run --separate-stderr "$MACKAS" runtime-args
	[ "$status" -eq 0 ]
	local n
	n="$(printf '%s\n' "$stderr" | grep -c "derived from \$PWD" || true)"
	[ "$n" -eq 1 ]
	printf '%s\n' "$stderr" | grep -q 'proj'
	printf '%s\n' "$stderr" | grep -q 'mackas-proj-tmp'
	printf '%s\n' "$stderr" | grep -q 'mackas-proj-dl'
	printf '%s\n' "$stderr" | grep -q 'mackas-proj-sstate'
}

@test "derive: the resolution note does NOT print for status (which reports it in its own section instead)" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run --separate-stderr "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$stderr" | grep -q 'derived from \$PWD'
}

@test "derive: the resolution note does NOT print for --help, which never loads config at all" {
	pin proj <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/proj"
	cd "$ROOT/work/proj"
	run --separate-stderr "$MACKAS" --help
	[ "$status" -eq 0 ]
	! printf '%s\n' "$stderr" | grep -q 'derived from \$PWD'
}

# ---------------------------------------------------------------------------
# destroy/clean's shared-volume refusal fires identically under a derived
# selection -- one test each, same shape as shared_volume_refusal.bats.
# ---------------------------------------------------------------------------

mkd() {
	run "$MACKAS" -y \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		"$@"
}

@test "derive: destroy refuses a shared dl volume under a DERIVED selection, exactly as under --project" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	pin bar <<-EOF
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	mkdir -p "$ROOT/work/foo"
	have_volume mackas-foo-tmp
	have_volume shared-dl
	have_volume mackas-foo-sstate
	cd "$ROOT/work/foo"
	mkd destroy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'bar'
	printf '%s\n' "$output" | grep -qF 'derived from $PWD'
	exists_now shared-dl
}

@test "derive: clean sstate refuses a shared sstate volume under a DERIVED selection" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_VOLUME_SSTATE_NAME="shared-sstate"
	EOF
	pin bar <<-EOF
	MACKAS_VOLUME_SSTATE_NAME="shared-sstate"
	EOF
	mkdir -p "$ROOT/work/foo"
	have_volume shared-sstate
	cd "$ROOT/work/foo"
	mkd clean sstate
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'bar'
	exists_now shared-sstate
}

# ---------------------------------------------------------------------------
# The audited hints read truthfully for a derived selection: no "drop
# --project NAME" for a selection that was never typed.
# ---------------------------------------------------------------------------

@test "derive: the shared-volume refusal names the derived source, not '--project'" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	pin bar <<-EOF
	MACKAS_VOLUME_DL_NAME="shared-dl"
	EOF
	mkdir -p "$ROOT/work/foo"
	have_volume shared-dl
	cd "$ROOT/work/foo"
	mkd destroy
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "derived from \$PWD"
	! printf '%s\n' "$output" | grep -qF -- "under '--project"
}

@test "derive: project add's 'cannot tell what NAME was already built with' hint says run elsewhere, not 'drop --project NAME'" {
	# Mirrors project_add.bats' "run under a DIFFERENT project's active
	# selector, is refused" -- just with the active selector coming from
	# cwd derivation (standing inside foo's workspace) rather than an
	# explicit --project other.
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	pin bar <<-'EOF'
	EOF
	mkdir -p "$ROOT/work/foo"
	local bardir="$ROOT/work/bar"
	mkdir -p "$bardir"
	( cd "$bardir" && git init -q -b main \
		&& git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
	cd "$ROOT/work/foo"
	run "$MACKAS" -y project add bar --from bar
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "cannot tell what 'bar' was already built with"
	printf '%s\n' "$output" | grep -qi 'run from outside this workspace'
	! printf '%s\n' "$output" | grep -qF "drop '--project"
	# Nothing was appended to bar's already-pinned (empty) config.
	[ ! -s "$PROJDIR/bar.conf" ]
}
