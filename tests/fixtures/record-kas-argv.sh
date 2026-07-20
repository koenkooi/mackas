#!/usr/bin/env bash
#
# Re-record the kas-container docker-argv conformance fixture.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run this ONCE per kas-container version bump. It drives the REAL kas-container
# with a recording `docker` stub on PATH: the stub answers kas's engine probe
# (`docker -v`, `docker context show`) and appends the argv of the `docker run`
# it would have issued to the fixture -- WITHOUT ever starting a container. So
# this is safe: no VM, no volume, no build. It reproduces exactly the
# environment mackas's run_kas() sets up (see mackas: KAS_CONTAINER_ENGINE,
# KAS_WORK_DIR, the empty KAS_BUILD_DIR/DL_DIR/SSTATE_DIR, GITCONFIG_FILE,
# KAS_CONTAINER_IMAGE, --runtime-args from kas_runtime_args()).
#
# Usage:
#   tests/fixtures/record-kas-argv.sh /path/to/kas-container
#   KAS_CONTAINER=/Users/koen/oe/bin/kas-container tests/fixtures/record-kas-argv.sh
#
# It writes tests/fixtures/kas-container-<VERSION>.argv, where <VERSION> is the
# KAS_CONTAINER_VERSION pinned in mackas. Commit the result and eyeball the diff.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"

KAS="${1:-${KAS_CONTAINER:-/Users/koen/oe/bin/kas-container}}"
[ -x "$KAS" ] || { echo "no kas-container at '$KAS' (pass it as \$1)" >&2; exit 1; }

# The version the fixture is named for is mackas's pin, not kas's self-report --
# they must agree, and naming from the pin is what the replay guard checks.
VERSION="$(sed -n 's/^KAS_CONTAINER_VERSION="\([^"]*\)".*/\1/p' "$REPO_ROOT/mackas" | head -1)"
[ -n "$VERSION" ] || { echo "could not read KAS_CONTAINER_VERSION from mackas" >&2; exit 1; }

FIX="$HERE/kas-container-${VERSION}.argv"

work="$(mktemp -d "${TMPDIR:-/tmp}/mackas-rec.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# kas resolves mount paths with realpath, and on macOS /var is a symlink to
# /private/var -- so the recorded paths use the RESOLVED form. Normalize that
# one, not the mktemp spelling.
work_real="$(cd "$work" && pwd -P)"
mkdir -p "$work/bin" "$work/work" "$work/proj/kas"
printf 'header:\n  version: 14\n' > "$work/proj/kas/base.yml"
printf 'header:\n  version: 14\n' > "$work/proj/kas/macos-local.yml"
printf '[safe]\n\tdirectory = *\n' > "$work/gitconfig"

cat > "$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -v|--version|version) echo "Docker version 29.3.1, build shim"; exit 0 ;;
esac
if [ "${1:-}" = "context" ] && [ "${2:-}" = "show" ]; then echo "default"; exit 0; fi
{
  printf '=== INVOCATION: %s\n' "${REC_LABEL:-unknown}"
  for a in "$@"; do printf '%s\n' "$a"; done
  printf '=== END\n'
} >> "$REC_FILE"
exit 0
STUB
chmod +x "$work/bin/docker"

FILES="kas/base.yml:kas/macos-local.yml"
# Mirrors kas_runtime_args() with representative, deterministic values.
RT="-c 18 -m 42g -v oe-build-tmp:/build -e KAS_BUILD_DIR=/build"
RT="$RT -v oe-build-dl:/downloads -e DL_DIR=/downloads"
RT="$RT -v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate"

REC_FILE="$work/captured.argv"
export REC_FILE
: > "$REC_FILE"

run_one() {
	label="$1"; shift
	( cd "$work/proj" && \
	  REC_LABEL="$label" \
	  PATH="$work/bin:/opt/homebrew/bin:$PATH" \
	  KAS_CONTAINER_ENGINE=docker \
	  KAS_WORK_DIR="$work/work" \
	  KAS_BUILD_DIR='' DL_DIR='' SSTATE_DIR='' \
	  GITCONFIG_FILE="$work/gitconfig" \
	  KAS_CONTAINER_IMAGE=ghcr.io/siemens/kas/kas:"$VERSION" \
	  BB_NUMBER_THREADS=18 PARALLEL_MAKE="-j 18" \
	  "$KAS" --runtime-args "$RT" "$@" ) </dev/null
}

run_one checkout        checkout "$FILES"
run_one shell-bitbake-p shell "$FILES" -c "bitbake -p"
run_one build-target    build "$FILES" --target core-image-minimal
run_one shell           shell "$FILES"

# Normalize machine-specific values so the fixture is identical on any machine.
norm="$work/normalized.argv"
sed \
	-e "s#$work_real/proj/kas#/MACKAS/work/project/kas#g" \
	-e "s#$work_real/work#/MACKAS/work#g" \
	-e "s#$work_real/gitconfig#/MACKAS/gitconfig#g" \
	-e "s#$work/proj/kas#/MACKAS/work/project/kas#g" \
	-e "s#$work/work#/MACKAS/work#g" \
	-e "s#$work/gitconfig#/MACKAS/gitconfig#g" \
	-e 's/^USER_ID=[0-9]*$/USER_ID=1000/' \
	-e 's/^GROUP_ID=[0-9]*$/GROUP_ID=1000/' \
	"$REC_FILE" > "$norm"

if grep -qE "$work_real|$work" "$norm"; then
	echo "normalization missed a path; refusing to write fixture" >&2
	exit 1
fi

# Emit the documentation header, then the normalized blocks.
cat > "$FIX" <<HDR
# kas-container docker-argv conformance fixture
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# WHAT THIS IS
#   The exact \`docker\` argv that the real kas-container ${VERSION} issues for the
#   four invocations mackas drives: \`checkout\`, \`shell ... -c "bitbake -p"\`,
#   \`build ... --target X\`, and a plain \`shell\`. This pins the *kas half* of the
#   bin/docker shim contract: previously "verified by reading upstream", now
#   recorded from the real tool.
#
# HOW IT WAS RECORDED
#   Run tests/fixtures/record-kas-argv.sh. It points a recording \`docker\` stub
#   (which answers kas's engine probe and appends its argv here, starting no
#   container) at the real kas-container, then normalizes machine-specific values.
#   NO container is ever started; the stub records and exits 0.
#
# NORMALIZATION (so the fixture is identical on any machine)
#   host mount paths -> /MACKAS/... ; USER_ID/GROUP_ID -> 1000. Container-side
#   paths (/repo, /work, /build, ...) and every flag/value SHAPE are verbatim.
#
# FILENAME <-> VERSION
#   The "${VERSION}" in the name is mackas's pinned KAS_CONTAINER_VERSION. tests/
#   kas_argv_replay.bats fails loudly if that pin has no matching fixture, so a
#   version bump without re-recording cannot pass silently.
#
# FORMAT
#   Blocks delimited by \`INVOCATION\` and \`END\` markers; between them, one argv
#   element per line (so a value containing spaces stays one element). Lines
#   starting with \`#\` (outside a block) are comments.
HDR
cat "$norm" >> "$FIX"

echo "wrote $FIX"
