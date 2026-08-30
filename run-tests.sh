#!/usr/bin/env bash
#
# mackas test entry point.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs shellcheck (if present), a bash 3.2 syntax check, the bats suite, and
# the Python unittest suite -- every tests/test_*.py, one per Python-side
# component (the mirror server, the tools/ helpers, the uibridge). Discovery
# is by that glob, so a new component's tests run here the moment the file
# exists; an enumerated list in this comment would only rot.
#
# None of this touches the real Apple container runtime, the build SSD, the
# network, sudo, NFS, or the mirror host -- it is safe to run anywhere, any time.
# The runtime half of that is enforced, not merely intended: helpers.bash puts
# tests/mock/bin (a stub `container`) at the front of PATH for every file except
# the *_real ones, tests/hermetic.bats fails if that guard slips, and this
# script plants a recording `container` behind the stub -- ahead of any real
# one -- so the run fails outright if some test got past it anyway.
# The mirror-server tests bind 127.0.0.1 on port 0, which is an ephemeral port
# the kernel picks and nothing else can already hold.
#
# The exceptions are the *_real.bats suites -- real_runtime (real Apple
# container), volume_resize_real (real volume grow), diskmon_real (real
# bitbake driving a volume near-full) and workspace_image_real (real hdiutil).
# All self-SKIP unless MACKAS_REAL_RUNTIME=1, so `bats tests/` discovers them
# here but runs none of their bodies. They are dev-Mac-only, non-hermetic and
# never CI-gated; enable one by hand with
# `MACKAS_REAL_RUNTIME=1 bats tests/real_runtime.bats` (see docs/testing.md).
# They also need a QUIET machine: each refuses while any container holds a
# mackas volume, and fails closed on an inspect race, so a busy runtime turns
# them into skips.
#
#   ./run-tests.sh              # everything (real_runtime.bats stays skipped)
#   ./run-tests.sh tests/shim.bats   # just one bats file
#
# Equivalent to `make test`.

set -euo pipefail

cd -- "$(dirname -- "$0")"

rc=0

hdr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Whole-run hermeticity guard, planted before anything runs. helpers.bash
# shadows `container` with tests/mock/bin for every hermetic bats file; this
# recorder sits BEHIND that stub and IN FRONT of any real binary, so a call
# landing here is one that got past the stub -- a file that skipped
# `load helpers`, rebuilt PATH from scratch, or was wrongly exempted -- or a
# Python test that shelled out for real. That is the slip hermetic.bats cannot
# see from inside a single bats file, and the one that once hung a whole run.
# Off under MACKAS_REAL_RUNTIME=1, where the opt-in suites want the real CLI.
guard_log=""
if [ "${MACKAS_REAL_RUNTIME:-}" != "1" ]; then
	guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/mackas-hermetic.XXXXXX")"
	# EXIT, not the end of the script: the bats-missing path exits early.
	trap 'rm -rf "$guard_dir"' EXIT
	guard_log="$guard_dir/calls"
	mkdir -p "$guard_dir/bin"
	cat > "$guard_dir/bin/container" <<-SH
		#!/bin/sh
		printf '%s\n' "\$*" >> "$guard_log"
		exit 1
	SH
	chmod +x "$guard_dir/bin/container"
	PATH="$guard_dir/bin:$PATH"
	# Named so tests/fixtures/hermeticity-breach.bats can call THIS and never
	# risk a real binary; hermetic.bats drives that file through here.
	export MACKAS_TEST_HERMETIC_RECORDER="$guard_dir/bin/container"
fi

hdr "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	# --severity=warning so the result is stable across shellcheck versions:
	# newer builds emit info-level notes (e.g. SC2015 on an intentional
	# `A && B || C`) that older ones do not, and an info note must not flip a
	# clean run to a failure on one machine but not another.
	if shellcheck --severity=warning -s bash mackas bin/docker run-tests.sh \
		tests/mock/container tests/mock/bin/container; then
		echo "shellcheck: clean"
	else
		echo "shellcheck: FAILED" >&2
		rc=1
	fi
else
	echo "shellcheck not installed; skipping (brew install shellcheck)"
fi

hdr "bash 3.2 syntax check"
# macOS ships bash 3.2 as /bin/bash. mackas must stay compatible with it,
# because that is the interpreter a stock Mac will use.
BASH32=/bin/bash
if [ -x "$BASH32" ]; then
	for f in mackas bin/docker; do
		if "$BASH32" -n "$f"; then
			echo "ok: $f parses under $("$BASH32" --version | head -1 | sed 's/,.*//')"
		else
			echo "FAILED: $f" >&2
			rc=1
		fi
	done
else
	echo "$BASH32 not found; skipping"
fi

hdr "python"
# mackas-mirrord targets Python 3.7+, stdlib only, so it runs on whatever the
# mirror host already has. py_compile is the floor; the unittest suite -- all
# the test_*.py files, not just the mirror server's -- is the point.
if command -v python3 >/dev/null 2>&1; then
	pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
	if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)'; then
		if python3 -m py_compile mirror-server/mackas-mirrord; then
			echo "ok: mirror-server/mackas-mirrord compiles under python $pyver"
		else
			echo "FAILED: mirror-server/mackas-mirrord does not compile" >&2
			rc=1
		fi
		# ruff or pyflakes if the host happens to have one; neither is required.
		if command -v ruff >/dev/null 2>&1; then
			ruff check mirror-server/mackas-mirrord tests/test_mirrord.py || rc=1
		elif python3 -m pyflakes --version >/dev/null 2>&1; then
			python3 -m pyflakes mirror-server/mackas-mirrord tests/test_mirrord.py || rc=1
		else
			echo "no ruff/pyflakes; skipping the python linter"
		fi
		if [ $# -eq 0 ]; then
			python3 -m unittest discover -s tests -p 'test_*.py' || rc=1
		fi
	else
		echo "python3 is $pyver; mackas-mirrord needs 3.7+. Skipping." >&2
		rc=1
	fi
else
	echo "python3 not found; skipping the mirror-server tests" >&2
fi

hdr "bats"
if ! command -v bats >/dev/null 2>&1; then
	echo "bats not installed. Install it with:" >&2
	echo "    brew install bats-core" >&2
	exit 1
fi

if [ $# -gt 0 ]; then
	bats "$@" || rc=1
else
	bats tests/ || rc=1
fi

if [ -n "$guard_log" ] && [ -s "$guard_log" ]; then
	echo "hermeticity: FAILED -- a test reached a container CLI past tests/mock/bin's stub:" >&2
	sort -u "$guard_log" | sed 's/^/    container /' >&2
	rc=1
fi

if [ "$rc" -eq 0 ]; then
	printf '\n\033[32mAll checks passed.\033[0m\n'
else
	printf '\n\033[31mSome checks FAILED.\033[0m\n' >&2
fi
exit "$rc"
