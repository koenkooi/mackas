#!/usr/bin/env bats
#
# End-to-end setup -> fragment -> smoketest chain, fully hermetic.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# All six shipped bugs lived BETWEEN the links: each generator was
# individually plausible, but nothing asserted that setup's output actually
# reaches kas intact. config.bats/volumes.bats pin the generators in isolation;
# this pins the COMPOSITION -- a real `mackas -y setup` followed by a real
# `mackas -y smoketest`, and then a single assertion that the whole chain arrives
# at kas together.
#
# Hermetic seams (no real Apple container runtime, no network, no build SSD):
#   * a fake `container` on PATH: system up, image/volume ops are no-ops, no
#     running containers (so auto-fstrim + the one-VM check are inert);
#   * a fake `curl` that writes a RECORDER kas-container to the download path --
#     it dumps its $PWD, argv and environment to $KREC on every call, which is
#     what lets the chain be inspected end to end;
#   * a fake `shasum` that prints the pinned sum, so setup's sha256 gate passes
#     over the stub the fake curl wrote;
#   * a real local `git init` fixture repo as MACKAS_PROJECT_URL, cloned by real
#     git into the checkout -- a genuine .git, no fake.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN MACKAS_FSTRIM_AUTO
	# These MUST NOT leak in from the caller: the whole point is to prove kas
	# gets them EMPTY / unset from mackas, not from the ambient shell.
	unset KAS_BUILD_DIR DL_DIR SSTATE_DIR KAS_EXTRA_RUNTIME_ARGS GITCONFIG_FILE
	export HOME="$TESTDIR"

	ROOT="$TESTDIR/oe"
	SHORT="$TESTDIR/short"
	# setup creates SHORT -> ROOT and derive_paths adopts it, so every base-path
	# runs through the short link. The checkout kas is cd'd into is under it.
	PROJECT="$SHORT/work/meta-ai"
	export ROOT SHORT PROJECT

	# Where the recorder kas-container logs $PWD + argv + env, one block per call.
	KREC="$TESTDIR/kas.rec"
	export KREC
	: > "$KREC"

	# The pinned sum mackas checks the download against.
	PINNED_SHA="$(grep '^KAS_CONTAINER_SHA256=' "$MACKAS" | cut -d'"' -f2)"

	# A real local fixture repo, cloned by real git during setup_project.
	FIXTURE="$TESTDIR/fixture.git"
	mkdir -p "$FIXTURE"
	(
		cd "$FIXTURE"
		git init -q -b testbranch
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
		mkdir kas
		echo "# base layer stub" > kas/base.yml
		git add -A
		git -c user.email=t@t -c user.name=t commit -q -m base
	)

	mkdir -p "$TESTDIR/fakebin"

	# Fake container: runtime up, everything else a recorded no-op, nothing
	# running. Never touches a real engine even on a host that has one.
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

	# Fake curl: write a recorder kas-container to the -o path. It appends its
	# $PWD, argv and full environment to $KREC on each call.
	cat > "$TESTDIR/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$out" ] || exit 1
cat > "$out" <<'REC'
#!/usr/bin/env bash
{
	printf 'PWD=%s\n' "$PWD"
	printf 'ARGV_BEGIN\n'
	for a in "$@"; do printf 'ARG:%s\n' "$a"; done
	printf 'ARGV_END\n'
	printf 'ENV_BEGIN\n'
	env
	printf 'ENV_END\n'
} >> "$KREC"
exit 0
REC
EOF
	chmod +x "$TESTDIR/fakebin/curl"

	# Fake shasum: always report the pinned sum, so the sha256 gate passes over
	# the stub the fake curl wrote (its real content is not the upstream tool).
	cat > "$TESTDIR/fakebin/shasum" <<EOF
#!/usr/bin/env bash
f="\${@: -1}"
printf '%s  %s\n' "$PINNED_SHA" "\$f"
EOF
	chmod +x "$TESTDIR/fakebin/shasum"

	PATH="$TESTDIR/fakebin:$PATH"
	export PATH
}

teardown() {
	cd /
	rm -rf "$TESTDIR"
}

# Common knobs for both setup and smoketest: pinned cpu/mem (so runtime-args is an
# exact string), overhead off, relocation off, the fixture as the project, and
# a single-file kas config so the composed files arg is exact and space-free.
mk() {
	run "$MACKAS" -y \
		--set "MACKAS_ROOT=$ROOT" \
		--set "MACKAS_SHORT_LINK=$SHORT" \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_CPUS=6 \
		--set MACKAS_MEMORY=12g \
		--set "MACKAS_PROJECT_URL=$FIXTURE" \
		--set MACKAS_PROJECT_BRANCH=testbranch \
		--set MACKAS_PROJECT_DIR=meta-ai \
		--set MACKAS_KAS_CONFIG=kas/base.yml \
		"$@"
}

# The whole environment of the first recorded kas call (identical across calls;
# _kas_exec sets it once).
kas_env() {
	awk '/^ENV_BEGIN/{e=1;next} /^ENV_END/{exit} e' "$KREC"
}

# The exact composed runtime-args string (the value token after --runtime-args).
EXPECT_RT="-c 6 -m 12g -v oe-build-tmp:/build -e KAS_BUILD_DIR=/build -v oe-build-dl:/downloads -e DL_DIR=/downloads -v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate"
# The exact composed kas files argument.
EXPECT_FILES="kas/base.yml:kas/macos-local.yml"

@test "e2e: setup then smoketest deliver the whole chain to kas intact, together" {
	mk setup
	[ "$status" -eq 0 ]

	# Reset the recorder: setup ran kas-container --version once, which we do not
	# want to confuse with the smoketest rung calls.
	: > "$KREC"

	mk --set "MACKAS_SMOKETEST_TARGETS=alpha beta" smoketest
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'Smoketest ladder passed'

	# --- 1. cwd is the checkout kas-container mounts as /repo -------------------
	local first_pwd
	first_pwd="$(sed -n 's/^PWD=//p' "$KREC" | head -1)"
	[ "$first_pwd" = "$PROJECT" ]

	# --- 2. the composed kas files argument reaches kas verbatim ----------------
	grep -qxF "ARG:$EXPECT_FILES" "$KREC"

	# --- 3. the --runtime-args value is the EXACT composed string ---------------
	# The three -v/-e volume pairs and the -c/-m limits, in order, as ONE token
	# (kas word-splits it, so a stray space would be a different bug).
	local rt
	rt="$(awk '/^ARG:--runtime-args$/{getline; sub(/^ARG:/,""); print; exit}' "$KREC")"
	[ "$rt" = "$EXPECT_RT" ]

	# --- 4. KAS_BUILD_DIR/DL_DIR/SSTATE_DIR are EMPTY in the kas environment -------
	# Present but blank: forward_dir() returns early on empty, so kas never
	# bind-mounts a host path over the ext4 volumes. (Bug 1.)
	kas_env | grep -qxF 'KAS_BUILD_DIR='
	kas_env | grep -qxF 'DL_DIR='
	kas_env | grep -qxF 'SSTATE_DIR='

	# --- 5. KAS_EXTRA_RUNTIME_ARGS is UNSET in the kas environment -----------------
	# kas blanks it before parsing, so exporting it would silently drop the
	# limits. It must not be in the environment at all. (Bug 2.)
	! kas_env | grep -q '^KAS_EXTRA_RUNTIME_ARGS='

	# --- 6. GITCONFIG_FILE points at a real file carrying safe.directory --------
	# The dubious-ownership blocker: without this file forwarded, git inside the
	# container refuses /repo and BBLAYERS mis-resolves.
	local gc
	gc="$(kas_env | sed -n 's/^GITCONFIG_FILE=//p' | head -1)"
	[ -n "$gc" ]
	[ -f "$gc" ]
	grep -qxF '[safe]' "$gc"
	grep -qE '^[[:space:]]*directory[[:space:]]*=[[:space:]]*\*[[:space:]]*$' "$gc"
}

@test "e2e: the kas fragment lands physically inside the checkout, bytes intact" {
	mk setup
	[ "$status" -eq 0 ]

	# It must be at kas/macos-local.yml UNDER the checkout: kas-container only
	# mounts files below the repo dir, and KAS_FILES_ARG names it by that path.
	local frag="$PROJECT/kas/macos-local.yml"
	[ -f "$frag" ]

	# The multi-line BB_DISKMON_DIRS continuation must survive generation AND the
	# copy into the checkout, byte for byte -- the shipped bug collapsed it onto
	# one line. Assert each physical line EXACTLY, which a collapsed line cannot
	# satisfy no matter how the substrings are rearranged.
	grep -qxF '    BB_DISKMON_DIRS ??= "\' "$frag"
	grep -qxF '      HALT,${TMPDIR},2G,100K \' "$frag"
	grep -qxF '      HALT,${DL_DIR},2G,100K \' "$frag"
	grep -qxF '      HALT,${SSTATE_DIR},2G,100K"' "$frag"
	# And it is genuinely NOT squeezed onto one line.
	! grep -qF 'BB_DISKMON_DIRS ??= "        HALT,' "$frag"

	# The fragment path was excluded from the checkout exactly once.
	[ "$(grep -c '^kas/macos-local.yml$' "$PROJECT/.git/info/exclude")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Global flags after the subcommand word (cmd_setup used to be one of the two
# tail-parsers -- alongside cmd_adopt -- that hit a bare "unknown option" die
# for these; every other tail-capturing command already accepted them here).
# ---------------------------------------------------------------------------

@test "setup accepts --dry-run after the subcommand word" {
	mk setup "$ROOT" --dry-run
	[ "$status" -eq 0 ]
	[ ! -e "$ROOT" ]
}
