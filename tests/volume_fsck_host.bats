#!/usr/bin/env bats
#
# Tests for the HOST fast path of `mackas volume fsck`: when a working
# e2fsck is available on the host (host_e2fsck_bin()), volume_fsck_one()
# runs it directly against the APFS clone -- no throwaway container, no
# loop device, no apt-get. tests/volume_mgmt.bats covers the (still
# unconditional fallback) container path; this file covers the host path
# specifically, via the MACKAS_FSCK_HOST_E2FSCK_BIN test seam so it runs
# deterministically regardless of what is actually installed on the
# machine running the suite.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The fake host e2fsck below mirrors the real tool's exit-code contract
# (0 clean, 1-7 errors corrected/still-dirty, >=8 operational/unrepairable)
# rather than the container mock's marker-line protocol -- fsck_host_run()
# is the thing translating real e2fsck exit codes into those same marker
# lines, so this file is what actually exercises that translation.

bats_require_minimum_version 1.5.0

load helpers

VOLDIR() { printf '%s/Library/Application Support/com.apple.container/volumes' "$HOME"; }

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	CLOG="$TESTDIR/container.log"
	export CLOG

	# The fake `container` here handles ONLY what setup/the one-VM check
	# need (system status, volume ls/create, ls/inspect for the busy
	# check) -- deliberately no ':/vol' fsck branch at all, so if
	# volume_fsck_one() ever fell back to the container path despite the
	# host one being forced available, the test would fail loudly (the
	# fake would fall through to its final `exit 0` with none of the
	# MACKAS-FSCK markers fsck_host_run()'s caller looks for).
	VSTATE="$TESTDIR/volumes.state"
	export VSTATE
	: > "$VSTATE"
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$CLOG"
voldir="$HOME/Library/Application Support/com.apple.container/volumes"
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls")
		echo "NAME TYPE DRIVER OPTIONS"
		while IFS="$(printf '\t')" read -r n s; do
			[ -n "$n" ] || continue
			printf '%s named local size=%s\n' "$n" "$s"
		done < "$VSTATE"
		exit 0 ;;
	"ls "*|"ls") echo "ID"; exit 0 ;;
	"inspect "*) exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"

	# The fake HOST e2fsck (this is what MACKAS_FSCK_HOST_E2FSCK_BIN points
	# at) -- mirrors real e2fsck's own exit-code contract, not a marker-line
	# protocol: 0 clean, 1-7 corrected-but-nonzero, >=8 operational/
	# unrepairable. A sibling ".repaired-marker" file tracks "already
	# repaired" across the three separate invocations (-n, -y, -n) fsck_host_run()
	# makes, since each is its own process with no shared memory.
	E2FSCK_LOG="$TESTDIR/e2fsck.log"
	export E2FSCK_LOG
	cat > "$TESTDIR/fake-e2fsck" <<'EOF'
#!/usr/bin/env bash
printf 'CALL: %s\n' "$*" >> "$E2FSCK_LOG"
mode="$2"; img="$3"
case "${MOCK_HOST_FSCK_STATE:-clean}" in
	clean) exit 0 ;;
	dirty-repairable)
		if [ "$mode" = "-n" ]; then
			[ -f "$img.repaired-marker" ] && exit 0
			exit 1
		else
			sz="$(stat -f %z "$img" 2>/dev/null)"
			if [ -n "$sz" ]; then
				/usr/bin/python3 -c '
import sys
p = sys.argv[1]; sz = int(sys.argv[2])
with open(p, "r+b") as f:
	f.write(b"REPAIRED-BY-FAKE-HOST-E2FSCK")
	f.truncate(sz)
' "$img" "$sz"
			fi
			touch "$img.repaired-marker"
			exit 1
		fi
		;;
	unrepairable)
		if [ "$mode" = "-n" ]; then exit 1; else exit 8; fi
		;;
esac
EOF
	chmod +x "$TESTDIR/fake-e2fsck"
	MACKAS_FSCK_HOST_E2FSCK_BIN="$TESTDIR/fake-e2fsck"
	export MACKAS_FSCK_HOST_E2FSCK_BIN
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

vol() {
	PATH="$TESTDIR/fakebin:$PATH" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 volume "$@"
}

# have_volume NAME SIZE [KB] -- register NAME directly (VSTATE + on-disk
# dir/entity.json/volume.img), same shape volume_mgmt.bats' own helper uses;
# no need to round-trip through a real 'volume create' call.
have_volume() {
	local name="$1" size="$2" kb="${3:-8192}"
	printf '%s\t%s\n' "$name" "$size" >> "$VSTATE"
	mkdir -p "$(VOLDIR)/$name"
	: > "$(VOLDIR)/$name/entity.json"
	dd if=/dev/zero of="$(VOLDIR)/$name/volume.img" bs=1024 count="$kb" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The host path is actually taken, and no container fsck call ever happens
# ---------------------------------------------------------------------------

@test "volume fsck: uses the host e2fsck when available, no ':/vol' container call at all" {
	have_volume oe-build-tmp 120G 8192
	MOCK_HOST_FSCK_STATE=clean vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/fake-e2fsck (host, no container needed)"
	printf '%s\n' "$output" | grep -qi "clean -- no repair needed"
	! grep -qF ':/vol]' "$CLOG"
	grep -qF -- '-n' "$E2FSCK_LOG"
}

@test "volume fsck: --dry-run's preview names the host e2fsck, not a container run" {
	have_volume oe-build-tmp 120G 8192
	MOCK_HOST_FSCK_STATE=clean vol --dry-run -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/fake-e2fsck"
	! printf '%s\n' "$output" | grep -qF 'container run'
	[ ! -f "$E2FSCK_LOG" ]
}

# ---------------------------------------------------------------------------
# Full repair flow via the host path -- same outcome the container path
# already proves in tests/volume_mgmt.bats, now via fsck_host_run()'s
# translation of real e2fsck exit codes into the same downstream handling.
# ---------------------------------------------------------------------------

@test "volume fsck: corruption via the host path is detected, backed up, repaired, and promoted" {
	have_volume oe-build-tmp 120G 8192
	img="$(VOLDIR)/oe-build-tmp/volume.img"
	orig_sz="$(stat -f %z "$img")"

	MOCK_HOST_FSCK_STATE=dirty-repairable vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi "repaired 'oe-build-tmp'"

	# The pre-repair image is kept, byte-identical to the untouched original.
	kept="$(find "$(VOLDIR)/oe-build-tmp" -maxdepth 1 -name 'volume.img.mackas-corrupt-*')"
	[ -n "$kept" ]
	[ "$(stat -f %z "$kept")" = "$orig_sz" ]

	# The promoted volume.img is the REPAIRED bytes (fake host e2fsck's own
	# marker string), same size as before.
	grep -qF "REPAIRED-BY-FAKE-HOST-E2FSCK" "$img"
	[ "$(stat -f %z "$img")" = "$orig_sz" ]
}

@test "volume fsck: declining the promotion via the host path leaves everything untouched" {
	# No -y, stdin not a tty: the clone and the host e2fsck rehearsal both
	# run on their own -- neither touches '$name' itself, so neither is
	# gated on a confirmation. The only question is whether to promote the
	# rehearsed repair, and with no -y and no tty confirm() declines that
	# one -- same shape as volume_mgmt.bats' matching container-path test.
	have_volume oe-build-tmp 120G 8192
	img="$(VOLDIR)/oe-build-tmp/volume.img"
	before_sum="$(shasum "$img" | awk '{print $1}')"
	MOCK_HOST_FSCK_STATE=dirty-repairable vol fsck oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "left unchanged"
	[ "$(shasum "$img" | awk '{print $1}')" = "$before_sum" ]
	# The host e2fsck DID run (this is the behavior change: no longer gated
	# behind a confirmation) -- only the promotion was declined.
	[ -f "$E2FSCK_LOG" ]
}

@test "volume fsck --check-only via the host path: dirty is reported, nothing repaired or promoted" {
	have_volume oe-build-tmp 120G 8192
	img="$(VOLDIR)/oe-build-tmp/volume.img"
	orig_sz="$(stat -f %z "$img")"
	MOCK_HOST_FSCK_STATE=dirty-repairable vol -y fsck oe-build-tmp --check-only
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'NOT clean'
	! find "$(VOLDIR)/oe-build-tmp" -maxdepth 1 -name 'volume.img.mackas-corrupt-*' | grep -q .
	[ "$(stat -f %z "$img")" = "$orig_sz" ]
}

@test "volume fsck: an unrepairable image via the host path is reported, original untouched" {
	have_volume oe-build-tmp 120G 8192
	img="$(VOLDIR)/oe-build-tmp/volume.img"
	orig_sz="$(stat -f %z "$img")"
	MOCK_HOST_FSCK_STATE=unrepairable vol -y fsck oe-build-tmp
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'could not bring a copy'
	[ "$(stat -f %z "$img")" = "$orig_sz" ]
}

# ---------------------------------------------------------------------------
# host_e2fsck_bin()'s own detection/test-seam contract
# ---------------------------------------------------------------------------

@test "host_e2fsck_bin: MACKAS_FSCK_HOST_E2FSCK_BIN set-but-empty forces the container path" {
	have_volume oe-build-tmp 120G 8192
	MACKAS_FSCK_HOST_E2FSCK_BIN="" MOCK_FSCK_STATE=clean \
		PATH="$TESTDIR/fakebin:$PATH" run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" --set MACKAS_RELOCATE_VOLUMES=0 \
		volume -y fsck oe-build-tmp
	# This test's own fake container has no ':/vol' branch (falls through to
	# a bare `exit 0`, no MACKAS-FSCK markers at all), so forcing the
	# container path here must surface as mackas not understanding the
	# (empty) result -- proof it really tried the container, not the host.
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'no result mackas understands'
	[ ! -f "$E2FSCK_LOG" ]
}

@test "host_e2fsck_bin: an explicit MACKAS_FSCK_HOST_E2FSCK_BIN path is used verbatim, no detection" {
	have_volume oe-build-tmp 120G 8192
	MOCK_HOST_FSCK_STATE=clean vol -y fsck oe-build-tmp
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/fake-e2fsck"
}
