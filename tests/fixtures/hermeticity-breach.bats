#!/usr/bin/env bats
#
# A bats file that breaches hermeticity on purpose.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Not part of the suite: `bats tests/` does not recurse, so nothing here runs
# in a normal run. hermetic.bats hands this file to run-tests.sh by name, to
# prove the whole-run hermeticity guard actually fires -- otherwise the guard
# is plumbing nobody has ever seen work. It does what a slipped test does:
# drops helpers.bash's stub off PATH and calls `container`.

bats_require_minimum_version 1.5.0

load ../helpers

@test "breach: call container past the stub, so run-tests.sh's recorder logs it" {
	PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$MOCK_BIN" | paste -sd: -)"

	# Only ever call the recorder. Without run-tests.sh's guard the next
	# `container` on PATH is a dev Mac's REAL one -- the very call this file
	# exists to prove is caught -- so skip instead and let hermetic.bats fail
	# on the missing breach.
	if [ -n "${MACKAS_TEST_HERMETIC_RECORDER:-}" ] &&
		[ "$(command -v container || true)" = "$MACKAS_TEST_HERMETIC_RECORDER" ]; then
		container hermeticity-breach-probe || true
	else
		skip "run-tests.sh's recorder is not the next container on PATH"
	fi
}
