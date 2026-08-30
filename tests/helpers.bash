#!/usr/bin/env bash
#
# Shared helpers for the mackas bats suite.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

# Repo root, regardless of where bats was invoked from.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

SHIM="$REPO_ROOT/bin/docker"
MACKAS="$REPO_ROOT/mackas"
MOCK_CONTAINER="$REPO_ROOT/tests/mock/container"
MOCK_BIN="$REPO_ROOT/tests/mock/bin"
export SHIM MACKAS MOCK_CONTAINER MOCK_BIN

# The four non-hermetic opt-in files, which want the genuine binary. Named
# outright rather than globbed: real_runtime.bats does not match *_real.bats,
# and a glob would also hand the real runtime to any future file that happened
# to be named that way. hermetic.bats cross-checks this against the files that
# actually self-skip without MACKAS_REAL_RUNTIME=1.
MACKAS_TEST_REAL_FILES="real_runtime.bats volume_resize_real.bats diskmon_real.bats workspace_image_real.bats"
export MACKAS_TEST_REAL_FILES

# Shadow the real `container` everywhere else. mackas resolves the runtime CLI
# through PATH and only some tests plant their own fake; the rest used to fall
# through to a dev Mac's /opt/homebrew/bin/container -- invisible while the
# daemon answers, a suite-wide hang once it wedges. An unknown filename gets
# the stub too, which is the safe direction. A test wanting its own answers
# still prepends its own fakebin, which wins over this.
_mackas_test_file="${BATS_TEST_FILENAME:-}"
case " $MACKAS_TEST_REAL_FILES " in
*" ${_mackas_test_file##*/} "*) ;;
*) PATH="$MOCK_BIN:$PATH" ;;
esac
unset _mackas_test_file

# The bats tmpdir (/tmp or $BATS_TEST_TMPDIR) is case-INSENSITIVE APFS on a
# stock Mac, same as most dev machines' /tmp. `setup` refuses a case-insensitive
# MACKAS_ROOT by default (setup_oe_root's MACKAS_REQUIRE_CASE_SENSITIVE gate) --
# correct in the real world, but it would fail every hermetic `setup` test here
# regardless of what each is actually testing. Default it off for the whole
# suite; case_sensitivity.bats explicitly re-enables it to test the gate itself.
export MACKAS_REQUIRE_CASE_SENSITIVE=0

# Run the shim with `container` mocked out. Every test that exercises
# translation goes through here, so no test can accidentally touch the real
# Apple container runtime.
run_shim() {
	MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "$@"
}

# Assert that the mock was invoked with $1 as one whole argument.
assert_arg() {
	local want="$1"
	if ! printf '%s\n' "$output" | grep -qxF "ARG:$want"; then
		printf 'expected argument %q to be present\n--- actual output ---\n%s\n' \
			"$want" "$output" >&2
		return 1
	fi
}

# Assert that no argument equal to $1 was passed to the mock.
refute_arg() {
	local unwanted="$1"
	if printf '%s\n' "$output" | grep -qxF "ARG:$unwanted"; then
		printf 'expected argument %q to be ABSENT, but it was passed\n--- actual output ---\n%s\n' \
			"$unwanted" "$output" >&2
		return 1
	fi
}

# The mock's argv as a newline-separated list with the ARG: prefix stripped,
# so tests can assert on exact ordering.
mock_argv() {
	printf '%s\n' "$output" | sed -n 's/^ARG://p'
}

# A throwaway directory, cleaned up by the caller's teardown.
make_tmpdir() {
	mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/mackas-test.XXXXXX"
}

# Assert that COMMAND fails (exits non-zero). Use this for any "must be
# refused" assertion that is NOT the final line of a test.
#
# A bare `! cmd` is a trap as an intermediate line: bash `set -e` (which bats
# leaves on for simple commands, so an intermediate `[ x = y ]` DOES fail a
# test) explicitly never aborts on a `!`-negated command, so `! cmd` passes
# vacuously even when cmd wrongly SUCCEEDS -- it only bites as the very last
# line, where its status becomes the test's. assert_fails returns non-zero on
# the wrong-success case, so set -e fails the test at the right line no matter
# where it sits.
assert_fails() {
	if "$@"; then
		printf 'assert_fails: expected NON-ZERO exit, but succeeded: %s\n' "$*" >&2
		return 1
	fi
	return 0
}
