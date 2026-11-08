#!/usr/bin/env bats
#
# Tests for bin/realpath, the Python stand-in for the GNU realpath forms
# kas-container and env.sh use (macOS's /bin/realpath is BSD and rejects them),
# and for realpath_forms_ok(), the probe that decides whether a given realpath
# is good enough.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	RP_SHIM="$BATS_TEST_DIRNAME/../bin/realpath"
	mkdir -p "$TESTDIR/base/child" "$TESTDIR/other"
	# /tmp and /var are symlinks on macOS; the shim must resolve them too
	TESTDIR="$(cd "$TESTDIR" && pwd -P)"
}

@test "shim: -e succeeds on an existing path and prints it canonicalized" {
	run "$RP_SHIM" -e "$TESTDIR/base/../base/child"
	[ "$status" -eq 0 ]
	[ "$output" = "$TESTDIR/base/child" ]
}

@test "shim: -e fails on a missing path with a message" {
	run --separate-stderr "$RP_SHIM" -e "$TESTDIR/missing"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"No such file or directory"* ]]
}

@test "shim: -qe fails on a missing path, silently" {
	run --separate-stderr "$RP_SHIM" -qe "$TESTDIR/missing"
	[ "$status" -ne 0 ]
	[ -z "$stderr" ]
}

@test "shim: without -e a missing path is canonicalized, not an error" {
	run "$RP_SHIM" -q "$TESTDIR/base/new"
	[ "$status" -eq 0 ]
	[ "$output" = "$TESTDIR/base/new" ]
}

@test "shim: --relative-base relativizes a child and leaves an outsider absolute" {
	run "$RP_SHIM" -q --relative-base="$TESTDIR/base" "$TESTDIR/base/child"
	[ "$output" = "child" ]
	run "$RP_SHIM" -q --relative-base="$TESTDIR/base" "$TESTDIR/other"
	[ "$output" = "$TESTDIR/other" ]
}

@test "shim: --relative-base accepts the separate-argument form" {
	run "$RP_SHIM" --relative-base "$TESTDIR/base" "$TESTDIR/base/child"
	[ "$output" = "child" ]
}

@test "shim: --relative-to always relativizes, using .. when needed" {
	run "$RP_SHIM" --relative-to="$TESTDIR/base" "$TESTDIR/other"
	[ "$status" -eq 0 ]
	[ "$output" = "../other" ]
	run "$RP_SHIM" --relative-to "$TESTDIR/base" "$TESTDIR/base/child"
	[ "$output" = "child" ]
}

@test "shim: -- ends option parsing" {
	run "$RP_SHIM" -q -- "-dash"
	[ "$status" -eq 0 ]
	[ "$output" = "$PWD/-dash" ]
}

@test "shim: an unknown option is refused" {
	run "$RP_SHIM" --bogus /
	[ "$status" -ne 0 ]
}

@test "shim: uses the stock interpreter, not whatever python3 is first on PATH" {
	[ "$(head -1 "$RP_SHIM")" = "#!/usr/bin/python3" ]
}

@test "realpath_forms_ok: accepts the shim" {
	eval "$(awk '/^realpath_forms_ok\(\) \{/,/^}/' "$BATS_TEST_DIRNAME/../mackas")"
	realpath_forms_ok "$RP_SHIM"
}

@test "realpath_forms_ok: rejects a realpath that lacks the forms (macOS BSD)" {
	eval "$(awk '/^realpath_forms_ok\(\) \{/,/^}/' "$BATS_TEST_DIRNAME/../mackas")"
	[ "$(uname -s)" = Darwin ] || skip "needs BSD realpath"
	run realpath_forms_ok /bin/realpath
	[ "$status" -ne 0 ]
}

@test "realpath_forms_ok: rejects a realpath that lacks --relative-to" {
	eval "$(awk '/^realpath_forms_ok\(\) \{/,/^}/' "$BATS_TEST_DIRNAME/../mackas")"
	printf '#!/bin/sh\ncase "$*" in *--relative-to*) exit 1 ;; esac\nexec %s "$@"\n' "$RP_SHIM" >"$TESTDIR/partial"
	chmod +x "$TESTDIR/partial"
	run realpath_forms_ok "$TESTDIR/partial"
	[ "$status" -ne 0 ]
}
