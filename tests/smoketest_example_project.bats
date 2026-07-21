#!/usr/bin/env bats
#
# Tests for smoketest's ephemeral "no project configured" example-project
# offer (offer_example_project/cleanup_example_project in mackas).
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hermetic: a fake `container` (runtime up, everything else a no-op), a real
# local `git init` fixture repo standing in for qualcomm-linux/meta-ai (via
# the MACKAS_EXAMPLE_PROJECT_URL/_BRANCH/_KAS_CONFIG test seam -- an
# undocumented override, never a real setting), and a fake kas-container that
# just succeeds and records its argv/cwd. Nothing touches the real Apple
# container runtime, the real network, or the real meta-ai repo.
#
# confirm() refuses to even prompt when stdin is not a terminal (see
# tests/config.bats and mackas's own confirm()) -- exactly bats' `run`
# environment -- so accepting the offer here always goes through -y/-f,
# never a piped "y". Declining is simply "no -y, no tty": confirm()'s
# existing non-interactive-refusal behaviour, not anything new here.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN MACKAS_FSTRIM_AUTO
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	export ROOT

	# The real local fixture repo standing in for meta-ai.
	FIXTURE="$TESTDIR/fixture.git"
	mkdir -p "$FIXTURE"
	(
		cd "$FIXTURE"
		git init -q -b examplebranch
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		mkdir kas
		echo "# base layer stub" > kas/base.yml
		git add -A
		git -c user.email=t@t -c user.name=t commit -q -m base
	)
	export MACKAS_EXAMPLE_PROJECT_URL="$FIXTURE"
	export MACKAS_EXAMPLE_PROJECT_BRANCH="examplebranch"
	export MACKAS_EXAMPLE_KAS_CONFIG="kas/base.yml"

	mkdir -p "$TESTDIR/fakebin"

	# Fake container: runtime up, everything else inert (no volumes, no
	# running containers -- auto-fstrim and the one-VM check stay out of the way).
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1" in --version) echo "container CLI 0.0-fake"; exit 0 ;; esac
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"image ls")      echo "NAME TAG"; exit 0 ;;
	"volume ls")     echo "NAME"; exit 0 ;;
	"container ls"|"ls "*|"ls") echo "ID"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"

	# Fake kas-container: always succeeds, records its cwd + argv.
	mkdir -p "$ROOT/bin"
	KLOG="$TESTDIR/kas.log"
	export KLOG
	cat > "$ROOT/bin/kas-container" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s ARGV=%s\n' "$PWD" "$*" >> "$KLOG"
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container"

	PATH="$TESTDIR/fakebin:$ROOT/bin:$PATH"
	export PATH
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

smoketest() {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/no-such-link" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set "MACKAS_SMOKETEST_TARGETS=" "$@" smoketest
}

@test "smoketest: offers the example project when nothing is configured" {
	smoketest -y
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'no project is configured'
	printf '%s\n' "$output" | grep -qi 'meta-ai example'
}

@test "smoketest: -y accepts the offer, clones, builds, then removes every trace" {
	smoketest -y
	[ "$status" -eq 0 ]
	# It really cloned the fixture and ran kas against it.
	grep -q "bitbake -p" "$KLOG"
	# ...and cleaned up afterward: no checkout survives.
	[ ! -d "$ROOT/work/meta-ai" ]
	printf '%s\n' "$output" | grep -qi 'removing the meta-ai example project'
}

@test "smoketest: without -y and no tty, the offer is declined and nothing runs" {
	smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	[ ! -f "$KLOG" ]
	[ ! -d "$ROOT/work/meta-ai" ]
}

@test "smoketest: declining never leaves a checkout or fragment behind" {
	smoketest
	[ ! -d "$ROOT/work" ] || [ -z "$(ls -A "$ROOT/work" 2>/dev/null)" ]
}

@test "smoketest: a real project configured (even if not yet cloned) never triggers the offer" {
	run "$MACKAS" --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/no-such-link" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set "MACKAS_PROJECT_URL=$FIXTURE" \
		-y smoketest
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'project not checked out'
	! printf '%s\n' "$output" | grep -qi 'meta-ai example'
}

@test "smoketest: the example project is never written to the config file" {
	# Nothing in offer_example_project ever calls 'mackas set' or otherwise
	# touches a config file -- confirm no file appears on the ordinary search
	# path (~/.mackas.conf) as a side effect of accepting the offer.
	[ ! -e "$HOME/.mackas.conf" ]
	smoketest -y
	[ "$status" -eq 0 ]
	[ ! -e "$HOME/.mackas.conf" ]
}
