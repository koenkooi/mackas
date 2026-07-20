#!/usr/bin/env bats
#
# OPT-IN real end-to-end test of the workspace-image mechanism (TODO item 18):
# a case-sensitive APFS sparse image, created and mounted for real via hdiutil.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKIPPED BY DEFAULT, same reasoning as real_runtime.bats: everything else is
# hermetic (case_sensitivity.bats covers the offer/decline/reattach/migrate
# LOGIC via --dry-run), but proving hdiutil create+attach genuinely produces a
# case-sensitive mount needs the real thing. Unlike real_runtime.bats this
# needs NO Apple `container` runtime at all -- it is pure hdiutil/APFS, so it
# gets its own lightweight setup() rather than inheriting that file's
# container-runtime checks.
#
#   MACKAS_REAL_RUNTIME=1 bats tests/workspace_image_real.bats
#
# Uses MACKAS_LIB_ONLY=1 to call offer_workspace_image() directly (see
# purefns.bats for the same pattern) rather than a full `mackas setup`, so
# this stays narrowly about the image mechanism, not the other 10 setup steps.

load helpers

setup() {
	if [ "${MACKAS_REAL_RUNTIME:-}" != "1" ]; then
		skip "opt-in: set MACKAS_REAL_RUNTIME=1 (dev-Mac only, non-hermetic, never CI)"
	fi
	command -v hdiutil >/dev/null 2>&1 || skip "no hdiutil (not macOS?)"

	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	setup_colors   # normally called from main(), which MACKAS_LIB_ONLY skips

	TESTDIR="$(make_tmpdir)"
	MACKAS_ROOT="$TESTDIR/root"
	MACKAS_WORKSPACE_SIZE="256m"   # small: this test only proves the mechanism
	DRY_RUN=0
	ASSUME_YES=1
	mkdir -p "$MACKAS_ROOT/work"
}

teardown() {
	[ "${MACKAS_REAL_RUNTIME:-}" = "1" ] || return 0
	# Detach whatever ended up mounted at work/, then remove everything --
	# tolerating a test that failed before creating anything.
	hdiutil detach "$MACKAS_ROOT/work" >/dev/null 2>&1 || true
	rm -rf "$TESTDIR" 2>/dev/null || true
}

@test "real workspace image: create+mount genuinely makes work/ case-sensitive" {
	local precs; set +e; dir_is_case_sensitive "$MACKAS_ROOT/work"; precs=$?; set -e
	[ "$precs" -eq 1 ] || skip "this host's tmp is already case-sensitive; nothing to prove here"

	offer_workspace_image

	local img; img="$(workspace_image_base).sparseimage"
	[ -f "$img" ]
	# Not a `mount | grep` here: macOS resolves /var -> /private/var in the
	# mount table but $MACKAS_ROOT (under bats' tmpdir) does not carry that
	# prefix, so a literal-path grep is fragile. dir_is_case_sensitive
	# actually writing through the mount is the real, robust proof anyway.
	local postcs; set +e; dir_is_case_sensitive "$MACKAS_ROOT/work"; postcs=$?; set -e
	[ "$postcs" -eq 0 ]

	# The real proof: a case-colliding pair actually round-trips, the exact
	# oe-core failure mode item 18 exists to prevent.
	: > "$MACKAS_ROOT/work/File.txt"
	: > "$MACKAS_ROOT/work/file.txt"
	[ "$(ls "$MACKAS_ROOT/work" | grep -c '^[Ff]ile\.txt$')" -eq 2 ]
}

@test "real workspace image: a pre-existing checkout survives the migration" {
	local precs; set +e; dir_is_case_sensitive "$MACKAS_ROOT/work"; precs=$?; set -e
	[ "$precs" -eq 1 ] || skip "this host's tmp is already case-sensitive; nothing to prove here"

	mkdir -p "$MACKAS_ROOT/work/some-layer"
	echo "real content" > "$MACKAS_ROOT/work/some-layer/marker"

	offer_workspace_image

	local postcs; set +e; dir_is_case_sensitive "$MACKAS_ROOT/work"; postcs=$?; set -e
	[ "$postcs" -eq 0 ]
	[ -f "$MACKAS_ROOT/work/some-layer/marker" ]
	[ "$(cat "$MACKAS_ROOT/work/some-layer/marker")" = "real content" ]

	# The pre-move stash must exist (moved-aside backup, not deleted).
	ls -d "$MACKAS_ROOT"/work.pre-workspace-* >/dev/null 2>&1
}
