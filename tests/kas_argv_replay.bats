#!/usr/bin/env bats
#
# Record/replay conformance for the bin/docker shim against the REAL kas.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/shim.bats pins what the shim does to hand-written docker command lines.
# This file pins the OTHER half of the contract: the actual docker argv the real
# kas-container issues (captured once into tests/fixtures/kas-container-<VER>.argv
# by tests/fixtures/record-kas-argv.sh -- see that fixture's header). Each
# recorded invocation is replayed THROUGH bin/docker with the mock `container`,
# and we assert the shim preserves the contract on kas's own real command lines:
#
#   * no DROPPED flag (--log-driver=none et al.) ever reaches `container`
#   * no HARD-FAIL (--device / --network host) fires on a real kas invocation
#     (the shim exits 0 for every one)
#   * the IMAGE boundary is right: the image and everything after it -- the kas
#     subcommand and its files -- are forwarded verbatim, in order
#   * every -v mount and -e env value survives intact as ONE argument, spaces
#     and all (e.g. `PARALLEL_MAKE=-j 18`, `bitbake -p`)
#
# Hermetic: the mock container just echoes argv; no VM, no volume, no build.

load helpers

# The version mackas pins. The fixture is named for it; a bump without a
# re-record is caught by the guard test below.
kas_version() {
	sed -n 's/^KAS_CONTAINER_VERSION="\([^"]*\)".*/\1/p' "$MACKAS" | head -1
}

fixture_path() {
	printf '%s/tests/fixtures/kas-container-%s.argv' "$REPO_ROOT" "$(kas_version)"
}

# Load one invocation's argv (one element per line) into the global BLOCK_ARGV.
# Header `#` lines sit outside any block and are ignored.
load_block() {
	local want="$1" line inblock=0
	BLOCK_ARGV=()
	while IFS= read -r line; do
		case "$line" in
			"=== INVOCATION: $want") inblock=1; continue ;;
			"=== INVOCATION: "*)      inblock=0; continue ;;
			"=== END")                if [ "$inblock" -eq 1 ]; then break; fi; continue ;;
		esac
		if [ "$inblock" -eq 1 ]; then
			BLOCK_ARGV+=("$line")
		fi
	done < "$(fixture_path)"
}

# The labels recorded in the fixture, in order.
FIXTURE_LABELS=(checkout shell-bitbake-p build-target shell)

# ---------------------------------------------------------------------------
# Guard: the pinned version must have a fixture, and it must be non-trivial.
# ---------------------------------------------------------------------------

@test "replay: mackas's pinned KAS_CONTAINER_VERSION has a matching argv fixture" {
	local ver fix
	ver="$(kas_version)"
	[ -n "$ver" ]
	fix="$(fixture_path)"
	if [ ! -f "$fix" ]; then
		printf 'no fixture for pinned kas-container %s.\n' "$ver" >&2
		printf 'Re-record it: tests/fixtures/record-kas-argv.sh\n' >&2
		printf '(expected: %s)\n' "$fix" >&2
		return 1
	fi
}

@test "replay: the fixture holds all four invocations, each non-empty" {
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		if [ "${#BLOCK_ARGV[@]}" -lt 4 ]; then
			printf 'invocation %s has only %d args\n' "$label" "${#BLOCK_ARGV[@]}" >&2
			return 1
		fi
		# Every recorded docker invocation is a `run`.
		[ "${BLOCK_ARGV[0]}" = "run" ]
	done
}

# ---------------------------------------------------------------------------
# The replay loop, one property per test, over every recorded invocation.
# ---------------------------------------------------------------------------

@test "replay: every real kas invocation passes the shim without a hard-fail (exit 0)" {
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		if [ "$status" -ne 0 ]; then
			printf 'invocation %s hard-failed (status %s):\n%s\n' \
				"$label" "$status" "$output" >&2
			return 1
		fi
	done
}

@test "replay: the dropped flag --log-driver=none never reaches container" {
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		# Sanity: the flag really is in the recorded input, or this is vacuous.
		local present=0 a
		for a in "${BLOCK_ARGV[@]}"; do
			[ "$a" = "--log-driver=none" ] && present=1
		done
		if [ "$present" -ne 1 ]; then
			printf 'fixture %s no longer contains --log-driver=none; re-check\n' "$label" >&2
			return 1
		fi
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		[ "$status" -eq 0 ]
		refute_arg "--log-driver=none"
		refute_arg "--log-driver"
	done
}

@test "replay: --user=root (a dropped-flag lookalike) is NOT dropped" {
	# --user is pass-through; only --log-driver/--security-opt/--userns/--group-add
	# are dropped. A too-greedy prefix match would eat --user. Guard it.
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		[ "$status" -eq 0 ]
		assert_arg "--user=root"
	done
}

@test "replay: the IMAGE and everything after it is forwarded verbatim, in order" {
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"

		# The image is the kas container image line; the tail is it plus the kas
		# subcommand and files -- forwarded byte-for-byte past the IMAGE boundary.
		local img_idx=-1 i
		for i in "${!BLOCK_ARGV[@]}"; do
			case "${BLOCK_ARGV[$i]}" in
				ghcr.io/*kas:*) img_idx=$i; break ;;
			esac
		done
		if [ "$img_idx" -lt 0 ]; then
			printf 'no image found in fixture %s\n' "$label" >&2
			return 1
		fi

		# Expected tail = image .. end of the recorded argv, newline-joined with
		# no trailing newline (so it compares cleanly to command-substituted
		# output, which strips trailing newlines).
		local expected_tail="" n_tail=0
		for (( i=img_idx; i<${#BLOCK_ARGV[@]}; i++ )); do
			if [ -n "$expected_tail" ]; then expected_tail+=$'\n'; fi
			expected_tail+="${BLOCK_ARGV[$i]}"
			n_tail=$((n_tail + 1))
		done

		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		[ "$status" -eq 0 ]

		# The mock echoes container's argv; its last n_tail lines must equal
		# expected_tail exactly (same values, order, nothing translated after
		# the image).
		local actual_tail
		actual_tail="$(mock_argv | tail -n "$n_tail")"
		if [ "$actual_tail" != "$expected_tail" ]; then
			printf 'IMAGE-boundary mismatch for %s\n--- expected tail ---\n%s\n--- actual tail ---\n%s\n' \
				"$label" "$expected_tail" "$actual_tail" >&2
			return 1
		fi
	done
}

@test "replay: every -v mount and -e env value survives intact as one argument" {
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"

		# The image index bounds the pre-image region (past it is forwarded
		# verbatim and covered by the boundary test).
		local img_idx=${#BLOCK_ARGV[@]} i
		for i in "${!BLOCK_ARGV[@]}"; do
			case "${BLOCK_ARGV[$i]}" in
				ghcr.io/*kas:*) img_idx=$i; break ;;
			esac
		done

		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		[ "$status" -eq 0 ]

		# For each -v / -e before the image, the FOLLOWING token is its value and
		# must reach container as one whole argument (spaces and colons intact).
		local seen_val=0
		for (( i=0; i<img_idx-1; i++ )); do
			case "${BLOCK_ARGV[$i]}" in
				-v|-e)
					seen_val=$((seen_val + 1))
					assert_arg "${BLOCK_ARGV[$((i+1))]}"
					;;
			esac
		done
		# checkout/build/shell all mount at least /repo, /work, /build, ... plus
		# several -e; a handful proves the loop isn't vacuous.
		if [ "$seen_val" -lt 5 ]; then
			printf 'only %d -v/-e values checked for %s\n' "$seen_val" "$label" >&2
			return 1
		fi
	done
}

@test "replay: values containing spaces survive as single arguments" {
	# The showcase mangling risk: an argv element with a space re-split into two.
	# The fixture has real ones (PARALLEL_MAKE=-j 18; the shell rung's bitbake -p).
	local label
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" "${BLOCK_ARGV[@]}"
		[ "$status" -eq 0 ]
		local a checked=0
		for a in "${BLOCK_ARGV[@]}"; do
			case "$a" in
				*" "*)
					checked=$((checked + 1))
					assert_arg "$a"
					;;
			esac
		done
		# Every recorded invocation carries PARALLEL_MAKE=-j 18 at least.
		if [ "$checked" -lt 1 ]; then
			printf 'no space-containing arg in %s to check\n' "$label" >&2
			return 1
		fi
	done
}

@test "replay: no --device or --network host was recorded (else the shim WOULD refuse)" {
	# The shim hard-fails on these. The plain-OE invocations mackas drives must
	# not contain them -- if a future kas ever emits one, this catches it before
	# the exit-0 test does, with a clearer message.
	local label a
	for label in "${FIXTURE_LABELS[@]}"; do
		load_block "$label"
		local prev=""
		for a in "${BLOCK_ARGV[@]}"; do
			case "$a" in
				--device|--device=*)
					printf '%s: unexpected --device in a real kas invocation\n' "$label" >&2
					return 1 ;;
				host)
					if [ "$prev" = "--network" ]; then
						printf '%s: unexpected --network host\n' "$label" >&2
						return 1
					fi ;;
				--network=host)
					printf '%s: unexpected --network=host\n' "$label" >&2
					return 1 ;;
			esac
			prev="$a"
		done
	done
}
