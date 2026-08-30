#!/usr/bin/env bats
#
# Guards the claim in AGENTS.md that the suite is hermetic: no hermetic test
# may reach the real Apple `container` binary.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# It was not true. mackas resolves the runtime CLI through PATH, and only the
# tests that wanted specific answers planted a fake; `mackas status`/`check`/
# `setup` from cli.bats, setup_kas_container.bats, volumes.bats and
# workspace_attach.bats fell through to a dev Mac's real
# /opt/homebrew/bin/container. Invisible while the daemon answers -- and with
# a wedged apiserver, where every client call blocks forever, the whole run
# hung in the cli.bats group with no child process to blame.
#
# helpers.bash now puts tests/mock/bin at the front of PATH for every file it
# does not name in MACKAS_TEST_REAL_FILES. These tests pin that: the stub wins
# over anything later on PATH, every file actually loads helpers, and the
# exemption list stays exactly the suites that self-skip without the opt-in.
# What a bats file cannot see from inside itself -- some OTHER file reaching
# past the stub -- run-tests.sh catches with a recorder behind it.

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

@test "hermetic: 'container' on PATH is the suite's stub" {
	local resolved; resolved="$(command -v container)"
	[ "$resolved" = "$MOCK_BIN/container" ]
}

@test "hermetic: mackas' runtime probes hit the stub, not a container further down PATH" {
	# A real runtime lives late in PATH (/opt/homebrew/bin) on a dev Mac and
	# nowhere at all on CI. Stand in for it with a recorder, and prove the
	# stub shadows it: mackas must reach the stub and never the one behind.
	local stublog="$TESTDIR/stub.log" poisonlog="$TESTDIR/poison.log"
	mkdir -p "$TESTDIR/lastbin"
	cat > "$TESTDIR/lastbin/container" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$poisonlog"
exit 0
EOF
	chmod +x "$TESTDIR/lastbin/container"

	MACKAS_TEST_CONTAINER_LOG="$stublog" PATH="$PATH:$TESTDIR/lastbin" \
		run "$MACKAS" --set "MACKAS_ROOT=$TESTDIR/oe" status
	[ "$status" -eq 0 ]
	# Non-vacuous: status really does probe the runtime, so the stub was used.
	[ -f "$stublog" ]
	grep -qxF 'system status' "$stublog"
	[ ! -e "$poisonlog" ]
}

@test "hermetic: every bats file loads helpers, so none can miss the stub" {
	local f missing=""
	for f in "$REPO_ROOT"/tests/*.bats; do
		grep -q '^load helpers$' "$f" || missing="$missing ${f##*/}"
	done
	[ -z "$missing" ]
}

@test "hermetic: the files exempt from the stub are exactly the opt-in ones" {
	# helpers.bash hands the real runtime to the files it names. A file that
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

@test "hermetic: helpers exempts only the named files; an unknown name still gets the stub" {
	# The exemption is decided once, off BATS_TEST_FILENAME, as helpers loads
	# -- a branch no single bats file can take both ways. Source helpers in a
	# plain shell with the filename faked and read back the PATH it built.
	local probe="$TESTDIR/exemption.sh"
	cat > "$probe" <<'EOF'
# This file's own load already put MOCK_BIN on PATH; drop it, or every
# branch below reads as stubbed and the test proves nothing.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$MOCK_BIN" | paste -sd: -)"
BATS_TEST_FILENAME="/anywhere/$1"
. "$REPO_ROOT/tests/helpers.bash"
case ":$PATH:" in
*":$MOCK_BIN:"*) echo stubbed ;;
*) echo exempt ;;
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

@test "hermetic: run-tests.sh fails a run in which a test got past the stub" {
	# hermetic.bats can only see out from inside itself; the slip that hung a
	# whole run for an hour was some OTHER file reaching the real binary.
	# run-tests.sh catches that with a recorder behind the stub -- drive a
	# deliberate breach through it and check the run really goes red.
	run "$REPO_ROOT/run-tests.sh" "$REPO_ROOT/tests/fixtures/hermeticity-breach.bats"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q 'hermeticity: FAILED'
	# Non-vacuous: the breach really ran and was recorded, rather than skipping.
	printf '%s\n' "$output" | grep -q 'container hermeticity-breach-probe'
}
