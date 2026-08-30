#!/usr/bin/env bats
#
# Pure-function coverage gaps, exercised in lib-mode (MACKAS_LIB_ONLY=1):
# ip_in_cidr / ip_to_int, fmt_kb's locale guard, volume_size's sed parse,
# buildhistory_repo_state's classification, and config_file_is_safe's symlink
# handling (the cases no command line can reach, plus the measured platform
# fact that whole check rests on).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These functions had no direct tests. ip_to_int silently accepted octets > 255
# and ip_in_cidr computed a negative shift for a /40; both are fixed here and
# pinned to the CORRECT behaviour, not the bug.

load helpers

setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	TESTDIR="$(make_tmpdir)"
}

teardown() {
	rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# ip_in_cidr / ip_to_int
# ---------------------------------------------------------------------------

@test "ip_in_cidr: an address inside a /24 matches, one outside does not" {
	ip_in_cidr 10.0.0.5   10.0.0.0/24
	ip_in_cidr 10.0.0.255 10.0.0.0/24
	assert_fails ip_in_cidr 10.0.1.5 10.0.0.0/24
	assert_fails ip_in_cidr 10.1.0.5 10.0.0.0/24
}

@test "ip_in_cidr: a bare IP is treated as /32 (exact match only)" {
	ip_in_cidr 192.168.1.7 192.168.1.7
	assert_fails ip_in_cidr 192.168.1.8 192.168.1.7
	# The explicit /32 spelling agrees with the bare one.
	ip_in_cidr 192.168.1.7 192.168.1.7/32
	assert_fails ip_in_cidr 192.168.1.8 192.168.1.7/32
}

@test "ip_in_cidr: /0 matches every address" {
	ip_in_cidr 0.0.0.0     0.0.0.0/0
	ip_in_cidr 255.255.255.255 0.0.0.0/0
	ip_in_cidr 8.8.8.8     10.20.30.40/0
}

@test "ip_to_int: rejects an octet greater than 255" {
	# Regression: "300.1.1.1" used to parse to a bogus integer instead of being
	# refused, because only non-digits were checked, not the 0..255 range.
	assert_fails ip_to_int 300.1.1.1
	assert_fails ip_to_int 1.1.1.256
	assert_fails ip_to_int 999.999.999.999
	# ...and a legitimate boundary value is still accepted.
	[ "$(ip_to_int 255.255.255.255)" = "4294967295" ]
	[ "$(ip_to_int 0.0.0.0)" = "0" ]
}

@test "ip_to_int: rejects a dotted quad that is not exactly four octets" {
	assert_fails ip_to_int 1.2.3
	assert_fails ip_to_int 1.2.3.4.5
	assert_fails ip_to_int ""
	assert_fails ip_to_int abc
}

@test "ip_in_cidr: a prefix length above 32 is refused, not computed as a negative shift" {
	# Regression: /40 made the mask shift by (32-40) = -8, which is undefined.
	# It must be refused outright, for any address.
	assert_fails ip_in_cidr 10.0.0.1 10.0.0.0/40
	assert_fails ip_in_cidr 10.0.0.1 10.0.0.0/33
	assert_fails ip_in_cidr 10.0.0.1 10.0.0.0/999
}

@test "ip_in_cidr: an out-of-range octet anywhere refuses the whole match" {
	assert_fails ip_in_cidr 300.1.1.1 10.0.0.0/24
	assert_fails ip_in_cidr 10.0.0.1  300.0.0.0/24
}

# ---------------------------------------------------------------------------
# fmt_kb -- the LC_ALL=C guard: a comma-decimal locale must NOT bleed into the
# formatted size (du -h would print "1,5M"; we compute on these, so they must
# stay dot-decimal and parseable).
# ---------------------------------------------------------------------------

@test "fmt_kb: formats mebi/gibibytes with a dot decimal in the C locale" {
	[ "$(fmt_kb 1536)" = "1.5M" ]
	[ "$(fmt_kb 1572864)" = "1.5G" ]
	[ "$(fmt_kb 512)" = "512K" ]
	# Never negative: a negative input is clamped to 0.
	[ "$(fmt_kb -5)" = "0K" ]
}

@test "fmt_kb: a comma-decimal locale still yields a dot, not a comma" {
	# NOTE: bats' own `skip` is shadowed here -- sourcing mackas defines a
	# skip() of its own -- so a host that genuinely cannot run this (no
	# comma-decimal locale) bails with `return 0` and a stderr note rather than
	# a real bats skip. On a host that HAS one (the maintainer's does), the real
	# assertion below runs and is not vacuous.
	# Capture `locale -a` once: piping it straight into `grep -q` trips
	# SIGPIPE under bats' pipefail (grep exits at the first match, `locale`
	# dies writing to the closed pipe, and the pipeline reports 141).
	local avail loc=""
	avail="$(locale -a 2>/dev/null)"
	for cand in de_DE.UTF-8 nl_NL.UTF-8 fr_FR.UTF-8 de_DE.ISO8859-1 nl_NL.ISO8859-1; do
		if printf '%s\n' "$avail" | grep -qxF "$cand"; then loc="$cand"; break; fi
	done
	if [ -z "$loc" ]; then
		echo "# no comma-decimal locale installed; not exercised" >&3
		return 0
	fi
	# Prove the locale really is comma-decimal for awk, so this test cannot
	# pass vacuously against a host whose "de_DE" still prints a dot.
	local raw
	raw="$(LC_ALL="$loc" LC_NUMERIC="$loc" awk 'BEGIN { printf "%.1f", 1.5 }')"
	if [ "$raw" != "1,5" ]; then
		echo "# locale $loc is not comma-decimal for awk here; not exercised" >&3
		return 0
	fi
	# The function guards awk with LC_ALL=C, so its output stays dot-decimal
	# even with a comma locale in the environment.
	local got
	got="$(LC_ALL="$loc" LC_NUMERIC="$loc" fmt_kb 1536)"
	[ "$got" = "1.5M" ]
}

# ---------------------------------------------------------------------------
# volume_size -- the sed parse of `container volume inspect`'s "size" field,
# which must survive both spellings of the JSON spacing.
# ---------------------------------------------------------------------------

@test "volume_size: parses \"size\": \"800M\" with no space around the colon" {
	container() { printf '{ "options": { "size": "800M" } }\n'; }
	[ "$(volume_size oe-build-tmp)" = "800M" ]
}

@test "volume_size: parses \"size\" : \"800M\" with spaces around the colon" {
	container() {
		printf '{\n  "configuration" : {\n    "options" : {\n      "size" : "800M"\n    }\n  }\n}\n'
	}
	[ "$(volume_size oe-build-tmp)" = "800M" ]
}

@test "volume_size: does not mistake sizeInBytes for the declared size" {
	# The pattern requires the closing quote immediately after `size`, so a
	# neighbouring "sizeInBytes" field must never be picked up instead.
	container() {
		printf '{ "sizeInBytes" : 838860800, "size" : "800M" }\n'
	}
	[ "$(volume_size oe-build-tmp)" = "800M" ]
}

# ---------------------------------------------------------------------------
# buildhistory_repo_state -- the buildhistory-analyze preflight's git-state
# classifier. Never called via `$(...)` (that would run it in a subshell and
# discard every global it sets, see the function's own comment) -- called
# plainly, then the globals are read directly, exactly as
# buildhistory_analyze() itself does.
# ---------------------------------------------------------------------------

bh_git_repo() {
	local dir="$1"
	mkdir -p "$dir"
	git init -q "$dir"
	git -C "$dir" config user.email test@example.com
	git -C "$dir" config user.name test
}

bh_commit() {
	local dir="$1" msg="$2" tag="${3:-}"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "$msg" --allow-empty
	[ -z "$tag" ] || git -C "$dir" tag "$tag"
}

@test "buildhistory_repo_state: a directory that does not exist is 'missing'" {
	buildhistory_repo_state "$TESTDIR/nope" build-minus-1 HEAD 0
	[ "$BH_STATE" = "missing" ]
}

@test "buildhistory_repo_state: an existing dir with no packages/images/sdk is 'notree'" {
	mkdir -p "$TESTDIR/empty-dir"
	buildhistory_repo_state "$TESTDIR/empty-dir" build-minus-1 HEAD 0
	[ "$BH_STATE" = "notree" ]
}

@test "buildhistory_repo_state: a buildhistory tree with no .git is 'nogit' (snapshot mode)" {
	mkdir -p "$TESTDIR/nogit/packages"
	buildhistory_repo_state "$TESTDIR/nogit" build-minus-1 HEAD 0
	[ "$BH_STATE" = "nogit" ]
}

@test "buildhistory_repo_state: a git repo with zero commits is 'empty'" {
	mkdir -p "$TESTDIR/emptygit/packages"
	bh_git_repo "$TESTDIR/emptygit"
	buildhistory_repo_state "$TESTDIR/emptygit" build-minus-1 HEAD 0
	[ "$BH_STATE" = "empty" ]
}

@test "buildhistory_repo_state: exactly one commit is 'single' -- nothing to diff yet" {
	mkdir -p "$TESTDIR/single/packages"
	echo x > "$TESTDIR/single/packages/f"
	bh_git_repo "$TESTDIR/single"
	bh_commit "$TESTDIR/single" "Build 1"
	buildhistory_repo_state "$TESTDIR/single" build-minus-1 HEAD 0
	[ "$BH_STATE" = "single" ]
}

@test "buildhistory_repo_state: two commits with a build-minus-1 tag resolve directly to 'ok'" {
	mkdir -p "$TESTDIR/ok/packages"
	bh_git_repo "$TESTDIR/ok"
	echo one > "$TESTDIR/ok/packages/f"
	bh_commit "$TESTDIR/ok" "Build 1" build-minus-1
	echo two > "$TESTDIR/ok/packages/f"
	bh_commit "$TESTDIR/ok" "Build 2"

	buildhistory_repo_state "$TESTDIR/ok" build-minus-1 HEAD 0
	[ "$BH_STATE" = "ok" ]
	[ "$BH_FROM_FELL_BACK" -eq 0 ]
	[ -n "$BH_FROM" ]
	[ -n "$BH_TO" ]
	[ "$BH_FROM" != "$BH_TO" ]
}

@test "buildhistory_repo_state: no build-minus-1 tag falls back to HEAD~1 for the DEFAULT from" {
	mkdir -p "$TESTDIR/notag/packages"
	bh_git_repo "$TESTDIR/notag"
	echo one > "$TESTDIR/notag/packages/f"
	bh_commit "$TESTDIR/notag" "Build 1"
	echo two > "$TESTDIR/notag/packages/f"
	bh_commit "$TESTDIR/notag" "Build 2"

	buildhistory_repo_state "$TESTDIR/notag" build-minus-1 HEAD 0
	[ "$BH_STATE" = "ok" ]
	[ "$BH_FROM_FELL_BACK" -eq 1 ]
	[ "$BH_FROM_REV" = "HEAD~1" ]
}

@test "buildhistory_repo_state: an EXPLICIT --from that fails to resolve is 'badrev', no fallback" {
	mkdir -p "$TESTDIR/notag2/packages"
	bh_git_repo "$TESTDIR/notag2"
	echo one > "$TESTDIR/notag2/packages/f"
	bh_commit "$TESTDIR/notag2" "Build 1"
	echo two > "$TESTDIR/notag2/packages/f"
	bh_commit "$TESTDIR/notag2" "Build 2"

	# from_explicit=1: even though this IS the string "build-minus-1", the
	# caller asked for it by name, so a failed resolution must not silently
	# fall back to HEAD~1 the way the default does above.
	buildhistory_repo_state "$TESTDIR/notag2" build-minus-1 HEAD 1
	[ "$BH_STATE" = "badrev" ]
}

@test "buildhistory_repo_state: a bogus user-supplied --to is 'badrev'" {
	mkdir -p "$TESTDIR/badto/packages"
	bh_git_repo "$TESTDIR/badto"
	echo one > "$TESTDIR/badto/packages/f"
	bh_commit "$TESTDIR/badto" "Build 1" build-minus-1
	echo two > "$TESTDIR/badto/packages/f"
	bh_commit "$TESTDIR/badto" "Build 2"

	buildhistory_repo_state "$TESTDIR/badto" build-minus-1 no-such-rev 0
	[ "$BH_STATE" = "badrev" ]
}

@test "buildhistory_repo_state: a .git dir but no git binary on PATH is 'nogitbin'" {
	mkdir -p "$TESTDIR/hasgit/packages" "$TESTDIR/hasgit/.git" "$TESTDIR/emptybin"
	local savepath="$PATH"
	PATH="$TESTDIR/emptybin"
	buildhistory_repo_state "$TESTDIR/hasgit" build-minus-1 HEAD 0
	PATH="$savepath"
	[ "$BH_STATE" = "nogitbin" ]
}

@test "buildhistory_repo_state: no git binary but ALSO no .git dir still classifies as 'nogit'" {
	# Snapshot mode never needs the git binary at all -- only diff mode does.
	mkdir -p "$TESTDIR/nogit2/packages" "$TESTDIR/emptybin"
	local savepath="$PATH"
	PATH="$TESTDIR/emptybin"
	buildhistory_repo_state "$TESTDIR/nogit2" build-minus-1 HEAD 0
	PATH="$savepath"
	[ "$BH_STATE" = "nogit" ]
}

# ---------------------------------------------------------------------------
# config_file_is_safe / path_is_owned_and_unwritable_by_others
#
# The security primitive behind the config search path and the --project
# selector, called here directly: its symlink handling has cases the command
# line cannot reach, because `[ -r ]`/`[ -f ]` at every call site resolve the
# path (and refuse a loop) before it is ever asked.
# ---------------------------------------------------------------------------

@test "ln -s applies the umask, so a symlink's own mode records only that" {
	# The platform fact the whole check rests on, measured rather than
	# assumed: a link is NOT 777, so it never fails the grade by itself, and
	# at the usual umask it is 755 -- squarely inside what
	# path_is_owned_and_unwritable_by_others accepts.
	local m umask_val want
	for m in 022:755 002:775 000:777 077:700 027:750; do
		umask_val="${m%%:*}"; want="${m##*:}"
		( umask "$umask_val" && ln -s /nonexistent "$TESTDIR/l$umask_val" )
		[ "$(stat -f '%Lp' "$TESTDIR/l$umask_val")" = "$want" ]
	done
}

@test "path_is_owned_and_unwritable_by_others refuses a symlink instead of grading it" {
	# stat(1) is lstat, so grading the link grades the umask above. The
	# target here is a perfectly safe 0600 file; the point is that the answer
	# for the LINK must not be inherited from it either -- callers resolve
	# first, and a link arriving here is a caller bug, not a pass.
	echo 'MACKAS_MEMORY="8g"' > "$TESTDIR/target.conf"
	chmod 600 "$TESTDIR/target.conf"
	( umask 022 && ln -s "$TESTDIR/target.conf" "$TESTDIR/link.conf" )
	path_is_owned_and_unwritable_by_others "$TESTDIR/target.conf"
	assert_fails path_is_owned_and_unwritable_by_others "$TESTDIR/link.conf"
}

@test "config_file_is_safe walks a symlink chain to the file that would be sourced" {
	# Three hops, every link ours and 0755, ending on a world-writable file.
	echo 'MACKAS_MEMORY="8g"' > "$TESTDIR/end.conf"
	chmod 666 "$TESTDIR/end.conf"
	( umask 022 && ln -s "$TESTDIR/end.conf" "$TESTDIR/c.conf" )
	( umask 022 && ln -s "$TESTDIR/c.conf"   "$TESTDIR/b.conf" )
	( umask 022 && ln -s "$TESTDIR/b.conf"   "$TESTDIR/a.conf" )
	assert_fails config_file_is_safe "$TESTDIR/a.conf"
	# ...and the same chain onto a 0600 file is accepted, so the refusal
	# above is the endpoint's mode and not the depth.
	chmod 600 "$TESTDIR/end.conf"
	config_file_is_safe "$TESTDIR/a.conf"
}

@test "config_file_is_safe terminates on a symlink loop" {
	# Unreachable from the command line -- every call site's `[ -r ]`/`[ -f ]`
	# fails with ELOOP first -- so the hop cap is pinned here, on the function
	# itself. Run with a deadline: without the cap this never returns, and a
	# hung suite is a worse signal than a red test.
	( umask 022 && ln -s "$TESTDIR/loop-a.conf" "$TESTDIR/loop-b.conf" )
	( umask 022 && ln -s "$TESTDIR/loop-b.conf" "$TESTDIR/loop-a.conf" )
	local pid i=0
	config_file_is_safe "$TESTDIR/loop-a.conf" & pid=$!
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null
		echo "config_file_is_safe did not return on a symlink loop" >&2
		return 1
	fi
	assert_fails wait "$pid"
}
