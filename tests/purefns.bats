#!/usr/bin/env bats
#
# Pure-function coverage gaps, exercised in lib-mode (MACKAS_LIB_ONLY=1):
# ip_in_cidr / ip_to_int, fmt_kb's locale guard, and volume_size's sed parse.
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
