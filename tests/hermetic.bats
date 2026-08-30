#!/usr/bin/env bats
#
# Guards the hermeticity claim in AGENTS.md: for the four host tools mackas
# resolves by bare name -- `container`, `curl`, `mdfind`, `diskutil` -- no
# hermetic test may reach the real one.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# It was not true. mackas resolves those through PATH, and only the tests that
# wanted specific answers planted a fake; the rest fell through to the host.
# Measured on one `./run-tests.sh` before the stubs existed: 114 calls to a dev
# Mac's real /opt/homebrew/bin/container, 9 real HTTPS requests to ghcr.io, 66
# Spotlight queries and 24 `diskutil info` reads of the host's boot volume.
# Invisible while everything answers -- and with a wedged container apiserver,
# where every client call blocks forever, the whole run hung in the cli.bats
# group with no child process to blame.
#
# helpers.bash now puts tests/mock/bin at the front of PATH, and points
# MACKAS_BREW_BIN there too, for every file it does not name in
# MACKAS_TEST_REAL_FILES. These tests pin all of that: the stubs win over
# anything later on PATH AND over the Homebrew dir mackas prepends inside its
# own children, every file actually loads helpers, and the exemption list stays
# exactly the suites that self-skip without the opt-in. What a bats file cannot
# see from inside itself -- some OTHER file reaching past a stub -- run-tests.sh
# catches with recorders behind them.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_MACHINE
	export HOME="$TESTDIR"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# A directory holding a recorder for each guarded tool, appending its own name
# and argv to $1. Used to stand in for "a real one of these, reachable".
plant_poison() {
	local dir="$1" log="$2" tool
	mkdir -p "$dir"
	for tool in container curl mdfind diskutil; do
		cat > "$dir/$tool" <<-EOF
			#!/usr/bin/env bash
			printf '$tool %s\n' "\$*" >> "$log"
			exit 0
		EOF
		chmod +x "$dir/$tool"
	done
}

@test "hermetic: every guarded host tool on PATH is the suite's stub" {
	local tool
	for tool in container curl mdfind diskutil; do
		[ "$(command -v "$tool")" = "$MOCK_BIN/$tool" ]
	done
}

@test "hermetic: mackas' host-tool probes hit the stubs, not a real tool further down PATH" {
	# On a dev Mac the real container/curl/mdfind/diskutil all sit somewhere in
	# the ambient PATH. Stand in for them with recorders placed DIRECTLY behind
	# the stub dir -- ahead of /opt/homebrew/bin and /usr/bin, so they are the
	# next match for every one of these names. Appending them to the end of
	# PATH instead would prove nothing on any machine that has a real tool
	# earlier, which is every dev Mac.
	local stublog="$TESTDIR/stub.log" poisonlog="$TESTDIR/poison.log"
	plant_poison "$TESTDIR/nextbin" "$poisonlog"

	MACKAS_TEST_CONTAINER_LOG="$stublog" PATH="$MOCK_BIN:$TESTDIR/nextbin:$PATH" \
		run "$MACKAS" --set "MACKAS_ROOT=$TESTDIR/oe" status
	[ "$status" -eq 0 ]
	# Non-vacuous: status really does probe the runtime, so the stub was used.
	[ -f "$stublog" ]
	grep -qxF 'system status' "$stublog"
	[ ! -e "$poisonlog" ]
}

@test "hermetic: the Homebrew dir mackas prepends for its children cannot outrank the stubs" {
	# mackas puts a Homebrew bin dir ahead of the inherited PATH in every child
	# it launches, so kas-container finds GNU realpath before /usr/bin's BSD
	# one. Hardcoded, that dir outranked this suite's stub INSIDE the child --
	# a dev Mac's real `container` stayed reachable from the one code path the
	# stub exists to shadow, and neither the stub nor run-tests.sh's recorder
	# could see it. BREW_BIN/MACKAS_BREW_BIN is that dir; helpers.bash aims it
	# at MOCK_BIN.
	local resolved="$TESTDIR/child-resolved" poisonlog="$TESTDIR/poison.log"
	plant_poison "$TESTDIR/fakebrew" "$poisonlog"
	cat > "$TESTDIR/kas-container.real" <<-EOF
		#!/usr/bin/env bash
		command -v container > "$resolved"
	EOF
	chmod +x "$TESTDIR/kas-container.real"

	# kas_invoke_env() is the one place that invocation environment lives, so
	# calling it directly is calling the real thing. Sourcing mackas shadows
	# bats' run(), hence the explicit subshells.
	child_container() {
		rm -f "$resolved"
		(
			MACKAS_LIB_ONLY=1; export MACKAS_LIB_ONLY
			if [ -n "$1" ]; then
				MACKAS_BREW_BIN="$1"; export MACKAS_BREW_BIN
			fi
			# shellcheck disable=SC1090
			. "$MACKAS"
			setup_colors
			set_defaults
			MACKAS_ROOT="$TESTDIR/oe"
			MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
			derive_paths
			KAS_CONTAINER_REAL="$TESTDIR/kas-container.real"
			kas_invoke_env "" "$MACKAS_GITCONFIG" 0 --version
		)
		cat "$resolved"
	}

	# Non-vacuous on any machine, CI included: pointed at a directory with a
	# `container` of its own, the child must land THERE -- which is only true
	# if the seam really is the dir mackas prepends, ahead of MOCK_BIN. With
	# the old hardcoded value this answers /opt/homebrew/bin/container on a dev
	# Mac and $MOCK_BIN/container on CI; neither is this path.
	[ "$(child_container "$TESTDIR/fakebrew")" = "$TESTDIR/fakebrew/container" ]
	# And with what helpers.bash actually sets, the child lands on the stub.
	[ "$(child_container "")" = "$MOCK_BIN/container" ]
	[ ! -e "$poisonlog" ]
}

@test "hermetic: every bats file loads helpers, so none can miss the stubs" {
	local f missing=""
	for f in "$REPO_ROOT"/tests/*.bats; do
		grep -q '^load helpers$' "$f" || missing="$missing ${f##*/}"
	done
	[ -z "$missing" ]
}

@test "hermetic: the files exempt from the stubs are exactly the opt-in ones" {
	# helpers.bash hands the real tools to the files it names. A file that
	# does not self-skip without MACKAS_REAL_RUNTIME=1 must never be on that
	# list, and one that does must never be off it -- either way the suite
	# stops being what AGENTS.md says it is.
	# The bracket keeps this pattern from matching the line it is written on.
	local f optin=""
	for f in "$REPO_ROOT"/tests/*.bats; do
		if grep -qE 'skip "opt-in: set MACKAS_REAL_RUNTIME=[1]' "$f"; then
			optin="$optin ${f##*/}"
		fi
	done

	[ -n "$optin" ]
	[ "$(printf '%s\n' $optin | sort)" = "$(printf '%s\n' $MACKAS_TEST_REAL_FILES | sort)" ]
}

@test "hermetic: helpers exempts only the named files; an unknown name still gets the stubs" {
	# The exemption is decided once, off BATS_TEST_FILENAME, as helpers loads
	# -- a branch no single bats file can take both ways. Source helpers in a
	# plain shell with the filename faked and read back what it built.
	local probe="$TESTDIR/exemption.sh"
	cat > "$probe" <<'EOF'
# This file's own load already put MOCK_BIN on PATH; drop it, or every branch
# below reads as stubbed and the test proves nothing. MACKAS_BREW_BIN is
# deliberately left as this file's load set it -- helpers must UNSET it on the
# exempt path, not merely decline to set it, and that is only visible if it
# arrives already set.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$MOCK_BIN" | paste -sd: -)"
BATS_TEST_FILENAME="/anywhere/$1"
. "$REPO_ROOT/tests/helpers.bash"
case ":$PATH:" in
*":$MOCK_BIN:"*) [ "${MACKAS_BREW_BIN:-}" = "$MOCK_BIN" ] && echo stubbed || echo half ;;
*) [ -z "${MACKAS_BREW_BIN:-}" ] && echo exempt || echo half ;;
esac
EOF
	run bash "$probe" cli.bats
	[ "$output" = stubbed ]
	run bash "$probe" real_runtime.bats
	[ "$output" = exempt ]
	# A name helpers has never heard of falls to the safe side.
	run bash "$probe" ""
	[ "$output" = stubbed ]
}

@test "hermetic: mackas' CLI-ABSENT branch, which the stub no longer presents" {
	# Until the stub landed, this branch was covered only by accident, and only
	# on CI -- the one machine with no `container` anywhere on PATH. The stub
	# puts a CLI on PATH everywhere, so CI now takes the CLI-PRESENT branch
	# too. Cover the absent one deliberately instead of losing it.
	#
	# This is the one assertion here that must NOT see MOCK_BIN's `container`,
	# so it gets a PATH with only the OTHER three stubs on it: dropping all of
	# them would hand `check` the host's real curl/mdfind/diskutil from
	# /usr/bin, which is the hermeticity hole this file exists to close.
	local nobin="$TESTDIR/no-container-bin" tool
	mkdir -p "$nobin"
	for tool in curl mdfind diskutil; do
		ln -s "$MOCK_BIN/$tool" "$nobin/$tool"
	done
	PATH="$nobin:/usr/bin:/bin:/usr/sbin:/sbin" \
		run "$MACKAS" --set "MACKAS_ROOT=$TESTDIR/oe" check
	# Non-vacuous: that PATH really has no container on it at all.
	[ -z "$(PATH="$nobin:/usr/bin:/bin:/usr/sbin:/sbin" command -v container || true)" ]
	printf '%s\n' "$output" | grep -qF "'container' CLI not installed"
	# The absent branch returns early, so rung 2 stops there and its kernel
	# probe below never runs. Anchored on that probe, not on the daemon
	# verdict: rung 8 reports the daemon separately, in almost the same words.
	! printf '%s\n' "$output" | grep -q 'kernel not probed'
}

@test "hermetic: run-tests.sh fails a run in which a test got past the stub" {
	# hermetic.bats can only see out from inside itself; the slip that hung a
	# whole run for an hour was some OTHER file reaching the real binary.
	# run-tests.sh catches that with recorders behind the stubs -- drive a
	# deliberate breach through it and check the run really goes red.
	#
	# MACKAS_REAL_RUNTIME is cleared for the child, not skipped around: the
	# recorder is deliberately off in that mode (see the next test), and a dev
	# exporting the variable must not turn this guard into a false failure.
	run env -u MACKAS_REAL_RUNTIME \
		"$REPO_ROOT/run-tests.sh" "$REPO_ROOT/tests/fixtures/hermeticity-breach.bats"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q 'hermeticity: FAILED'
	# Non-vacuous: the breach really ran and was recorded, rather than skipping.
	printf '%s\n' "$output" | grep -q 'container hermeticity-breach-probe'
}

@test "hermetic: MACKAS_REAL_RUNTIME=1 deliberately runs without the whole-run recorder" {
	# The other half of the mode, asserted rather than assumed: with the opt-in
	# set, run-tests.sh plants no recorder (the *_real suites want the genuine
	# tools), so the breach fixture finds nothing safe to call and skips
	# instead of reddening the run.
	run env MACKAS_REAL_RUNTIME=1 \
		"$REPO_ROOT/run-tests.sh" "$REPO_ROOT/tests/fixtures/hermeticity-breach.bats"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'recorder is not the next container on PATH'
	! printf '%s\n' "$output" | grep -q 'hermeticity: FAILED'
}
