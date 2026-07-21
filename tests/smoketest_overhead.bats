#!/usr/bin/env bats
#
# Tests for the host-side overhead sampler folded into `mackas smoketest`.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# `mackas smoketest` wraps each rung in tools/mackas-overhead. These drive a real
# `mackas smoketest` (parse-only rung, then one build rung with no --target
# since MACKAS_SMOKETEST_TARGETS is empty) against a fake
# kas-container that just succeeds, with the sampler pointed -- via the
# MACKAS_OVERHEAD_BIN test seam -- at a fake that records to a marker file. The
# fake is real Python run under /usr/bin/python3, exactly as production runs it.
# Nothing touches the real Apple container runtime, a volume, or the network.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	# A fake kas-container that records its argv and succeeds -- but sleeps
	# briefly first, so the backgrounded sampler is reliably up (and past
	# interpreter start) before the rung ends and it is signalled.
	mkdir -p "$ROOT/bin" "$ROOT/work/meta-ai/.git" "$ROOT/work/meta-ai/kas"
	touch "$ROOT/work/meta-ai/kas/macos-local.yml"
	KLOG="$TESTDIR/kas.log"
	export KLOG
	cat > "$ROOT/bin/kas-container" <<'EOF'
#!/usr/bin/env bash
printf 'KAS:%s\n' "$*" >> "$KLOG"
sleep 0.4
exit 0
EOF
	chmod +x "$ROOT/bin/kas-container"

	# A fake sampler: production always invokes it as `/usr/bin/python3 <bin>`,
	# so it must be valid Python. It installs its SIGTERM handler FIRST, records
	# STARTED, prints the two headline lines the hook greps, then idles until
	# signalled -- recording TERMED on the way out.
	SAMPLER_MARKER="$TESTDIR/sampler.marker"
	export SAMPLER_MARKER
	SAMPLER="$TESTDIR/fake-sampler"
	export SAMPLER
	cat > "$SAMPLER" <<'EOF'
import os, signal, sys, time
marker = os.environ["SAMPLER_MARKER"]
def note(s):
    with open(marker, "a") as f:
        f.write(s + "\n")
def stop(*_):
    note("TERMED")
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
note("STARTED")
print("host CPU  1.0 CPU-seconds consumed during window")
print("host RSS  peak 100.0 MB  mean 90.0 MB")
sys.stdout.flush()
while True:
    time.sleep(0.05)
EOF
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

smoketest() {
	run "$MACKAS" -y --set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_PROJECT_DIR=meta-ai \
		--set "MACKAS_SMOKETEST_TARGETS=" "$@" smoketest
}

# ---------------------------------------------------------------------------
# The hook starts and stops the sampler
# ---------------------------------------------------------------------------

@test "smoketest: starts the sampler around the rung and stops it afterwards" {
	MACKAS_OVERHEAD_BIN="$SAMPLER" smoketest
	[ "$status" -eq 0 ]
	# Rung passed AND the sampler both ran and was signalled.
	printf '%s\n' "$output" | grep -qF '[OK]'
	grep -qxF 'STARTED' "$SAMPLER_MARKER"
	grep -qxF 'TERMED' "$SAMPLER_MARKER"
}

@test "smoketest: the sampler summary is folded into the rung log" {
	MACKAS_OVERHEAD_BIN="$SAMPLER" smoketest
	[ "$status" -eq 0 ]
	# Pin the exact rung log file (not just "somewhere under logs/"): the
	# overhead section and headline host figures must land IN it. Rung 1 (the
	# parse-only rung) is guaranteed singular even though the default empty
	# MACKAS_SMOKETEST_TARGETS now adds a second, no-target build rung.
	local logf
	logf="$(ls "$ROOT/logs/"smoketest-1-*.log)"
	[ -f "$logf" ]
	grep -qF 'host-side overhead (mackas-overhead)' "$logf"
	grep -qF 'host CPU  1.0 CPU-seconds' "$logf"
}

@test "smoketest: prints the headline host CPU/RSS to the console" {
	MACKAS_OVERHEAD_BIN="$SAMPLER" smoketest
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'host CPU  1.0 CPU-seconds'
	printf '%s\n' "$output" | grep -qF 'host RSS  peak 100.0 MB'
}

# ---------------------------------------------------------------------------
# A sampler failure must never fail the build
# ---------------------------------------------------------------------------

@test "smoketest: a sampler that crashes does not fail the rung" {
	# A sampler that exits non-zero the instant it starts.
	printf 'import sys\nsys.exit(1)\n' > "$TESTDIR/broken-sampler"
	MACKAS_OVERHEAD_BIN="$TESTDIR/broken-sampler" smoketest
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[OK]'
	# The rung's build still ran.
	grep -q 'KAS:' "$KLOG"
}

@test "smoketest: a missing sampler binary does not fail the rung" {
	MACKAS_OVERHEAD_BIN="$TESTDIR/does-not-exist" smoketest
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[OK]'
}

# ---------------------------------------------------------------------------
# MACKAS_OVERHEAD=0 disables it
# ---------------------------------------------------------------------------

@test "smoketest: MACKAS_OVERHEAD=0 does not start the sampler" {
	MACKAS_OVERHEAD_BIN="$SAMPLER" smoketest --set MACKAS_OVERHEAD=0
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF '[OK]'
	# The sampler never ran, so its marker was never written.
	[ ! -f "$SAMPLER_MARKER" ]
}

@test "smoketest: --dry-run does not start the sampler" {
	MACKAS_OVERHEAD_BIN="$SAMPLER" run "$MACKAS" -y \
		--set "MACKAS_ROOT=$ROOT" --set "MACKAS_SHORT_LINK=$TESTDIR/short" \
		--set MACKAS_RELOCATE_VOLUMES=0 --set "MACKAS_SMOKETEST_TARGETS=" \
		--dry-run smoketest
	[ "$status" -eq 0 ]
	[ ! -f "$SAMPLER_MARKER" ]
}
