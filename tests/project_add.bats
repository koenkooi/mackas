#!/usr/bin/env bats
#
# Tests for `mackas project add <name> [--url URL --branch BRANCH |
# --from <checkout>]` -- the in-root sibling of `adopt`: it pins a project
# workspace under THIS Mac's own MACKAS_ROOT (creating $MACKAS_WORK_ROOT/<name>/
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

# ---------------------------------------------------------------------------
# M6 (#80) slice 2: workspace_dir and the bare-name --from arm must resolve
# through MACKAS_WORK_ROOT (the flat work root), not MACKAS_WORK -- a later
# slice scopes MACKAS_WORK to the SELECTED project's own KAS_WORK_DIR, while
# MACKAS_WORK_ROOT stays the flat root. Getting this backwards is silent:
# under an active --project A selector, 'project add B' would create
# work/A/B and pin MACKAS_PROJECT_DIR=B (whose derived checkout is
# work/B/B) -- the directory created and the directory pinned diverge, with
# no error.
#
# This slice keeps MACKAS_WORK an exact alias of MACKAS_WORK_ROOT (zero
# behaviour change -- see multi_project_compat.bats), so no runtime output
# can yet tell the two variables apart -- an assertion built on 'project
# add's output would pass identically whichever one line 6379/6397 actually
# read, which is exactly the vacuous-test trap AGENTS.md warns against.
# Source-grep is the honest test for logic a bats run cannot yet exercise
# differently (same rule as set -e-guarded logic).
# ---------------------------------------------------------------------------

@test "project add: workspace_dir and the bare-name --from arm read MACKAS_WORK_ROOT (source-grep, M6 forward-compat)" {
	grep -qF 'workspace_dir="$MACKAS_WORK_ROOT/$name"' "$MACKAS"
	grep -qF 'from_resolved="$(resolve_path "$MACKAS_WORK_ROOT/$from")"' "$MACKAS"
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
	# Each 'mk_add' call below auto-confirms (mk_add always passes -y), so
	# the #80 item 4 migration offer added alongside this test also
	# auto-runs and moves the checkout into work/demo/demo -- start a fresh
	# flat checkout before each attempt so there is still something legacy-
	# shaped for --from to resolve and introspect; the migration itself is
	# covered on its own further down this file.
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	rm -f "$PROJDIR/demo.conf"
	rm -rf "$ROOT/work/demo"
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from "work/demo"
	[ "$status" -eq 0 ]
	rm -f "$PROJDIR/demo.conf"
	rm -rf "$ROOT/work/demo"
	mk_checkout demo https://example.com/demo.git
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

	# The call above also auto-confirmed the #80 item 4 migration offer
	# (mk_add always passes -y) and moved the checkout into work/demo/demo
	# -- start a fresh flat checkout so the second --from call still has
	# something legacy-shaped to introspect.
	rm -rf "$ROOT/work/demo"
	mk_checkout demo https://example.com/demo.git
	mk_add --set MACKAS_VOLUME_NAME=oe-build project add demo --from demo --derive-volumes
	[ "$status" -eq 0 ]
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
	[ "$(grep -c '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# #80 item 4: --from offers to move a pre-M6 flat checkout into its
# now-current work/<name>/<name> workspace. 'mk_checkout' always produces
# the flat pre-M6 shape (a real git checkout directly at work/<name>), which
# is exactly the fixture this whole section needs.
# ---------------------------------------------------------------------------

@test "project add --from -y moves a legacy flat checkout into its workspace" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "moved the checkout to $ROOT/work/demo/demo"

	# The checkout itself is intact at the new path, not re-cloned.
	[ -d "$ROOT/work/demo/demo/.git" ]
	[ "$(git -C "$ROOT/work/demo/demo" log --oneline | wc -l)" -eq 1 ]
	# And it is gone from the old, flat path.
	[ ! -d "$ROOT/work/demo/.git" ]
}

@test "project add --from, no tty and no --yes, declines the move and prints all three recovery commands" {
	mk_checkout demo https://example.com/demo.git
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" project add demo --from demo
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "declined -- 'demo' is pinned, but its checkout is still at"
	# Nothing moved.
	[ -d "$ROOT/work/demo/.git" ]
	[ ! -d "$ROOT/work/demo/demo" ]
	# All three recovery commands, naming the real paths.
	printf '%s\n' "$output" | grep -qF "mv $ROOT/work/demo $ROOT/work/.mackas-migrating-demo"
	printf '%s\n' "$output" | grep -qF "mkdir -p $ROOT/work/demo"
	printf '%s\n' "$output" | grep -qF "mv $ROOT/work/.mackas-migrating-demo $ROOT/work/demo/demo"
}

@test "project add --from --dry-run prints the move but changes nothing on disk" {
	mk_checkout demo https://example.com/demo.git
	mk_add --dry-run project add demo --from demo
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "+ mv $ROOT/work/demo $ROOT/work/.mackas-migrating-demo"
	printf '%s\n' "$output" | grep -qF "+ mkdir -p $ROOT/work/demo"
	printf '%s\n' "$output" | grep -qF "+ mv $ROOT/work/.mackas-migrating-demo $ROOT/work/demo/demo"
	# --dry-run's own contract: nothing on disk moved, no config written.
	[ -d "$ROOT/work/demo/.git" ]
	[ ! -e "$PROJDIR/demo.conf" ]
}

@test "project add --from refuses to move onto an already-existing destination" {
	mk_checkout demo https://example.com/demo.git
	mkdir -p "$ROOT/work/demo/demo"
	echo "something already here" > "$ROOT/work/demo/demo/stray-file"
	mk_add project add demo --from demo
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "already exists -- refusing to move"
	# Untouched: neither side of the refused move was mutated.
	[ -d "$ROOT/work/demo/.git" ]
	[ -f "$ROOT/work/demo/demo/stray-file" ]
	# But the config WAS already written -- config-first is the point (a
	# declined/refused move must never leave an unexplained state).
	[ -f "$PROJDIR/demo.conf" ]
}

@test "project add --from refuses when a prior interrupted move's temp dir is still there" {
	mk_checkout demo https://example.com/demo.git
	mkdir -p "$ROOT/work/.mackas-migrating-demo"
	mk_add project add demo --from demo
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "an earlier move of 'demo' was interrupted"
	printf '%s\n' "$output" | grep -qF "$ROOT/work/.mackas-migrating-demo"
	# Untouched: refused before any mutation.
	[ -d "$ROOT/work/demo/.git" ]
	[ -d "$ROOT/work/.mackas-migrating-demo" ]
}

@test "project add --from refuses to move a workspace reached through a symlink" {
	mk_checkout real-demo https://example.com/demo.git
	ln -s "$ROOT/work/real-demo" "$ROOT/work/demo"
	mk_add project add demo --from demo
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "is a symlink -- refusing to move"
	# Untouched: the symlink and its target are exactly as they were.
	[ -L "$ROOT/work/demo" ]
	[ -d "$ROOT/work/real-demo/.git" ]
}

@test "project add --from on an already-converted project offers nothing (no-op)" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "moved the checkout"

	# Re-running --from demo now dies at introspection (adopt_introspect_project
	# requires a .git directly at work/demo, which no longer exists once
	# converted) -- unrelated pre-existing behaviour, not this slice's own
	# refusal. What matters here is that the migration block itself does not
	# fire a SECOND time and nothing under work/demo/demo is touched.
	mk_add project add demo --from demo
	[ "$status" -ne 0 ]
	[ -d "$ROOT/work/demo/demo/.git" ]
	! printf '%s\n' "$output" | grep -qF "moved the checkout"
}

@test "'mackas projects' flags a pin whose checkout is still in the pre-M6 flat layout" {
	mk_checkout demo https://example.com/demo.git
	# Write the pin directly, the same shape 'project add' itself writes,
	# without going through 'project add --from' -- that would immediately
	# offer (and, under this suite's -y, perform) the very move this test
	# means to catch BEFORE it happens.
	pin demo <<-EOF
	MACKAS_ROOT='$ROOT'
	MACKAS_PROJECT_DIR='demo'
	EOF

	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "legacy layout"
	printf '%s\n' "$output" | grep -qF "$ROOT/work/demo"
}

@test "'mackas projects' does not flag a pin once its checkout is migrated" {
	mk_checkout demo https://example.com/demo.git
	mk_add project add demo --from demo
	[ "$status" -eq 0 ]
	[ -d "$ROOT/work/demo/demo/.git" ]

	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qi "legacy layout"
}

@test "cmd_project_add blocks INT/TERM across its move (source-grep: bats cannot trigger a signal mid-mv)" {
	# AGENTS.md: logic only set -e/signal handling can reach is pinned by
	# source-grep, not a pretend runtime test. Scoped to cmd_project_add's
	# own body so this cannot pass on the strength of cmd_volume_move's or
	# on_interrupt's OWN identical idiom elsewhere in the file.
	sed -n '/^cmd_project_add() {/,/^}/p' "$MACKAS" > "$TESTDIR/fn.txt"
	grep -qF "trap '' INT TERM" "$TESTDIR/fn.txt"
	grep -qF "trap on_interrupt INT TERM" "$TESTDIR/fn.txt"
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
# --keep-volumes under an ACTIVE, DIFFERENT project selector: $MACKAS_VOLUME_NAME
# is only resolved to that OTHER project's own derived stem, never to
# anything this checkout actually built with -- 'keep' must refuse rather
# than silently pin the new project to the wrong volumes (found while
# reviewing #77: this used to write MACKAS_VOLUME_NAME='mackas-other' into
# demo.conf with no warning at all).
# ---------------------------------------------------------------------------

@test "project add --from --keep-volumes, run under a DIFFERENT project's active selector, is refused" {
	pin other <<'EOF'
EOF
	mk_checkout demo https://example.com/demo.git
	mk_add --project other project add demo --from demo --keep-volumes
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "cannot tell what 'demo' was already built with"
	[ ! -e "$PROJDIR/demo.conf" ]
}

@test "project add --from, non-interactive default, run under a DIFFERENT project's active selector, is refused rather than guessing" {
	pin other <<'EOF'
EOF
	mk_checkout demo https://example.com/demo.git
	# No --keep-volumes/--derive-volumes at all: the non-interactive default
	# would normally be 'keep', but that default is exactly what is unsafe
	# here -- it must refuse instead of silently choosing either answer.
	mk_add --project other project add demo --from demo
	[ "$status" -ne 0 ]
	[ ! -e "$PROJDIR/demo.conf" ]
}

@test "project add --from --derive-volumes, run under a DIFFERENT project's active selector, is unaffected" {
	pin other <<'EOF'
EOF
	mk_checkout demo https://example.com/demo.git
	# --derive-volumes never consults MACKAS_VOLUME_NAME's current value, so
	# the ambiguity that blocks --keep-volumes above does not apply to it.
	mk_add --project other project add demo --from demo --derive-volumes
	[ "$status" -eq 0 ]
	! grep -q '^MACKAS_VOLUME_NAME=' "$PROJDIR/demo.conf"
}

@test "project add --from --keep-volumes, selecting THIS SAME project being (re-)pinned, is unaffected" {
	pin demo <<EOF
MACKAS_ROOT='$ROOT'
MACKAS_PROJECT_DIR='demo'
EOF
	mk_checkout demo https://example.com/demo.git
	# PROJECT_SELECTED == the name being pinned: MACKAS_VOLUME_NAME resolves
	# to mackas-demo (demo's own derived default), which is trivially safe
	# either way -- must not be refused by the new guard.
	mk_add --project demo project add demo --from demo --keep-volumes
	[ "$status" -eq 0 ]
}

@test "project add --from --keep-volumes, active selector's OWN config pins an explicit stem colliding with it, is now refused (closes the #77 cross-project tmp collision gap)" {
	pin other <<'EOF'
MACKAS_VOLUME_NAME='mackas-explicit-other'
EOF
	mk_checkout demo https://example.com/demo.git
	# other's stem is EXPLICIT (config_pinned_setting is true), so
	# want_explicit_stem correctly carries it forward -- but tmp is never a
	# sharing surface (#72), so the cross-project collision guard added
	# alongside this test refuses outright rather than silently pinning
	# 'demo' to the exact same -tmp/-dl/-sstate volumes 'other' already
	# owns. This closes what used to be a known, deliberately deferred gap
	# (see the M3 integration review that first flagged it).
	mk_add --project other project add demo --from demo --keep-volumes
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "already.*other.*build volume"
	[ ! -e "$PROJDIR/demo.conf" ]
}

# ---------------------------------------------------------------------------
# dl/sstate collisions: unlike tmp, sharing them is a real opt-in M1 feature,
# so a collision here WARNS rather than refuses -- loud enough that this
# exact bug class cannot happen silently, but without breaking a deliberate
# 'MACKAS_VOLUME_DL_NAME=mackas-shared-dl'-style choice.
# ---------------------------------------------------------------------------

@test "project add inheriting a DIFFERENT project's explicit MACKAS_VOLUME_DL_NAME warns but still writes it" {
	pin other <<'EOF'
MACKAS_VOLUME_DL_NAME='mackas-shared-dl'
EOF
	mk_add --project other project add newname --url https://example.com/x.git --branch main
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "note:.*share a cache volume"
	printf '%s\n' "$output" | grep -qF "mackas-shared-dl"
	grep -qxF "MACKAS_VOLUME_DL_NAME='mackas-shared-dl'" "$PROJDIR/newname.conf"
}

@test "project add with no dl/sstate collision shows no sharing note" {
	pin other <<'EOF'
EOF
	mk_add --project other project add newname --url https://example.com/x.git --branch main
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qF "share a cache volume"
}

@test "project add tmp-collision refusal and dl-collision warning are independent of --dry-run" {
	pin other <<'EOF'
MACKAS_VOLUME_NAME='mackas-explicit-other'
EOF
	mk_checkout demo https://example.com/demo.git
	mk_add --dry-run --project other project add demo --from demo --keep-volumes
	[ "$status" -ne 0 ]
	[ ! -e "$PROJDIR/demo.conf" ]
}

@test "project add colliding on tmp via the fresh (non---from) path is refused the same way" {
	pin other <<'EOF'
MACKAS_VOLUME_NAME='mackas-explicit-other'
EOF
	mk_add --project other project add newname --url https://example.com/x.git --branch main
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "already.*other.*build volume"
	[ ! -e "$PROJDIR/newname.conf" ]
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
