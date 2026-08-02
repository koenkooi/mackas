#!/usr/bin/env bats
#
# Tests for the smoketest ladder's FAILURE path -- cmd_smoketest / smoketest_rung.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# volumes.bats source-greps run_kas's `|| rc=$?` tee-pipeline contract (the
# after-trim must still run on a failed build). This is its BEHAVIOURAL
# complement: a real `mackas -y smoketest` against a fake kas-container that fails
# one rung, asserting the ladder STOPS at that rung, the exit is propagated,
# the operator sees [FAILED]/exit-code/log/last-20-lines, and the exact rung
# argv (and cwd) reach kas in order.
#
# Fully hermetic: a fake kas-container ($ROOT/bin/kas-container.real) records $PWD +
# argv per call and keys its exit on the target; a fake `container` on PATH
# makes the auto-fstrim probe and the one-VM check inert so only kas runs.
# Nothing touches the real Apple container runtime, a volume, or the network.

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
	PROJ="$ROOT/work/meta-ai"
	export ROOT PROJ

	# A checkout that cmd_smoketest's three preconditions accept.
	mkdir -p "$ROOT/bin" "$ROOT/logs" "$PROJ/.git" "$PROJ/kas"
	touch "$PROJ/kas/macos-local.yml"
	# run_kas refuses before ever reaching kas-container if the gitconfig it
	# would forward is missing/incomplete -- matching what a real 'setup' run
	# leaves behind at $ROOT/gitconfig.
	printf '[safe]\n\tdirectory = *\n' > "$ROOT/gitconfig"

	# Fake kas-container: record "PWD=<pwd>|ARG=<a>|..." one line per call, emit
	# a body line to stdout so the rung log (tee'd) has content to tail, and exit
	# 3 for the `--target b` build so the ladder must stop there.
	KLOG="$TESTDIR/kas.log"
	export KLOG
	: > "$KLOG"
	cat > "$ROOT/bin/kas-container.real" <<'EOF'
#!/usr/bin/env bash
# Drop the leading `--runtime-args <value>` pair mackas always prepends, so the
# record is the kas SUBCOMMAND argv (the runtime-args string is pinned exactly
# in setup_e2e.bats, not here).
args=( "$@" )
if [ "${args[0]:-}" = "--runtime-args" ]; then args=( "${args[@]:2}" ); fi
{
	line="PWD=$PWD"
	for a in "${args[@]}"; do line="$line|ARG=$a"; done
	printf '%s\n' "$line"
} >> "$KLOG"
echo "kas-fake-stdout-marker: ${args[*]}"
case " ${args[*]} " in
	*" --target b "*) echo "kas-fake: deliberate failure on b" >&2; exit 3 ;;
esac
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container.real"
	# ensure_kas_container_installed (cmd_smoketest calls it) requires BOTH
	# files present -- the wrapper itself must exist too, even though only
	# kas-container.real above is ever exec'd.
	touch "$ROOT/bin/kas-container"
	chmod +x "$ROOT/bin/kas-container"

	# Fake container: system up, but no volumes and no running containers, so
	# auto_fstrim (volume_exists) and volume_in_use are inert. Never runs a real
	# engine even on a host that has one installed.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls")     echo "NAME"; exit 0 ;;
	"container ls"|"ls "*|"ls") echo "ID"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"
	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# Drive a real `mackas -y smoketest` with a three-rung target list, overhead off
# (deterministic, no background sampler) and the short link disabled so
# MACKAS_BASE == MACKAS_ROOT. KAS_CONFIG is pinned so the composed files arg is
# an exact, space-free string.
smoketest() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/no-such-link" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_PROJECT_DIR=meta-ai \
		--set MACKAS_KAS_CONFIG=kas/base.yml \
		--set "MACKAS_SMOKETEST_TARGETS=a b c" "$@" smoketest
}

# The composed kas files argument the ladder passes to kas.
FILES="kas/base.yml:kas/macos-local.yml"

@test "smoketest ladder: stops at the first failing rung and propagates its exit" {
	smoketest
	# The whole command failed (a rung failed), not exit 0.
	[ "$status" -ne 0 ]
	# The failing rung is reported with its exact exit code...
	printf '%s\n' "$output" | grep -qF '[FAILED]'
	printf '%s\n' "$output" | grep -qF '(exit 3)'
	# ...and the later rung never ran: no build argv for target c was recorded.
	! grep -qF -- '|ARG=--target|ARG=c' "$KLOG"
	# The success banner for a passed ladder must NOT appear.
	! printf '%s\n' "$output" | grep -qi 'Smoketest ladder passed'
}

@test "smoketest ladder: a failed rung shows the log path and a last-20-lines tail" {
	smoketest
	[ "$status" -ne 0 ]
	# The exact per-rung log file for the failing build rung (rung 3 = "build b").
	local logf="$ROOT/logs/smoketest-3-build-b.log"
	printf '%s\n' "$output" | grep -qF "see: $logf"
	[ -f "$logf" ]
	printf '%s\n' "$output" | grep -qi 'last 20 lines'
	# The tail really came from that log: the kas stdout body line the fake
	# emitted for the b build is echoed back, indented by smoketest_rung's sed.
	printf '%s\n' "$output" | grep -qF 'kas-fake-stdout-marker: build kas/base.yml:kas/macos-local.yml --target b'
}

@test "smoketest ladder: the exact rung argv order reaches kas, each run in the checkout" {
	smoketest
	[ "$status" -ne 0 ]
	# Rung 1 is parse-only: shell <files> -c "bitbake -p".
	grep -qxF "PWD=$PROJ|ARG=shell|ARG=$FILES|ARG=-c|ARG=bitbake -p" "$KLOG"
	# Rung 2: build <files> --target a (the first target, which passes).
	grep -qxF "PWD=$PROJ|ARG=build|ARG=$FILES|ARG=--target|ARG=a" "$KLOG"
	# Rung 3: build <files> --target b (the failing one).
	grep -qxF "PWD=$PROJ|ARG=build|ARG=$FILES|ARG=--target|ARG=b" "$KLOG"
	# Exactly three kas invocations were recorded: 1 (parse) + 2 (a, b). c never
	# ran because b failed and the ladder returned.
	[ "$(grep -c '^PWD=' "$KLOG")" -eq 3 ]
	# And the parse rung genuinely came first, before either build rung.
	local parse_ln a_ln b_ln
	parse_ln="$(grep -n '|ARG=shell|' "$KLOG" | head -1 | cut -d: -f1)"
	a_ln="$(grep -n '|ARG=--target|ARG=a' "$KLOG" | head -1 | cut -d: -f1)"
	b_ln="$(grep -n '|ARG=--target|ARG=b' "$KLOG" | head -1 | cut -d: -f1)"
	[ "$parse_ln" -lt "$a_ln" ] && [ "$a_ln" -lt "$b_ln" ]
}

@test "smoketest ladder: every rung runs from the project checkout, not the invoker cwd" {
	# cwd matters: kas-container resolves the relative kas files against $PWD and
	# only mounts files under the repo dir, so a rung run from the wrong dir
	# would not find kas/macos-local.yml. Assert no recorded call ran from
	# anywhere but the checkout.
	smoketest
	[ "$status" -ne 0 ]
	# Nothing ran from the test's own cwd (TESTDIR) ...
	! grep -qF "PWD=$TESTDIR|" "$KLOG"
	# ... and every recorded PWD is exactly the checkout.
	local bad
	bad="$(grep -c -v "^PWD=$PROJ|" "$KLOG" || true)"
	[ "$bad" -eq 0 ]
}
