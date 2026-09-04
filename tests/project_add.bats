#!/usr/bin/env bats
#
# Tests for `mackas project add <name> [--url URL --branch BRANCH |
# --from <checkout>]` -- the in-root sibling of `adopt`: it pins a project
# workspace under THIS Mac's own MACKAS_ROOT (creating $MACKAS_WORK/<name>/
# and a standalone config at ~/.config/mackas/projects/<name>.conf), instead
# of adopting a whole foreign root. See #72/#77.
#
# Unlike adopt.bats, none of this needs the container-runtime/curl/shasum
# mocks: 'project add' pins only -- it never calls cmd_setup, never clones,
# never touches a volume. The one fake here (like project_select.bats/
# project_volume_names.bats) is 'container', because 'status' asks the
# daemon for a volume's live cap and a real dev-Mac daemon would answer with
# real, unrelated state.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

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

	ROOT="$TESTDIR/oe"

	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") echo "NAME TYPE DRIVER OPTIONS"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	chmod -R u+rwX "$TESTDIR" 2>/dev/null || true
	rm -rf "$TESTDIR"
}

# Write a pinned project config named $1 from stdin (for tests that need one
# already there before 'project add' runs).
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

mk_add() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" "$@"
}

# A real local git checkout under $ROOT/work/$1, the fixture --from tests
# convert. Mirrors adopt.bats' own FIXTURE pattern.
mk_checkout() {
	local dir="$ROOT/work/$1"
	mkdir -p "$dir"
	(
		cd "$dir"
		git init -q -b "${3:-main}"
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		[ -z "${2:-}" ] || git remote add origin "$2"
	)
}

# The exact runtime-args mount fragment -- same lightest black-box hook onto
# MACKAS_VOL_TMP/DL/SSTATE that project_volume_names.bats/
# multi_project_compat.bats already use.
assert_volumes() {
	local tmp="$1" dl="$2" sstate="$3"
	printf '%s\n' "$output" | grep -qF -- "-v ${tmp}:/build -e KAS_BUILD_DIR=/build"
	printf '%s\n' "$output" | grep -qF -- "-v ${dl}:/downloads -e DL_DIR=/downloads"
	printf '%s\n' "$output" | grep -qF -- "-v ${sstate}:/sstate -e SSTATE_DIR=/sstate"
}

# ---------------------------------------------------------------------------
# Happy path: --url/--branch
# ---------------------------------------------------------------------------

@test "project add --url/--branch writes a standalone config and creates the workspace dir" {
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]

	[ -f "$PROJDIR/demo.conf" ]
	[ -d "$ROOT/work/demo" ]

	grep -qxF "MACKAS_ROOT='$ROOT'" "$PROJDIR/demo.conf"
	grep -qxF "MACKAS_PROJECT_DIR='demo'" "$PROJDIR/demo.conf"
	grep -qxF "MACKAS_PROJECT_URL='https://example.com/demo.git'" "$PROJDIR/demo.conf"
	grep -qxF "MACKAS_PROJECT_BRANCH='main'" "$PROJDIR/demo.conf"
	# No volume-name override: nothing pinned one explicitly, so it is left
	# to derive mackas-demo-* once --project demo selects this file.
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
}

@test "project add --url without --branch is refused" {
	mk_add project add demo --url https://example.com/demo.git
	[ "$status" -ne 0 ]
	[ ! -f "$PROJDIR/demo.conf" ]
}

@test "project add --branch without --url is refused" {
	mk_add project add demo --branch main
	[ "$status" -ne 0 ]
	[ ! -f "$PROJDIR/demo.conf" ]
}

@test "project add --from together with --url is refused" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo --url https://example.com/other.git --branch main
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "mutually exclusive"
}

@test "project add with no --url/--branch/--from pins the name with no checkout configured" {
	mk_add project add demo
	[ "$status" -eq 0 ]
	[ -d "$ROOT/work/demo" ]
	! grep -q '^MACKAS_PROJECT_URL=' "$PROJDIR/demo.conf"
}

@test "project add refuses an invalid name the same way --project does" {
	mk_add project add "../escape"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "project name"
}

# ---------------------------------------------------------------------------
# The work/ collision refusal (#72: filesystem shape alone never decides)
# ---------------------------------------------------------------------------

@test "project add refuses a name colliding with a plain, unpinned work/ entry" {
	mkdir -p "$ROOT/work/demo"
	echo "just a directory, not even git" > "$ROOT/work/demo/README"
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "already exists"
	[ ! -f "$PROJDIR/demo.conf" ]
	# Untouched: the collision must not have gotten anywhere near deciding
	# to fold the existing directory in.
	[ -f "$ROOT/work/demo/README" ]
}

@test "project add recovers cleanly from an interrupted prior run (empty leftover work/ dir)" {
	# 'run mkdir -p "$workspace_dir"' is this command's own first mutation,
	# strictly before the config file is ever written -- so a prior run that
	# died between that mkdir and its last config_write_setting call (Ctrl-C,
	# a full disk) leaves exactly this behind: an empty work/<name>/ with no
	# pinned config. A plain re-run must finish the job, not join the earlier
	# 'plain directory collision' refusal above -- an empty directory carries
	# nothing that could be silently folded in or lost.
	mkdir -p "$ROOT/work/demo"
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]
	[ -f "$PROJDIR/demo.conf" ]
	grep -qxF "MACKAS_PROJECT_URL='https://example.com/demo.git'" "$PROJDIR/demo.conf"
}

@test "project add --from a DIFFERENT directory than <name> is refused, not silently converted" {
	mk_checkout other-name https://example.com/other.git
	mk_add project add demo --from other-name
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "does not name"
	[ ! -f "$PROJDIR/demo.conf" ]
	# Nothing moved: the original checkout is exactly where it was.
	[ -d "$ROOT/work/other-name/.git" ]
	[ ! -d "$ROOT/work/demo" ]
}

@test "project add --from accepts the bare name, 'work/<name>', and a full path, identically" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	rm -f "$PROJDIR/demo.conf"
	mk_add project add demo --from "work/demo"
	[ "$status" -eq 0 ]
	rm -f "$PROJDIR/demo.conf"
	mk_add project add demo --from "$ROOT/work/demo"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --from conversion: introspection, and the already-pinned overwrite refusal
# ---------------------------------------------------------------------------

@test "project add --from introspects the checkout's remote URL and branch" {
	mk_checkout demo https://example.com/demo.git feature-branch
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_PROJECT_URL='https://example.com/demo.git'" "$PROJDIR/demo.conf"
	grep -qxF "MACKAS_PROJECT_BRANCH='feature-branch'" "$PROJDIR/demo.conf"
}

@test "project add --from a checkout with no origin remote leaves URL/BRANCH unset" {
	mk_checkout demo "" main
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	! grep -q '^MACKAS_PROJECT_URL=' "$PROJDIR/demo.conf"
	! grep -q '^MACKAS_PROJECT_BRANCH=' "$PROJDIR/demo.conf"
}

@test "project add --from a non-git directory is refused" {
	mkdir -p "$ROOT/work/demo"
	mk_add project add demo --from demo
	[ "$status" -ne 0 ]
	[ ! -f "$PROJDIR/demo.conf" ]
}

@test "project add on an already-pinned name is refused without confirmation" {
	pin demo <<-'EOF'
	MACKAS_ROOT='/somewhere/else'
	EOF
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		project add demo --url https://example.com/demo.git --branch main <<< "n"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	grep -qxF "MACKAS_ROOT='/somewhere/else'" "$PROJDIR/demo.conf"
}

@test "project add -y overwrites an already-pinned name's config" {
	pin demo <<-'EOF'
	MACKAS_ROOT='/somewhere/else'
	EOF
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_ROOT='$ROOT'" "$PROJDIR/demo.conf"
	! grep -q '/somewhere/else' "$PROJDIR/demo.conf"
}

# ---------------------------------------------------------------------------
# THE MIGRATION QUESTION (#72 path B): keep vs derive, --from only
#
# bats' `run` never attaches a tty, so the genuinely-interactive confirm()
# prompt cannot be exercised hermetically here (same limitation every other
# confirm()-gated test in this suite already lives with -- see adopt.bats).
# --keep-volumes/--derive-volumes are the deterministic equivalent of
# answering both ways, and are what these tests exercise; the two
# non-interactive-default tests below both land on the SAME safe-default
# branch (no tty, regardless of -y) -- kept as two tests because they
# document two different callers reaching it (an explicit -y, and a script
# with neither -y nor a tty), not because the code takes two different paths.
# ---------------------------------------------------------------------------

@test "project add --from --keep-volumes pins the current stem explicitly" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --keep-volumes
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='oe-build'" "$PROJDIR/demo.conf"
}

@test "project add --from --derive-volumes leaves the stem unset (derives mackas-<name>-*)" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --derive-volumes
	[ "$status" -eq 0 ]
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
}

@test "project add --from, non-interactive, defaults to keeping the existing stem" {
	mk_checkout demo https://example.com/demo.git
	# mk_add's `run` already has no tty attached (bats captures output), and
	# -y is passed -- both routes to the same safe, documented default.
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='oe-build'" "$PROJDIR/demo.conf"
	printf '%s\n' "$output" | grep -qi "non-interactive"
}

@test "project add --from, no -y at all (still no tty under bats), defaults to keeping the stem" {
	mk_checkout demo https://example.com/demo.git
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" --set MACKAS_VOLUME_NAME=oe-build \
		project add demo --from demo
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='oe-build'" "$PROJDIR/demo.conf"
}

@test "project add --from --keep-volumes then --derive-volumes: no stale line survives the overwrite" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --keep-volumes
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='oe-build'" "$PROJDIR/demo.conf"

	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --derive-volumes
	[ "$status" -eq 0 ]
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
	[ "$(grep -c '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf")" -eq 0 ]
}

@test "project add --keep-volumes without --from is refused" {
	mk_add project add demo --url https://example.com/demo.git --branch main --keep-volumes
	[ "$status" -ne 0 ]
}

@test "project add --keep-volumes and --derive-volumes together is refused" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo --keep-volumes --derive-volumes
	[ "$status" -ne 0 ]
}

@test "project add --from carries forward an explicit MACKAS_VOLUME_DL_NAME override" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_DL_NAME=shared-dl project add demo --from demo --derive-volumes
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_DL_NAME='shared-dl'" "$PROJDIR/demo.conf"
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
}

# ---------------------------------------------------------------------------
# --dry-run writes nothing
# ---------------------------------------------------------------------------

@test "project add --dry-run creates neither the config nor the workspace directory" {
	mk_add --dry-run project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]
	[ ! -f "$PROJDIR/demo.conf" ]
	[ ! -d "$ROOT/work/demo" ]
}

# ---------------------------------------------------------------------------
# The round trip: what got written is what --project <name> resolves
# ---------------------------------------------------------------------------

@test "the written config round-trips: --project <name> resolves mackas-<name>-* by default" {
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]

	run "$MACKAS" --project demo runtime-args
	[ "$status" -eq 0 ]
	assert_volumes mackas-demo-tmp mackas-demo-dl mackas-demo-sstate
}

@test "the round trip honours an explicitly-kept stem (migration path B)" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --keep-volumes
	[ "$status" -eq 0 ]

	run "$MACKAS" --project demo runtime-args
	[ "$status" -eq 0 ]
	assert_volumes oe-build-tmp oe-build-dl oe-build-sstate
}

@test "the round trip's kept stem also surfaces the #77 disagreement note exactly once" {
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --keep-volumes
	[ "$status" -eq 0 ]

	run "$MACKAS" --project demo status
	[ "$status" -eq 0 ]
	local n
	n="$(printf '%s\n' "$output" | grep -c 'note:')"
	[ "$n" -eq 1 ]
	printf '%s\n' "$output" | grep -qF "oe-build-tmp"
	printf '%s\n' "$output" | grep -qF "mackas-demo-tmp"
}

@test "the round trip's MACKAS_PROJECT_DIR/URL/BRANCH resolve correctly too" {
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]

	run "$MACKAS" --project demo status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "https://example.com/demo.git"
	printf '%s\n' "$output" | grep -qF "$ROOT/work/demo"
}

# ---------------------------------------------------------------------------
# Wiring: 'project' vs 'projects', help, misplaced global flags
# ---------------------------------------------------------------------------

@test "'project' and 'projects' are distinct commands" {
	mk_add project add demo --url https://example.com/demo.git --branch main
	[ "$status" -eq 0 ]

	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q "demo"
}

@test "'mackas project' with no verb shows usage, not an error" {
	run "$MACKAS" project
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "project add"
}

@test "'mackas project add --help' shows the add-specific usage" {
	run "$MACKAS" project add --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi -- "--keep-volumes"
}

@test "'mackas project bogus' is refused as an unknown subcommand" {
	run "$MACKAS" project bogus
	[ "$status" -ne 0 ]
}

@test "--config after 'project add' is refused with the misplaced-flag hint" {
	run "$MACKAS" project add demo --config /tmp/whatever.conf
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "must come BEFORE"
}

@test "'project' appears in the top-level command list" {
	run "$MACKAS" --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^ *project +'
}
