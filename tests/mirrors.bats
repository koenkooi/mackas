#!/usr/bin/env bats
#
# Tests for the mirror knobs that feed the generated kas fragment:
# MACKAS_USE_HTTP_MIRRORS / MACKAS_USE_NFS_MIRRORS and their URLs and paths.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The fragment is what bitbake actually reads, so the exact bytes matter --
# especially ';downloadfilename=PATH', which is valid for http:// mirrors and
# NOT for file:// ones. These call setup_kas_fragment directly with
# MACKAS_LIB_ONLY=1 and read the file it writes. Nothing touches the network.
#
# NOTE: bats' own `run` helper must not be used here, for the same reason
# units.bats avoids it -- mackas defines a run() of its own (the verbose/
# dry-run command wrapper) and sourcing the script shadows bats' version.
# These use command substitution and explicit subshells instead.

load helpers

setup() {
	MACKAS_LIB_ONLY=1
	export MACKAS_LIB_ONLY
	# shellcheck disable=SC1090
	. "$MACKAS"
	TESTDIR="$(make_tmpdir)"
	setup_colors
	set_defaults
	MACKAS_ROOT="$TESTDIR"
	MACKAS_SHORT_LINK="/nonexistent-short-link-xyzzy"
	derive_paths
	DRY_RUN=0
}

teardown() {
	rm -rf "$TESTDIR"
}

frag() {
	cat "$MACKAS_KAS_FRAGMENT_SRC"
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

@test "mirrors: both mirror paths are off by default" {
	[ "$MACKAS_USE_HTTP_MIRRORS" = "0" ]
	[ "$MACKAS_USE_NFS_MIRRORS" = "0" ]
}

@test "mirrors: the default HTTP mirror URLs use mackas-mirrord's port 8100" {
	# 8100 is mackas-mirrord's own default; the host is a placeholder.
	printf '%s\n' "$MACKAS_HTTP_MIRROR_SSTATE" | grep -q ':8100/sstate$'
	printf '%s\n' "$MACKAS_HTTP_MIRROR_DL" | grep -q ':8100/downloads$'
}

@test "mirrors: both default URLs use the SAME port (one process, two prefixes)" {
	s_port="$(printf '%s' "$MACKAS_HTTP_MIRROR_SSTATE" | sed 's|.*:\([0-9]*\)/.*|\1|')"
	d_port="$(printf '%s' "$MACKAS_HTTP_MIRROR_DL" | sed 's|.*:\([0-9]*\)/.*|\1|')"
	[ "$s_port" = "$d_port" ]
}

@test "mirrors: no mirror stanza in the fragment when both are off" {
	setup_kas_fragment
	out="$(frag)"
	# Assert ABSENT with `! ... | grep -q`. The -qv form does NOT assert
	# absence: it exits 0 whenever any single line lacks the pattern, so on
	# multi-line output it passes whether the stanza is present or not. (ugrep's
	# -qv happens to behave as intended, which hid this on the dev machine while
	# it lied on stock BSD grep / CI.)
	! printf '%s\n' "$out" | grep -q "SSTATE_MIRRORS"
	! printf '%s\n' "$out" | grep -q "SOURCE_MIRROR_URL"
	# The parallelism stanza must still be there.
	printf '%s\n' "$out" | grep -q "BB_NUMBER_THREADS"
}

# ---------------------------------------------------------------------------
# HTTP mirrors
# ---------------------------------------------------------------------------

@test "mirrors: HTTP fragment has downloadfilename=PATH (valid for http://)" {
	MACKAS_USE_HTTP_MIRRORS=1
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -qF 'SSTATE_MIRRORS ?= "file://.* http://linux-computer.local:8100/sstate/PATH;downloadfilename=PATH"'
}

@test "mirrors: HTTP fragment sets SOURCE_MIRROR_URL and inherits own-mirrors" {
	MACKAS_USE_HTTP_MIRRORS=1
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -qF 'SOURCE_MIRROR_URL ?= "http://linux-computer.local:8100/downloads"'
	printf '%s\n' "$out" | grep -qF 'INHERIT += "own-mirrors"'
}

@test "mirrors: custom HTTP mirror URLs land in the fragment verbatim" {
	MACKAS_USE_HTTP_MIRRORS=1
	MACKAS_HTTP_MIRROR_SSTATE="https://mirror.example:9443/ss"
	MACKAS_HTTP_MIRROR_DL="https://mirror.example:9443/dl"
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -qF 'https://mirror.example:9443/ss/PATH;downloadfilename=PATH'
	printf '%s\n' "$out" | grep -qF 'SOURCE_MIRROR_URL ?= "https://mirror.example:9443/dl"'
}

@test "mirrors: the HTTP fragment is valid YAML-ish under local_conf_header" {
	MACKAS_USE_HTTP_MIRRORS=1
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -q '^  macos-mirrors: |$'
	printf '%s\n' "$out" | grep -q '^header:$'
	printf '%s\n' "$out" | grep -q '^  version: 14$'
	# Every mirror line must be indented four spaces to sit inside the block
	# scalar. One wrong indent and kas rejects the whole file.
	printf '%s\n' "$out" | grep -q '^    SSTATE_MIRRORS '
	printf '%s\n' "$out" | grep -q '^    SOURCE_MIRROR_URL '
}

# ---------------------------------------------------------------------------
# NFS mirrors -- the existing behaviour, guarded against regression
# ---------------------------------------------------------------------------

@test "mirrors: NFS fragment does NOT use downloadfilename (invalid for file://)" {
	# This is the regression guard. downloadfilename= is meaningful only for
	# http:// mirrors; putting it on a file:// one is wrong, and the repo
	# already got this right.
	MACKAS_USE_NFS_MIRRORS=1
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -q "SSTATE_MIRRORS"
	# ABSENT via `! ... | grep -q` (the -qv form passes vacuously).
	! printf '%s\n' "$out" | grep -q "downloadfilename"
}

@test "mirrors: NFS fragment uses the container-side bind mount paths" {
	MACKAS_USE_NFS_MIRRORS=1
	setup_kas_fragment
	out="$(frag)"
	printf '%s\n' "$out" | grep -qF 'file:///sstate-mirror/PATH'
	printf '%s\n' "$out" | grep -qF 'file:///downloads-mirror'
}

# ---------------------------------------------------------------------------
# Conflict
# ---------------------------------------------------------------------------

@test "mirrors: enabling both HTTP and NFS mirrors is a hard error" {
	# Both emit SSTATE_MIRRORS into the same fragment; bitbake's '?=' would
	# make the first silently win. Refuse rather than guess.
	MACKAS_USE_HTTP_MIRRORS=1
	MACKAS_USE_NFS_MIRRORS=1
	# die() exits, so it must be contained in a subshell.
	out="$( (setup_kas_fragment) 2>&1 )" && rc=0 || rc=$?
	[ "$rc" -ne 0 ]
	printf '%s\n' "$out" | grep -q "both"
	# ...and it must not have written a fragment with a guessed answer in it.
	[ ! -f "$MACKAS_KAS_FRAGMENT_SRC" ]
}

# ---------------------------------------------------------------------------
# Settings plumbing
# ---------------------------------------------------------------------------

@test "mirrors: the new knobs are real settings (--set accepts them)" {
	is_setting_name MACKAS_USE_HTTP_MIRRORS
	is_setting_name MACKAS_HTTP_MIRROR_SSTATE
	is_setting_name MACKAS_HTTP_MIRROR_DL
}

# The end-to-end precedence check for these knobs lives in config.bats, not
# here: this file exports MACKAS_LIB_ONLY=1 to source the script, and a child
# `mackas status` would inherit it and refuse to do anything.
