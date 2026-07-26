#!/usr/bin/env bats
#
# require_mackas_root as a CLASS: with MACKAS_ROOT unset, every mutating command
# falls back to the current directory ($PWD) with a loud warning rather than
# refusing, and the one read-only exception (`volume list`) works without any
# warning.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The fallback must be ANNOUNCED, never silent: with no root the default volume
# names (oe-build-{tmp,dl,sstate}) still derive, so a command that skipped the
# warning would operate on those real volumes with no hint that no root was
# configured. Asserting the whole class in one loop keeps any single command
# from silently losing the warning. --dry-run keeps it hermetic; the fake
# `container` in setup() is a second backstop.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	export HOME="$TESTDIR"

	# A fake `container` so the read-only `volume list` case never touches the
	# real Apple runtime. The refuse cases die before reaching it.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls")     echo "NAME"; exit 0 ;;   # header only: no volumes
	*)               exit 0 ;;
esac
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

@test "require_mackas_root: every mutating command falls back to \$PWD with a warning" {
	local cmd n=0
	# `volume fstrim all` is a mutating command too: it attaches each volume.
	# `retrieve buildstats` is the mutating one of the retrieve/buildstats pair
	# (buildstats analyze is a read-only local summary and does not gate on a
	# root at all -- see buildstats_analyze.bats).
	# --dry-run so nothing is actually created/destroyed while we probe the class.
	for cmd in setup smoketest shell clean destroy "retrieve buildstats" "volume fstrim all" "clean downloads"; do
		n=$((n + 1))
		# shellcheck disable=SC2086  # deliberate word-split for the two-word case
		run "$MACKAS" --dry-run -y --set "MACKAS_ROOT=" $cmd
		# It must warn that no root is set...
		if ! printf '%s\n' "$output" | grep -qF 'MACKAS_ROOT is not set'; then
			echo "'$cmd' did not warn that no root is set:" >&2
			printf '%s\n' "$output" >&2
			return 1
		fi
		# ...and name the $PWD fallback specifically, not some murkier failure.
		if ! printf '%s\n' "$output" | grep -qF 'using the current directory'; then
			echo "'$cmd' warned, but not about the \$PWD fallback:" >&2
			printf '%s\n' "$output" >&2
			return 1
		fi
	done
	# All eight were actually exercised (guards the loop against a typo that
	# empties the list).
	[ "$n" -eq 8 ]
}

@test "require_mackas_root: 'volume list' works with NO root (it only reads)" {
	# The deliberate exception: listing volumes is read-only, so it must NOT
	# require a root. Refusing it would make it useless in exactly the
	# unconfigured state you reach for it.
	run "$MACKAS" --set "MACKAS_ROOT=" volume list
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'Container volumes'
	# ...and it did not fall through to the root gate.
	! printf '%s\n' "$output" | grep -qF 'MACKAS_ROOT is not set'
}
