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
# runtime-args --require-volumes-free") is the wrapper's ONLY source for that
# string since issue #96 -- there is no frozen fallback baked into the
# generated file any more, so a fake MACKAS_SELF stub is the only knob these
# tests need. It defaults to a real, valid string and a zero exit; individual
# tests make it fail the way a real 'mackas' would when a guard refuses
# (message on stderr, non-zero exit, nothing on stdout).
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

	# The MACKAS_SELF stub's own argv log -- unlike KREC this one IS
	# pre-created, since tests read it for the flags the wrapper passed rather
	# than asserting it never came into existence.
	SELF_REC="$TESTDIR/self.rec"
	export SELF_REC
	: > "$SELF_REC"

	write_self_stub "$(kas_runtime_args)" 0
	write_recorder
	write_container_mock
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

# write_self_stub OUTPUT EXITCODE [STDERR] -- (re)write the fake MACKAS_SELF
# binary: answers "runtime-args" with OUTPUT on stdout, STDERR (if given) on
# stderr, and exits EXITCODE; refuses anything else. Every call's argv, and
# the $MACKAS_PROJECT_SELECT it was handed, are appended to $SELF_REC, so a
# test can assert WHICH flags and WHICH project the wrapper passed. The
# '<unset>' marker keeps "never passed" distinguishable from "passed empty",
# which is the whole difference between inheriting the calling shell's
# selector and overriding it.
# Does NOT regenerate the wrapper -- MACKAS_SELF is a fixed path baked in
# once; only its CONTENT changes here.
write_self_stub() {
	local output="$1" exitcode="${2:-0}" errmsg="${3:-}"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'printf "ARGV:%%s\\n" "$*" >> "$SELF_REC"\n'
		printf 'printf "SEL:%%s\\n" "${MACKAS_PROJECT_SELECT-<unset>}" >> "$SELF_REC"\n'
		printf 'if [ "$1" = "runtime-args" ]; then\n'
		if [ -n "$errmsg" ]; then
			printf '\tprintf "%%s\\n" %s >&2\n' "$(printf '%q' "$errmsg")"
		fi
		printf '\tprintf %%s %s\n' "$(printf '%q' "$output")"
		printf '\texit %s\n' "$exitcode"
		printf 'fi\n'
		printf 'exit 1\n'
	} > "$SELF_STUB"
	chmod +x "$SELF_STUB"
}

# write_container_mock -- a fake `container` on $PATH answering "system
# status"/"system start", the same daemon-check the wrapper now runs before
# ever handing off to .real (issue #33). Without this, the wrapper's
# unconditional `container system status` call would reach the REAL Apple
# container CLI, since nothing else in this file puts a fake one on $PATH.
# Default: always "running", matching every pre-existing test's assumption
# that the daemon is up and 'system start' is never called. A test that
# wants the down-then-recovers or down-forever cases sets MOCK_CONTAINER_DOWN
# =1 (and, for the recovers case, CONTAINER_STARTED_MARKER) before invoking
# the wrapper.
write_container_mock() {
	mkdir -p "$TESTDIR/fakebin"
	CONTAINER_LOG="$TESTDIR/container.rec"
	export CONTAINER_LOG
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
printf 'CALL: %s\n' "$*" >> "$CONTAINER_LOG"
if [ "$1 $2" = "system status" ]; then
	if [ "${MOCK_CONTAINER_DOWN:-0}" = "1" ] && [ ! -f "${CONTAINER_STARTED_MARKER:-/nonexistent-marker-xyzzy}" ]; then
		exit 1
	fi
	echo "status running"
	exit 0
fi
if [ "$1 $2" = "system start" ]; then
	[ -n "${CONTAINER_STARTED_MARKER:-}" ] && touch "$CONTAINER_STARTED_MARKER"
	exit 0
fi
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
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

# The recorded value of ONE variable out of that environment. First match only:
# an exported bash function spans several lines, so a later line could
# otherwise be mistaken for a second definition.
rec_env_var() {
	rec_env | sed -n "s/^$1=//p" | head -1
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
# 6-7: refusal on a failed or unusable live recompute. A multi-hour build
# with no protected storage attached -- or with SOMEONE ELSE'S storage
# attached, which is what reusing setup-time values can mean once volume
# names are configurable (M1) or derived (M3) -- is strictly worse than
# failing fast before it ever starts. The recorder must NEVER be created.
# ---------------------------------------------------------------------------

@test "refusal: a failed live recompute is FATAL, not a fallback -- recorder never created (issue #96)" {
	# Exactly how a real 'mackas' refuses: its die() message on stderr, a
	# non-zero exit, nothing on stdout. The wrapper used to warn and build on
	# the frozen copy; there is no frozen copy any more, and this is the test
	# that keeps one from coming back.
	write_self_stub "" 1 "mackas: error: volume 'oe-build-dl' is attached to a running container"
	[ ! -e "$KREC" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	# mackas's own message reaches the terminal verbatim -- the wrapper adds
	# context, it never swallows or paraphrases the diagnosis.
	printf '%s\n' "$out" | grep -qF "volume 'oe-build-dl' is attached to a running container"
	printf '%s\n' "$out" | grep -qi 'refusing to launch'
	printf '%s\n' "$out" | grep -qi 'not falling back'
	[ ! -e "$KREC" ]
}

@test "refusal: the live recompute is asked for the one-VM check, not just the args string (issue #96)" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	# Both flags, on ONE recompute: the one-VM check and the identity check
	# ride the same call. The work dir varies per test dir, so match the shape.
	grep -qE '^ARGV:runtime-args --require-volumes-free --expect-work /' "$SELF_REC"
}

@test "refusal: a partial args string (limits present, no volume mounts) refuses to launch, recorder never created" {
	# A live recompute that SUCCEEDS but answers something plausible-but-
	# incomplete: cpu/memory limits present, none of the three ext4 mounts --
	# a stale/incompatible mackas, which a non-zero exit status cannot catch.
	# This exercises the substring-validation case statements specifically; a
	# totally-empty answer would already be caught by the plain "-z" check.
	write_self_stub "-c 4 -m 8g" 0
	[ ! -e "$KREC" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'refusing to launch'
	printf '%s\n' "$out" | grep -qF 'mackas setup'
	[ ! -e "$KREC" ]
}

@test "refusal: an empty answer with a ZERO exit status still refuses, recorder never created" {
	write_self_stub "" 0
	[ ! -e "$KREC" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'refusing to launch'
	[ ! -e "$KREC" ]
}

@test "no frozen fallback: the generated wrapper bakes in no --runtime-args string at all (issue #96)" {
	# A source-level pin, not a behavioural one: as long as the setup-time
	# string is not IN the file, no future edit can quietly start using it
	# again. The volume names are the part that must not be frozen.
	assert_fails grep -q 'MACKAS_FROZEN_RUNTIME_ARGS' "$KAS_CONTAINER_BIN"
	assert_fails grep -qF -- "-v $MACKAS_VOL_TMP:/build" "$KAS_CONTAINER_BIN"
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

# ---------------------------------------------------------------------------
# 9: auto-start the container runtime (issue #33). A hand-typed kas-container
# invocation gets the same container_running-then-start treatment mackas's
# own shell/exec/smoketest do, instead of whatever raw error the daemon-down
# state produces.
# ---------------------------------------------------------------------------

@test "auto-start: runtime already up, no 'system start' is ever called" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	! grep -q 'system start' "$CONTAINER_LOG"
}

@test "auto-start: runtime down at invocation, comes up after 'system start', reaches the recorder" {
	MOCK_CONTAINER_DOWN=1
	CONTAINER_STARTED_MARKER="$TESTDIR/container-started"
	export MOCK_CONTAINER_DOWN CONTAINER_STARTED_MARKER
	[ ! -e "$CONTAINER_STARTED_MARKER" ]

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF 'CALL: system start' "$CONTAINER_LOG"
	[ -e "$CONTAINER_STARTED_MARKER" ]
	[ -e "$KREC" ]
	rt="$(rec_runtime_args_value)"
	printf '%s\n' "$rt" | grep -qF ':/build'
}

@test "auto-start: runtime stays down after 'system start', wrapper refuses with a clear message, recorder never created" {
	MOCK_CONTAINER_DOWN=1
	export MOCK_CONTAINER_DOWN
	# No CONTAINER_STARTED_MARKER set: the mock's "system status" always
	# fails, so 'system start' can never bring it up.

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -qi 'container system did not start'
	printf '%s\n' "$out" | grep -qF 'container system status'
	grep -qF 'CALL: system start' "$CONTAINER_LOG"
	[ ! -e "$KREC" ]
}

# ---------------------------------------------------------------------------
# 10: MACKAS_KAS_FRAGMENT_DONE dedup. The wrapper's own "this did not go
# through env.sh" note must agree with what env.sh's kas-container() shell
# function actually does -- it sets MACKAS_KAS_FRAGMENT_DONE=1 right before
# handing off to this same generated wrapper (see mackas's kas-container()
# function, and tests/volumes.bats' "kas-container function: delegates to
# the wrapper -- one call, FRAGMENT_DONE=1..." for the function-side half of
# this pin: that test proves the function sets exactly "1"; this one proves
# the wrapper's note is gated on exactly that value). Together the two
# cannot silently drift apart -- if either side ever changes the literal
# value, one of the two tests catches it.
#
# Neither call sets MACKAS_KAS_WRAPPED, so the unrelated re-entry guard
# (test 8, above) never short-circuits this: both calls run the wrapper's
# full normal path down to the FRAGMENT_DONE check.
# ---------------------------------------------------------------------------

@test "FRAGMENT_DONE dedup: MACKAS_KAS_FRAGMENT_DONE=1 (as env.sh's kas-container() function sets it) silences the bypass note; unset (a direct invocation) still prints it" {
	cd "$TESTDIR"

	# Shell-function-routed path, simulated the same way env.sh's
	# kas-container() function itself hands off: FRAGMENT_DONE already 1.
	out="$( (MACKAS_KAS_FRAGMENT_DONE=1 "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	! printf '%s\n' "$out" | grep -qF 'did not go through the env.sh shell function'
	rm -f "$KREC"

	# Direct generated-wrapper path: nothing set FRAGMENT_DONE, so the note
	# must still print -- this is the whole point of the wrapper existing.
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	printf '%s\n' "$out" | grep -qF 'did not go through the env.sh shell function'
}

# ---------------------------------------------------------------------------
# 11: the exec line's PATH. Nothing read this line until it grew a seam: the
# Homebrew dir was a hardcoded literal, and turning it into $BREW_BIN put it
# back inside a raw "..." -- the exact injection setup_shim_and_env()'s own
# comment records as already fixed once, in the other generated file.
# ---------------------------------------------------------------------------

@test "PATH: the shim comes first, then the Homebrew dir, then the caller's own PATH" {
	# The shim must outrank /usr/local/bin's real Docker CLI, and the Homebrew
	# dir must outrank /usr/bin's BSD realpath -- both only if this order holds.
	cd "$TESTDIR"
	out="$( (PATH="/marker-dir-xyzzy:$PATH" "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	got="$(rec_env_var PATH)"
	case "$got" in
		"$SHIM_DIR:$BREW_BIN:/marker-dir-xyzzy:"*) ;;
		*) echo "wrapper PATH is not shim:brew:caller -- $got" >&2; return 1 ;;
	esac
}

@test "PATH: a hostile BREW_BIN lands inert instead of injecting into the wrapper" {
	# This writer shq()s every other value it bakes in. Measured before the
	# fix: the backtick below ran at every hand-typed kas-container invocation,
	# and the '"' ended the PATH string so .real was never reached at all.
	BREW_BIN='/opt/x`touch '"$TESTDIR"'/BREW-PWNED`"; touch '"$TESTDIR"'/BREW-PWNED2; :"'
	write_kas_wrapper
	/bin/sh -n "$KAS_CONTAINER_BIN"

	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ ! -e "$TESTDIR/BREW-PWNED" ]
	[ ! -e "$TESTDIR/BREW-PWNED2" ]

	# .real really was reached (a broken exec line stops short of it), and the
	# value arrived verbatim as one inert PATH entry.
	[ -e "$KREC" ]
	got="$(rec_env_var PATH)"
	case "$got" in
		"$SHIM_DIR:$BREW_BIN:"*) ;;
		*) echo "BREW_BIN did not survive generation intact: $got" >&2; return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# 12: the selector propagates into the live recompute.
#
# The wrapper freezes MACKAS_WORK/KAS_IMAGE/MACKAS_GITCONFIG from whatever
# config `setup` ran against, but recomputes --runtime-args on every call. If
# that recompute resolves a DIFFERENT config, the build gets one project's
# ext4 volumes beside another project's work dir -- on the hand-typed
# kas-container path, which is the primary real-world workflow. So the
# generated wrapper replays the project it was built for, and passes it
# EXPLICITLY even when empty, so an exported $MACKAS_PROJECT_SELECT in the
# calling shell cannot re-aim a wrapper at a project it was never built for.
# ---------------------------------------------------------------------------

@test "selector: a wrapper written under --project replays that project into the live recompute" {
	PROJECT_SELECTED="proj-a"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qxF 'SEL:proj-a' "$SELF_REC"
}

@test "selector: an exported \$MACKAS_PROJECT_SELECT cannot re-aim a wrapper built for another project" {
	PROJECT_SELECTED="proj-a"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR"
	out="$( (MACKAS_PROJECT_SELECT=proj-b "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qxF 'SEL:proj-a' "$SELF_REC"
	sel_b="$(grep -c '^SEL:proj-b$' "$SELF_REC" || true)"
	[ "$sel_b" -eq 0 ]
}

@test "selector: a wrapper written with no project passes an EMPTY selector, not the caller's" {
	# lib_setup left PROJECT_SELECTED empty, i.e. the default search path.
	# The recompute must still see an empty selector rather than inheriting
	# whatever the calling shell exported -- otherwise the same mismatch
	# appears in the other direction.
	cd "$TESTDIR"
	out="$( (MACKAS_PROJECT_SELECT=proj-b "$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qxF 'SEL:' "$SELF_REC"
	sel_b="$(grep -c '^SEL:proj-b$' "$SELF_REC" || true)"
	[ "$sel_b" -eq 0 ]
}

# #78 tier 3: a `mackas setup` run from inside a workspace that derivation
# alone selected must NOT freeze that selection into the wrapper -- the whole
# point of derivation is that it is recomputed per invocation from wherever
# the shell happens to stand, so baking today's answer in would replay it
# from every OTHER directory too. write_kas_wrapper() only bakes an EXPLICIT
# tier-1/2 selector (PROJECT_SELECT_SOURCE "--project" or
# "$MACKAS_PROJECT_SELECT"); anything else -- this derived case included --
# gets an empty pin, same as no selection at all.
@test "selector: a wrapper written under a DERIVED selection also passes an EMPTY selector" {
	PROJECT_SELECTED="proj-a"
	PROJECT_SELECT_SOURCE="derived from \$PWD"
	write_kas_wrapper
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qxF 'SEL:' "$SELF_REC"
	sel_a="$(grep -c '^SEL:proj-a$' "$SELF_REC" || true)"
	[ "$sel_a" -eq 0 ]
}

@test "selector: a project name with a shell metacharacter is baked in inert" {
	# PROJECT_SELECTED reaches the generated file through shq(), like every
	# other interpolated value. validate_project_select refuses this name at
	# the CLI; the point here is that write_kas_wrapper does not depend on
	# that check to keep the generated file from executing what it embeds.
	PROJECT_SELECTED="a'\$(touch $TESTDIR/pwned)b"
	PROJECT_SELECT_SOURCE="--project"
	write_kas_wrapper
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build foo.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ ! -e "$TESTDIR/pwned" ]
	grep -qxF "SEL:a'\$(touch $TESTDIR/pwned)b" "$SELF_REC"
}

# The wrapper freezes MACKAS_WORK/KAS_IMAGE/gitconfig but recomputes volumes
# LIVE, so a config resolving a different root would hand this build another
# project's ext4 volumes while its sources stay put. Identity is compared
# rather than the config path being frozen, so an ambient $MACKAS_CONF keeps
# working whenever it agrees and is refused only when it does not.

@test "the generated wrapper passes --expect-work with its frozen MACKAS_WORK" {
	grep -qF -- '--expect-work "$MACKAS_WORK"' "$MACKAS_BIN/kas-container"
}

# ---------------------------------------------------------------------------
# #78: the kas-chain hint. Standing in work/ itself, a hand-typed
# 'kas-container build meta-qcom/kas/a.yml:...' cannot be derived from $PWD
# alone -- so the wrapper's own leading-options scan (mirroring env.sh's
# kas-container() function) finds the file-list argument and forwards it,
# raw, as '--kas-files' on the SAME live-recompute call that already carries
# --require-volumes-free/--expect-work. Unit-level: a fake MACKAS_SELF
# records its own argv, so these assert WHAT THE WRAPPER FORWARDS without
# needing a real 'mackas' behind it -- tests/kas_chain_derive_e2e.bats is the
# companion file that drives a REAL mackas through this same wrapper end to
# end, per #78's own coverage requirement.
# ---------------------------------------------------------------------------

@test "kas-files hint: a plain 'build <chain>' forwards the chain verbatim" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build meta-qcom/kas/a.yml:meta-qcom/kas/b.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF -- '--kas-files meta-qcom/kas/a.yml:meta-qcom/kas/b.yml' "$SELF_REC"
}

@test "kas-files hint: 'shell' is scanned the same way as 'build'" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" shell meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF -- '--kas-files meta-qcom/kas/a.yml' "$SELF_REC"
}

@test "kas-files hint: leading --skip VALUE and -k are skipped to find the chain" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build --skip repos_checkout -k meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF -- '--kas-files meta-qcom/kas/a.yml' "$SELF_REC"
}

@test "kas-files hint: -c/--cmd's own VALUE (a string with a space) does not get mistaken for the chain" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" shell -c "bitbake -p" meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF -- '--kas-files meta-qcom/kas/a.yml' "$SELF_REC"
}

@test "kas-files hint: an absolute file list is forwarded raw too -- validation is mackas's job, not the wrapper's" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build /abs/path/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	grep -qF -- '--kas-files /abs/path/a.yml' "$SELF_REC"
}

@test "kas-files hint: an unknown leading option makes the wrapper back off -- no hint forwarded" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build --some-unknown-flag meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	! grep -qF -- '--kas-files' "$SELF_REC"
}

@test "kas-files hint: 'dump' is not scanned -- its positional is not a kas file list" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" dump meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	! grep -qF -- '--kas-files' "$SELF_REC"
}

@test "kas-files hint: with no positional at all (bare 'build'), nothing is forwarded" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	! grep -qF -- '--kas-files' "$SELF_REC"
}

@test "kas-files hint: the scan runs in a subshell -- \$@ reaching the final exec is untouched" {
	cd "$TESTDIR"
	out="$( ("$KAS_CONTAINER_BIN" build --skip repos_checkout -k meta-qcom/kas/a.yml) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; false; }
	[ -e "$KREC" ]
	rec_argv | grep -qxF 'build'
	rec_argv | grep -qxF -- '--skip'
	rec_argv | grep -qxF 'repos_checkout'
	rec_argv | grep -qxF -- '-k'
	rec_argv | grep -qxF 'meta-qcom/kas/a.yml'
}
