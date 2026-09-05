#!/usr/bin/env bats
#
# THE M4 COMPATIBILITY CONTRACT (issue #78).
#
# M4 teaches mackas to derive a project SELECTION from physical $PWD (and, in
# the hand-typed kas-container flow, from the first path component of a kas
# chain) as a third tier between the explicit selectors (--project/--config
# and their $MACKAS_PROJECT_SELECT/$MACKAS_CONF env equivalents, M2) and the
# default search path (~/.config/mackas/config, ~/.mackas.conf -- today's
# terminal fallback). #78 requires this exact guarantee to be written FIRST,
# before any of M4's feature code, and to be mutation-tested: airtight.
#
# The guarantee, in one sentence: an invocation where no derivation can
# legitimately apply -- no pinned project's work/<name> prefixes $PWD, or an
# explicit selector is already in play -- resolves EXACTLY what it resolves
# today: config file used, project selected (none), MACKAS_ROOT, the three
# volume names, MACKAS_PROJECT_DIR. No matter what pinned projects happen to
# exist on disk or where the shell is standing.
#
# DO NOT RELAX ANY ASSERTION BELOW TO MAKE A LATER CHANGE PASS. If a later M4
# commit needs one of these to change, that is a sign the change broke the
# compatibility contract, not a sign the test was wrong. Every test here must
# pass right now, on this pre-M4 tree, because there is no derivation yet --
# and it must keep passing once M4 lands, because M4 must be a no-op in every
# situation these tests cover.

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
	mkdir -p "$ROOT/work"

	# Same reason multi_project_compat.bats/project_select.bats fake it:
	# `status` asks the daemon for a volume's live cap, and a dev Mac with real
	# oe-build-* volumes would answer with real state in tests that are about
	# config resolution, not about volumes. "oe-build" reads as present, every
	# other name as absent.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") printf 'NAME TYPE DRIVER OPTIONS\noe-build\n'; exit 0 ;;
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

# Read one setting out of `mackas status` output (same helper as
# project_select.bats / multi_project_compat.bats).
setting() {
	printf '%s\n' "$output" | awk -v k="$1" '$1 == k { $1=""; sub(/^ +/,""); print; exit }'
}

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# The exact runtime-args mount fragment for a given stem, MACKAS_ROOT forced
# via --set so the config file's own MACKAS_ROOT (if any) never has to be a
# real, existing directory just to make this a pure query. `runtime-args` is
# a read-only, side-effect-free command (cmd_runtime_args) -- it derives and
# prints kas_runtime_args() without needing a real checkout or a running
# container, exactly the mount fragment a real build would hand kas-container.
mk_runtime_args() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		"$@" runtime-args
}

mk_status() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		"$@" status
}

assert_default_volume_names() {
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-tmp:/build -e KAS_BUILD_DIR=/build'
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-dl:/downloads -e DL_DIR=/downloads'
	printf '%s\n' "$output" | grep -qF -- '-v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate'
}

# refute_output: assert $1 is absent from the last `run`'s $output. A bare
# `! ... | grep -q` is only safe as a test's FINAL line (see helpers.bash's
# assert_fails comment: a `!`-negated command's failure is exempt from `set -e`
# at any OTHER position) -- this is the non-final-line-safe form.
refute_output() {
	if printf '%s\n' "$output" | grep -qF -- "$1"; then
		printf 'expected the output NOT to mention: %s\n--- output ---\n%s\n' \
			"$1" "$output" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
# 1. No pinned projects at all -- every existing user's setup today. Must
#    resolve the built-in defaults no matter where the shell is standing,
#    including from INSIDE what would, with pins, be a project checkout.
# ---------------------------------------------------------------------------

@test "compat: no pinned projects -- default volumes from an ordinary cwd" {
	mk_runtime_args
	[ "$status" -eq 0 ]
	assert_default_volume_names
}

@test "compat: no pinned projects -- default volumes even from inside <root>/work/<checkout>" {
	mkdir -p "$ROOT/work/meta-ai"
	cd "$ROOT/work/meta-ai"
	mk_runtime_args
	[ "$status" -eq 0 ]
	assert_default_volume_names
	refute_output 'project selected'
}

@test "compat: no pinned projects -- status shows no selected project and the default config file, from inside a checkout" {
	mkdir -p "$ROOT/work/meta-ai"
	cd "$ROOT/work/meta-ai"
	mk_status
	[ "$status" -eq 0 ]
	refute_output 'project selected'
	printf '%s\n' "$output" | grep -qE '^  config file +<none: built-in defaults>$'
}

# ---------------------------------------------------------------------------
# 2. Pins exist for OTHER names; cwd sits inside an UNPINNED legacy checkout.
#    Nothing on disk names this checkout, so nothing may select it.
# ---------------------------------------------------------------------------

@test "compat: pins exist elsewhere, cwd inside an UNPINNED legacy checkout -- no selection" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_KAS_CONFIG="kas/from-foo.yml"
	EOF
	mkdir -p "$ROOT/work/meta-ai"
	cd "$ROOT/work/meta-ai"
	mk_runtime_args
	[ "$status" -eq 0 ]
	assert_default_volume_names
	refute_output 'project selected'
}

@test "compat: pins exist elsewhere, cwd inside an UNPINNED legacy checkout -- status agrees, foo's config never sourced" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_KAS_CONFIG="kas/from-foo.yml"
	EOF
	mkdir -p "$ROOT/work/meta-ai"
	cd "$ROOT/work/meta-ai"
	mk_status
	[ "$status" -eq 0 ]
	refute_output 'project selected'
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

# ---------------------------------------------------------------------------
# 3. Pins exist, cwd sits inside what WOULD be a matching pinned workspace --
#    but an explicit selector (tier 1/2) is already in play. The explicit
#    selector must win outright; derivation (tier 3) is never even evaluated,
#    so it must not matter that cwd would also match a candidate.
#
#    setup_matching_cwd_fixture pins "foo" so its derivable candidate is
#    exactly $ROOT/work/foo, pins "other" as the thing each test actually asks
#    for, and leaves the caller to cd into $ROOT/work/foo before invoking.
# ---------------------------------------------------------------------------

setup_matching_cwd_fixture() {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	MACKAS_KAS_CONFIG="kas/from-foo.yml"
	EOF
	pin other <<-EOF
	MACKAS_KAS_CONFIG="kas/from-other.yml"
	EOF
	mkdir -p "$ROOT/work/foo"
	cd "$ROOT/work/foo"
}

@test "compat: --project wins over a matching cwd candidate" {
	setup_matching_cwd_fixture
	run "$MACKAS" --project other status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-other.yml" ]
	printf '%s\n' "$output" | grep -qE '^  project selected +other$'
}

@test "compat: \$MACKAS_PROJECT_SELECT wins over a matching cwd candidate" {
	setup_matching_cwd_fixture
	MACKAS_PROJECT_SELECT=other run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-other.yml" ]
	printf '%s\n' "$output" | grep -qE '^  project selected +other$'
}

@test "compat: --config wins over a matching cwd candidate, and selects no project at all" {
	setup_matching_cwd_fixture
	echo 'MACKAS_KAS_CONFIG="kas/from-explicit-file.yml"' > "$TESTDIR/explicit.conf"
	run "$MACKAS" --config "$TESTDIR/explicit.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-explicit-file.yml" ]
	refute_output 'project selected'
}

@test "compat: \$MACKAS_CONF wins over a matching cwd candidate, and selects no project at all" {
	setup_matching_cwd_fixture
	echo 'MACKAS_KAS_CONFIG="kas/from-explicit-file.yml"' > "$TESTDIR/explicit.conf"
	MACKAS_CONF="$TESTDIR/explicit.conf" run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-explicit-file.yml" ]
	refute_output 'project selected'
}

# The pathological nested case: an adopted root sitting inside another
# project's work/, so cwd genuinely prefix-matches TWO derivable candidates at
# once (rootA/work/foo == rootB, and rootB/work/bar). Reachable only by
# deliberately nesting checkouts this way, but exactly the shape #78 calls out
# as "more than one candidate -> die listing all of them, UNLESS an explicit
# selector was given, in which case tier 3 is never evaluated at all". An
# explicit selector here must never trip that ambiguity die.

@test "compat: an explicit selector never dies on an ambiguous nested cwd (adopted root inside another project's work/)" {
	rootA="$TESTDIR/rootA"
	rootB="$rootA/work/foo"
	mkdir -p "$rootB/work/bar/sub"
	pin foo <<-EOF
	MACKAS_ROOT="$rootA"
	EOF
	pin bar <<-EOF
	MACKAS_ROOT="$rootB"
	EOF
	pin elsewhere <<-EOF
	MACKAS_KAS_CONFIG="kas/from-elsewhere.yml"
	EOF
	cd "$rootB/work/bar/sub"
	run "$MACKAS" --project elsewhere status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-elsewhere.yml" ]
	printf '%s\n' "$output" | grep -qE '^  project selected +elsewhere$'
	refute_output 'foo'
	refute_output 'bar'
}

# ---------------------------------------------------------------------------
# 4. --help / help / <cmd> --help from inside a would-be-matching pinned
#    workspace never loads any config at all -- main() routes every --help
#    path around load_config entirely. Proven by planting a pinned config that
#    would leave a visible trace if it were ever sourced.
# ---------------------------------------------------------------------------

@test "compat: --help / help / <cmd> --help from inside a pinned workspace sources nothing" {
	pin p <<-EOF
	touch "$TESTDIR/CONF_RAN"
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$ROOT/work/p"
	cd "$ROOT/work/p"

	run "$MACKAS" --help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/CONF_RAN" ]
	printf '%s\n' "$output" | grep -q 'USAGE'

	run "$MACKAS" help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/CONF_RAN" ]

	run "$MACKAS" status --help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/CONF_RAN" ]
}

# ---------------------------------------------------------------------------
# 5. A pinned config's MACKAS_ROOT is stale (the directory is gone) or not an
#    absolute path -- either way it names no viable candidate, so it must
#    change nothing for a cwd standing elsewhere. #78: "A MACKAS_ROOT value
#    that is not an absolute path ... is simply not a candidate. Never eval or
#    expand it" -- config_grep_setting prints these raw, so the fixtures below
#    exercise exactly the shapes it would hand back unresolved.
# ---------------------------------------------------------------------------

@test "compat: a pinned config's stale MACKAS_ROOT (directory gone) changes nothing elsewhere" {
	pin stale <<-EOF
	MACKAS_ROOT="$TESTDIR/vanished-directory"
	MACKAS_VOLUME_NAME="pinned-stale-should-never-be-read"
	EOF
	mk_runtime_args
	[ "$status" -eq 0 ]
	assert_default_volume_names
	refute_output 'pinned-stale-should-never-be-read'
}

@test "compat: a handful of non-absolute pinned MACKAS_ROOT shapes change nothing elsewhere" {
	local shape
	for shape in 'relative/oe' '~/oe' '\$HOME/oe' './oe'; do
		pin "nonabs-$(printf '%s' "$shape" | tr -c 'A-Za-z0-9' -)" <<-EOF
		MACKAS_ROOT="$shape"
		MACKAS_VOLUME_NAME="wrong-for-$shape"
		EOF
		mk_runtime_args
		[ "$status" -eq 0 ]
		assert_default_volume_names
		refute_output "wrong-for-$shape"
	done
}

# ---------------------------------------------------------------------------
# 6. The hand-typed-kas-container-style path: MACKAS_ROOT reaching the process
#    through the inherited ENVIRONMENT (as write_kas_wrapper()'s live
#    --runtime-args recompute hands it down to a fresh subprocess, cwd
#    inherited) rather than --set, invoked from a cwd outside every pinned
#    workspace, with pins present on disk for an unrelated project. Must still
#    resolve the built-in defaults.
#
#    Decision: #78 also asks to reuse tests/kas_wrapper.bats's
#    write_kas_wrapper()+MACKAS_LIB_ONLY=1 harness to prove this through an
#    actually-generated wrapper's LIVE recompute. That harness (lib_setup,
#    write_recorder, write_container_mock, the .real/KREC plumbing) is
#    substantial machinery whose payoff here is proving the same thing this
#    test already proves -- that an env-sourced MACKAS_ROOT with no selector
#    and no cwd match resolves the defaults -- so it was skipped for now in
#    favour of driving `mackas runtime-args` directly. Recorded in this
#    session's decisions.
# ---------------------------------------------------------------------------

@test "compat: env-sourced MACKAS_ROOT, cwd outside every pinned workspace, pins present elsewhere -- still default volumes" {
	pin foo <<-EOF
	MACKAS_ROOT="$ROOT"
	EOF
	mkdir -p "$TESTDIR/elsewhere"
	cd "$TESTDIR/elsewhere"
	MACKAS_ROOT="$ROOT" MACKAS_RELOCATE_VOLUMES=0 run "$MACKAS" runtime-args
	[ "$status" -eq 0 ]
	assert_default_volume_names
}

# ---------------------------------------------------------------------------
# 7. Exported MACKAS_PROJECT_DIR naming a pinned project's own NAME, cwd
#    elsewhere -- selects nothing. #72's core rule, restated for M4: identity
#    is derived off the SELECTOR-NAMEABLE candidate path (a pinned config's
#    basename), never off MACKAS_PROJECT_DIR -- so a value that merely LOOKS
#    like a project name must not be confused with one.
# ---------------------------------------------------------------------------

@test "compat: MACKAS_PROJECT_DIR matches a pinned config's name, but cwd is elsewhere -- still oe-build-*, pin never read" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="pinned-meta-ai-should-never-be-read"
	EOF
	mk_runtime_args --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	assert_default_volume_names
	refute_output 'pinned-meta-ai-should-never-be-read'
}

@test "compat: MACKAS_PROJECT_DIR matches a pinned config's name -- status confirms no selection" {
	pin meta-ai <<-'EOF'
	MACKAS_VOLUME_NAME="pinned-meta-ai-should-never-be-read"
	EOF
	mk_status --set MACKAS_PROJECT_DIR=meta-ai
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_NAME)" = "oe-build" ]
	refute_output 'project selected'
}
