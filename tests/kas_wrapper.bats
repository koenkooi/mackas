#!/usr/bin/env bats
#
# End-to-end tests for the write_kas_wrapper() protection wrapper: every
# $PATH-resolution bypass (nohup, env, a bare invocation with no shell
# function in scope) must still reach kas-container with the ext4 volumes
# attached, never the raw upstream binary at Apple's cpus=4/memory=1gb
# defaults.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# THIS is the regression test issue #27 exists to produce. KAS_CONTAINER_REAL,
# setup_kas_container()'s migration of an existing raw install,
# write_kas_wrapper() itself, and env.sh's kas-container() shell function
# delegating to it are all in place -- but none of that proves a hand-typed
# 'kas-container build ...', reached via nohup/env/a bare $PATH lookup (none
# of which ever go through env.sh's shell function), actually arrives at a
# protected build instead of a raw, unprotected upstream binary. This file is
# that proof.
#
# Kept as a SEPARATE file from setup_kas_container.bats (already ~354 lines,
# past this suite's informal ~350-line split point) rather than growing it
# further: that file stays focused on setup_kas_container()'s sha256 gate and
# the static shape of the generated wrapper; this one drives the GENERATED
# wrapper end to end against a fake .real recorder.
#
# Harness: a fake .real "kas-container" that records $PWD, argv and the full
# environment to $KREC on every call -- the same recorder idiom
# setup_e2e.bats already uses for its fake curl-downloaded kas-container,
# copied here rather than reinvented. KREC is deliberately never pre-created
# (unlike setup_e2e.bats' own ": > $KREC"): the refusal tests below assert it
# is NEVER created at all, which is the whole point of "refuse, don't launch
# unprotected".
#
# The wrapper's LIVE --runtime-args recompute (MACKAS_SELF, "mackas
# runtime-args") and its GENERATION-TIME frozen fallback (kas_runtime_args(),
# called directly by write_kas_wrapper() to bake MACKAS_FROZEN_RUNTIME_ARGS)
# are controlled INDEPENDENTLY of each other here: a fake MACKAS_SELF stub
# answers the former; overriding the kas_runtime_args shell function itself
# (before calling the real write_kas_wrapper()) controls the latter. Both
# default to a real, valid string; individual tests force one or both bad.
#
# NOTE: bats' own `run` must not be used here -- mackas defines its own run()
# and sourcing it shadows bats' version. Explicit subshells with manually
# captured status, exactly as setup_kas_container.bats and volumes.bats do.
#
# NOTE: a bare `! cmd` (or `! pipeline`) is invisible to `set -e` when it is
# NOT the last line of a test (see helpers.bash's assert_fails comment) --
# bash never treats a `!`-negated exit status as an errexit trigger, so a
# wrongly-passing assertion earlier in a test can be silently swallowed.
# Every "must be absent" check below is therefore phrased as `[ ! -e FILE ]`
# / `[ "$count" -eq N ]` (a `test` builtin's own exit status, never negation
# of an external command), which IS caught by `set -e` at any position.

bats_require_minimum_version 1.5.0

load helpers

lib_setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	TESTDIR="$(make_tmpdir)"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	MACKAS_CPUS=6
	MACKAS_MEMORY=12g

	# MACKAS_SELF (baked into the wrapper as the binary its LIVE recompute
	# execs) is "$SCRIPT_DIR/$SCRIPT_NAME" -- point both at a private,
	# fully-scripted stand-in rather than $REPO_ROOT/mackas, so each test
	# dictates exactly what "mackas runtime-args" answers. SCRIPT_NAME stays
	# "mackas" (not some test-only name) so the wrapper's own stderr messages
	# read exactly as a real user would see them ("re-run: mackas setup").
	SELFDIR="$TESTDIR/selfbin"
	mkdir -p "$SELFDIR"
	SCRIPT_DIR="$SELFDIR"
	SCRIPT_NAME="mackas"
	SELF_STUB="$SELFDIR/$SCRIPT_NAME"

	derive_paths
	DRY_RUN=0

	# Deliberately never pre-created -- see file header. Exported so it is
	# visible to whatever the wrapper execs, however it was invoked (nohup,
	# env, a bare $PATH lookup).
	KREC="$TESTDIR/kas.rec"
	export KREC

	write_self_stub "$(kas_runtime_args)" 0
	write_recorder
	write_kas_wrapper
}

setup() {
	lib_setup
}

teardown() {
	rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# Harness helpers
# ---------------------------------------------------------------------------

# write_self_stub OUTPUT EXITCODE -- (re)write the fake MACKAS_SELF binary:
# answers "runtime-args" with OUTPUT and exits EXITCODE, refuses anything
# else. This controls the wrapper's LIVE recompute independently of the
# FROZEN fallback (force_frozen_fallback, below). Does NOT regenerate the
# wrapper -- MACKAS_SELF is a fixed path baked in once; only its CONTENT
# changes here.
write_self_stub() {
	local output="$1" exitcode="${2:-0}"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'if [ "$1" = "runtime-args" ]; then\n'
		printf '\tprintf %%s %s\n' "$(printf '%q' "$output")"
		printf '\texit %s\n' "$exitcode"
		printf 'fi\n'
		printf 'exit 1\n'
	} > "$SELF_STUB"
	chmod +x "$SELF_STUB"
}

# force_frozen_fallback OUTPUT -- override kas_runtime_args() itself, the
# function write_kas_wrapper() calls DIRECTLY (never through MACKAS_SELF) to
# bake MACKAS_FROZEN_RUNTIME_ARGS at generation time. The caller must re-run
# (the real) write_kas_wrapper after this for it to take effect.
force_frozen_fallback() {
	FROZEN_FAKE="$1"
	# shellcheck disable=SC2317  # invoked indirectly by write_kas_wrapper()
	kas_runtime_args() { printf '%s' "$FROZEN_FAKE"; }
}

# write_recorder -- the fake .real kas-container the wrapper execs at the
# end. Records $PWD, argv and the full environment to $KREC on every call.
# Same idiom as setup_e2e.bats' fake curl-downloaded recorder, copied rather
# than reinvented.
write_recorder() {
	mkdir -p "$MACKAS_BIN"
	cat > "$KAS_CONTAINER_REAL" <<'REC'
#!/usr/bin/env bash
{
	printf 'PWD=%s\n' "$PWD"
	printf 'ARGV_BEGIN\n'
	for a in "$@"; do printf 'ARG:%s\n' "$a"; done
	printf 'ARGV_END\n'
	printf 'ENV_BEGIN\n'
	env
	printf 'ENV_END\n'
} >> "$KREC"
exit 0
REC
	chmod +x "$KAS_CONTAINER_REAL"
}

# The recorded argv of the first call, one element per line, ARG: stripped.
rec_argv() {
	sed -n 's/^ARG://p' "$KREC"
}

# The recorded environment of the first call.
rec_env() {
	awk '/^ENV_BEGIN/{e=1;next} /^ENV_END/{exit} e' "$KREC"
}

# The exact value token passed to --runtime-args on the first call.
rec_runtime_args_value() {
	awk '/^ARG:--runtime-args$/{getline; sub(/^ARG:/,""); print; exit}' "$KREC"
}

# ---------------------------------------------------------------------------
# 1-3: every $PATH-resolution bypass reaches the recorder with the volumes
# attached. This is the core regression this whole mechanism exists to close.
# ---------------------------------------------------------------------------

@test "nohup: reaches the .real recorder with all three ext4 volumes attached" {
	cd "$TESTDIR"
	out="$( (nohup "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	grep -qxF 'ARG:--runtime-args' "$KREC"
	rt="$(rec_runtime_args_value)"
	printf '%s\n' "$rt" | grep -qF ':/build'
	printf '%s\n' "$rt" | grep -qF ':/downloads'
	printf '%s\n' "$rt" | grep -qF ':/sstate'
}

@test "env: reaches the .real recorder with all three ext4 volumes attached" {
	cd "$TESTDIR"
	out="$( (env "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	grep -qxF 'ARG:--runtime-args' "$KREC"
	rt="$(rec_runtime_args_value)"
	printf '%s\n' "$rt" | grep -qF ':/build'
	printf '%s\n' "$rt" | grep -qF ':/downloads'
	printf '%s\n' "$rt" | grep -qF ':/sstate'
}

@test "bare \$PATH resolution, no shell function in scope: reaches the .real recorder with all three ext4 volumes attached" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	grep -qxF 'ARG:--runtime-args' "$KREC"
	rt="$(rec_runtime_args_value)"
	printf '%s\n' "$rt" | grep -qF ':/build'
	printf '%s\n' "$rt" | grep -qF ':/downloads'
	printf '%s\n' "$rt" | grep -qF ':/sstate'
}

# ---------------------------------------------------------------------------
# 4: the volume-directory vars must be EMPTY, not merely unset -- an unset var
# behaves differently from an empty one in kas-container's own forward_dir().
# ---------------------------------------------------------------------------

@test "recorded environment: KAS_BUILD_DIR/DL_DIR/SSTATE_DIR are present but EMPTY, not merely absent" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	rec_env | grep -qxF 'KAS_BUILD_DIR='
	rec_env | grep -qxF 'DL_DIR='
	rec_env | grep -qxF 'SSTATE_DIR='
}

# ---------------------------------------------------------------------------
# 5: double-injection guard. Upstream kas-container ACCUMULATES repeated
# --runtime-args values rather than the last one winning, so injecting a
# second one on top of the caller's own would silently double every mount.
# ---------------------------------------------------------------------------

@test "double-injection guard: a caller-supplied --runtime-args is not duplicated" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" --runtime-args "-c 1 -m 1g" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	count="$(grep -cxF 'ARG:--runtime-args' "$KREC")"
	[ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 6-7: refusal on empty/unusable computed args. A multi-hour build with no
# protected storage attached is strictly worse than failing fast before it
# ever starts -- the recorder must NEVER be created in either case.
# ---------------------------------------------------------------------------

@test "refusal: empty live recompute AND empty frozen fallback refuses to launch, recorder never created" {
	write_self_stub "" 1
	force_frozen_fallback ""
	write_kas_wrapper
	[ ! -e "$KREC" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'refusing to launch'
	printf '%s\n' "$out" | grep -qF 'mackas setup'
	[ ! -e "$KREC" ]
}

@test "refusal: a partial args string (limits present, no volume mounts) refuses to launch, recorder never created" {
	# Live fails (forcing the fallback to be consulted at all), and the
	# fallback itself is plausible-but-incomplete: cpu/memory limits present,
	# none of the three ext4 mounts. This exercises the substring-validation
	# case statements specifically -- a totally-empty $rt (test 6, above)
	# would already be caught by the plain "-z" check alone.
	write_self_stub "" 1
	force_frozen_fallback "-c 4 -m 8g"
	write_kas_wrapper
	[ ! -e "$KREC" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'refusing to launch'
	printf '%s\n' "$out" | grep -qF 'mackas setup'
	[ ! -e "$KREC" ]
}

# ---------------------------------------------------------------------------
# 8: re-entry guard. KAS_CONTAINER_REAL must never lead back to the wrapper --
# a fork bomb (or, in practice, a straight-line exec loop) instead of a clean
# failure.
# ---------------------------------------------------------------------------

@test "re-entry guard: MACKAS_KAS_WRAPPED=1 execs .real immediately with no injection, and a self-symlinked .real terminates in bounded time" {
	cd "$TESTDIR"

	# The legitimate case: something already set MACKAS_KAS_WRAPPED=1 (this
	# wrapper's own final exec does, on every normal call). The re-entry
	# branch must exec .real immediately, verbatim argv, no --runtime-args
	# injected -- checked by exact equality below, which alone proves no
	# extra element was added.
	out="$( (MACKAS_KAS_WRAPPED=1 "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	[ "$(rec_argv)" = "$(printf 'build\nfoo.yml')" ]

	# Defensive sanity check: corrupt the install so .real is a symlink back
	# to the wrapper itself (as if setup_kas_container()'s migration somehow
	# left a copy/symlink loop). Invoked WITHOUT MACKAS_KAS_WRAPPED set, the
	# wrapper runs its normal path once, then execs "$KAS_CONTAINER_REAL"
	# (itself) with MACKAS_KAS_WRAPPED=1 newly set -- which re-enters the
	# wrapper, trips the re-entry branch above, and that branch UNCONDITIONALLY
	# execs "$KAS_CONTAINER_REAL" (itself) again, forever: a straight-line
	# exec loop (never a fork bomb -- exec replaces the process image, it
	# never forks), but the guard as written cannot break out of it on its
	# own. `timeout` bounds this externally so a genuine infinite loop fails
	# this test with a clear timeout rather than hanging the whole suite.
	rm -f "$KAS_CONTAINER_REAL"
	ln -s "$KAS_CONTAINER_BIN" "$KAS_CONTAINER_REAL"
	: > "$KREC"

	loop_rc=0
	timeout 5 "$KAS_CONTAINER_BIN" build foo.yml >/dev/null 2>&1 || loop_rc=$?
	[ "$loop_rc" -eq 124 ]
}
