#!/usr/bin/env bats
#
# M5 (#79): the dump retrofit and clean's log wipe, scoped to the
# selected project -- end to end, as a real subprocess, with real filesystem
# checks. tests/project_logs.bats covers the derive_paths()/smoketest_rung()
# half at the library level; this file is the other half: `mackas dump`,
# `mackas status` and bare `mackas clean` actually touching disk.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The clean test below is the one that matters most: it proves bare `clean`
# under a selected project removes ONLY that project's own logs/<name>,
# never a sibling project's logs/<other> and never the flat legacy dir that
# predates any project ever being selected on this MACKAS_ROOT.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY MACKAS_CPUS
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	export HOME="$TESTDIR/home"
	mkdir -p "$HOME"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"

	ROOT="$TESTDIR/oe"
	mkdir -p "$ROOT/bin" "$ROOT/work/meta-qcom/.git" "$ROOT/work/meta-angstrom/.git"
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"

	# kas-container.real: records every argv line and, for a `dump` call,
	# prints a canned "resolved" YAML to stdout -- same shape as
	# tests/lock_dump.bats and tests/generated_paths_compat.bats.
	KLOG="$TESTDIR/kas-container.log"
	export KLOG
	EXIT_CODE_FILE="$TESTDIR/kas-exit-code"
	echo 0 > "$EXIT_CODE_FILE"
	export EXIT_CODE_FILE
	DUMP_STDOUT="$TESTDIR/dump-stdout"
	echo "resolved: yaml" > "$DUMP_STDOUT"
	export DUMP_STDOUT
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
{
	printf 'CALL:'
	for a in "$@"; do printf ' [%s]' "$a"; done
	printf '\n'
} >> "$KLOG"
for a in "$@"; do
	if [ "$a" = "dump" ] && [ -f "${DUMP_STDOUT:-}" ]; then
		cat "$DUMP_STDOUT"
		break
	fi
done
rc=0
[ -f "$EXIT_CODE_FILE" ] && rc="$(cat "$EXIT_CODE_FILE")"
exit "$rc"
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	# container: the Apple `container` CLI mackas resolves by bare name.
	# Tracks ext4 volume state (create/delete/ls) in VSTATE, the same
	# mechanism tests/volumes_cmd.bats and tests/generated_paths_compat.bats
	# use, so bare `clean` here really deletes-and-recreates the TMPDIR
	# volume rather than tripping over a static fake.
	CLOG="$TESTDIR/container.log"
	export CLOG
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
case "$1 $2" in
	"volume ls")
		echo "NAME"
		grep -v '^$' "$VSTATE" 2>/dev/null || true
		;;
	"volume create")
		# ... -s SIZE NAME
		eval "name=\${$#}"
		printf '%s\n' "$name" >> "$VSTATE"
		;;
	"volume delete"|"volume rm")
		grep -vxF "$3" "$VSTATE" > "$VSTATE.new" 2>/dev/null || true
		mv "$VSTATE.new" "$VSTATE"
		;;
	"system status") echo "status running" ;;
	"system start") : ;;
	"image ls") echo "NAME TAG"; echo "ghcr.io/siemens/kas/kas 5.5" ;;
	"--version "*|"--version") echo "container CLI version 1.1.0" ;;
	"ls "*|"ls") echo "ID" ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	chmod -R u+rwX "$TESTDIR" 2>/dev/null || true
	rm -rf "$TESTDIR"
}

# Write a pinned project config named $1, selecting MACKAS_PROJECT_DIR=$1 so
# the checkout is $ROOT/work/$1 -- same shape as tests/project_select.bats'
# own pin() helper.
pin() {
	printf 'MACKAS_PROJECT_DIR="%s"\n' "$1" > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

have_volumes() {
	printf '%s\n' "$@" > "$VSTATE"
}

mkp() {
	local proj="$1"; shift
	run "$MACKAS" -y --project "$proj" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

# Same, with no project selected at all -- the legacy side of the asymmetry.
mk() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 "$@"
}

@test "dump (selected): writes to the project's own logs/<name>/dump-<ts>.yml, not the flat path" {
	pin meta-qcom
	MACKAS_DUMP_TS=20260901000000 mkp meta-qcom dump
	[ "$status" -eq 0 ]
	[ -f "$ROOT/logs/meta-qcom/dump-20260901000000.yml" ]
	grep -qF "resolved: yaml" "$ROOT/logs/meta-qcom/dump-20260901000000.yml"
	[ ! -e "$ROOT/logs/dump-20260901000000.yml" ]
	printf '%s\n' "$output" | grep -qF "$ROOT/logs/meta-qcom/dump-20260901000000.yml"
}

@test "status (selected): Recent logs section reads the project's own logs/<name>/, not the flat dir" {
	pin meta-qcom
	mkdir -p "$ROOT/logs/meta-qcom"
	echo x > "$ROOT/logs/meta-qcom/sentinel-selected.txt"
	mkdir -p "$ROOT/logs"
	echo y > "$ROOT/logs/sentinel-flat.txt"
	mkp meta-qcom status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qxF "  sentinel-selected.txt"
	! printf '%s\n' "$output" | grep -qxF "  sentinel-flat.txt"
}

@test "clean (selected): removes exactly logs/<name>, leaving a sibling project's logs and the flat legacy dir intact" {
	pin meta-qcom
	pin meta-angstrom
	have_volumes mackas-meta-qcom-tmp mackas-meta-qcom-dl mackas-meta-qcom-sstate

	mkdir -p "$ROOT/logs/meta-qcom"
	echo "old-qcom" > "$ROOT/logs/meta-qcom/dump-old.yml"
	mkdir -p "$ROOT/logs/meta-angstrom"
	echo "sibling" > "$ROOT/logs/meta-angstrom/sibling.txt"
	mkdir -p "$ROOT/logs"
	echo "legacy" > "$ROOT/logs/legacy-flat.yml"

	mkp meta-qcom clean
	[ "$status" -eq 0 ]

	# The one assertion that matters most: a real filesystem check, not a
	# string match on help text.
	[ -d "$ROOT/logs/meta-qcom" ]
	[ -z "$(ls -A "$ROOT/logs/meta-qcom")" ]
	[ -f "$ROOT/logs/meta-angstrom/sibling.txt" ]
	[ -f "$ROOT/logs/legacy-flat.yml" ]

	# The confirmation text names the directory it actually removed.
	printf '%s\n' "$output" | grep -qF "$ROOT/logs/meta-qcom"
	! printf '%s\n' "$output" | grep -qF "$ROOT/logs/meta-angstrom"
}

# The isolation above is deliberately one-way, and that is worth pinning
# rather than leaving as an accident: an UNSELECTED bare `clean` wipes
# MACKAS_LOGS, which with nothing selected is the flat logs/ -- so every
# project's logs/<name> under it goes too. Narrowing it would break the
# backward-compatibility contract in tests/generated_paths_compat.bats
# (bare clean has always cleared the whole logs dir); widening the selected
# case would break the sibling isolation above. `clean --help` says so.
@test "clean (unselected): wipes the whole flat logs/, per-project subdirs included" {
	pin meta-qcom
	have_volumes oe-build-tmp oe-build-dl oe-build-sstate

	mkdir -p "$ROOT/logs/meta-qcom"
	echo "qcom" > "$ROOT/logs/meta-qcom/dump-old.yml"
	echo "legacy" > "$ROOT/logs/legacy-flat.yml"

	mk clean
	[ "$status" -eq 0 ]
	[ -d "$ROOT/logs" ]
	[ -z "$(ls -A "$ROOT/logs")" ]
	[ ! -e "$ROOT/logs/meta-qcom" ]
}

@test "clean --help: says the flat wipe takes every project's logs/<name> with it" {
	mk clean --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "never a sibling's"
	printf '%s\n' "$output" | grep -qF "logs/<name> sitting under it along with it"
}

# status's "Recent logs" prints bare filenames, so "Derived paths" is the
# only place that says which directory they came out of -- which now moves
# with the selector.
@test "status: Derived paths names the log directory, per-project when selected" {
	pin meta-qcom
	mkp meta-qcom status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE "^  logs +$ROOT/logs/meta-qcom\$"

	mk status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE "^  logs +$ROOT/logs\$"
}
