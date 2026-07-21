#!/usr/bin/env bats
#
# Tests for `mackas adopt <path>` -- bringing a foreign MACKAS_ROOT (another
# Mac's mackas set it up) back to a working build on THIS Mac.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hermetic seams, the same ones setup_e2e.bats already established: a fake
# `container` on PATH (system up, everything else a recorded no-op, nothing
# running); a fake `curl` that writes a recorder kas-container to the
# download path; a fake `shasum` that reports the pinned sum so the sha256
# gate passes; a real local `git init` fixture repo, cloned by real git.
# Nothing here touches the real Apple container runtime, the network, or the
# build SSD.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	unset MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL MACKAS_OVERHEAD_BIN MACKAS_FSTRIM_AUTO
	export HOME="$TESTDIR"

	FOREIGN="$TESTDIR/foreign-oe"
	PINNED_SHA="$(grep '^KAS_CONTAINER_SHA256=' "$MACKAS" | cut -d'"' -f2)"

	# A real local fixture repo, cloned by real git as the adopted project.
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

	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1" in --version) echo "container CLI 0.0-fake"; exit 0 ;; esac
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"image ls")      echo "NAME TAG"; exit 0 ;;
	"volume ls")
		echo "NAME"
		for v in ${MOCK_EXISTING_VOLUMES:-}; do echo "$v"; done
		exit 0
		;;
	"container ls"|"ls "*|"ls") echo "ID"; exit 0 ;;
esac
exit 0
EOF
	chmod +x "$TESTDIR/fakebin/container"

	cat > "$TESTDIR/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$out" ] || exit 1
cat > "$out" <<'REC'
#!/usr/bin/env bash
exit 0
REC
EOF
	chmod +x "$TESTDIR/fakebin/curl"

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

# A foreign root with exactly one checkout under work/, cloned for real from
# the local fixture -- a genuine .git, no fake.
make_foreign_root_with_project() {
	mkdir -p "$FOREIGN/work" "$FOREIGN/bin"
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-ai"
}

mk() {
	run "$MACKAS" -y \
		--set MACKAS_RELOCATE_VOLUMES=0 \
		--set MACKAS_OVERHEAD=0 \
		--set MACKAS_CPUS=6 \
		--set MACKAS_MEMORY=12g \
		"$@"
}

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

@test "adopt: refuses a path that does not look like a mackas root" {
	mkdir -p "$TESTDIR/just-a-dir"
	mk adopt "$TESTDIR/just-a-dir"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'does not look like a mackas root'
}

@test "adopt: refuses a path that is already this Mac's own MACKAS_ROOT" {
	make_foreign_root_with_project
	mk --set "MACKAS_ROOT=$FOREIGN" adopt "$FOREIGN"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'already this Mac'\''s own MACKAS_ROOT'
}

@test "adopt: refuses a nonexistent path" {
	mk adopt "$TESTDIR/does-not-exist"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a directory'
}

@test "adopt: with no path at all, refuses with a clear usage error" {
	mk adopt
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a path'
}

# ---------------------------------------------------------------------------
# Project introspection
# ---------------------------------------------------------------------------

@test "adopt: introspects the single checkout's remote URL and branch" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "project    : meta-ai"
	printf '%s\n' "$output" | grep -qF "url      : $FIXTURE"
	printf '%s\n' "$output" | grep -qF "branch   : testbranch"
	grep -qxF "MACKAS_PROJECT_URL='$FIXTURE'" "$TESTDIR/newconfig.conf"
	grep -qxF "MACKAS_PROJECT_BRANCH='testbranch'" "$TESTDIR/newconfig.conf"
	grep -qxF "MACKAS_PROJECT_DIR='meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: zero checkouts under work/ adopts infra only, no project" {
	mkdir -p "$FOREIGN/work" "$FOREIGN/bin"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'adopting infra only'
	! grep -q "MACKAS_PROJECT_URL" "$TESTDIR/newconfig.conf"
	printf '%s\n' "$output" | grep -qi 'no project configured'
}

@test "adopt: more than one checkout requires --project-dir" {
	make_foreign_root_with_project
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-second"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs to know which one'
	printf '%s\n' "$output" | grep -qF 'meta-ai'
	printf '%s\n' "$output" | grep -qF 'meta-second'
}

@test "adopt: --project-dir picks one of several checkouts explicitly" {
	make_foreign_root_with_project
	git clone -q -b testbranch "$FIXTURE" "$FOREIGN/work/meta-second"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf" --project-dir meta-second
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_PROJECT_DIR='meta-second'" "$TESTDIR/newconfig.conf"
}

@test "adopt: --project-dir naming a nonexistent checkout is refused" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf" --project-dir nope
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'no git checkout at'
}

# ---------------------------------------------------------------------------
# Distinct identity: volume name and short link never collide
# ---------------------------------------------------------------------------

@test "adopt: derives a distinct MACKAS_VOLUME_NAME from the project name" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='mackas-meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: disambiguates the volume name when one already exists for something else" {
	make_foreign_root_with_project
	MOCK_EXISTING_VOLUMES="mackas-meta-ai-tmp mackas-meta-ai-dl mackas-meta-ai-sstate" \
		mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_VOLUME_NAME='mackas-meta-ai-2'" "$TESTDIR/newconfig.conf"
}

@test "adopt: derives a distinct MACKAS_SHORT_LINK from the project name" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai'" "$TESTDIR/newconfig.conf"
}

@test "adopt: disambiguates the short link when one already exists for something else" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/some-other-root"
	ln -s "$TESTDIR/some-other-root" "$HOME/oe-meta-ai"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai-2'" "$TESTDIR/newconfig.conf"
}

@test "adopt: re-adopting the same root reuses its existing short link, no new suffix" {
	make_foreign_root_with_project
	ln -s "$FOREIGN" "$HOME/oe-meta-ai"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	grep -qxF "MACKAS_SHORT_LINK='$HOME/oe-meta-ai'" "$TESTDIR/newconfig.conf"
}

# ---------------------------------------------------------------------------
# Config file handling
# ---------------------------------------------------------------------------

@test "adopt: defaults the config file under ~/.config/mackas/projects/" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN"
	[ "$status" -eq 0 ]
	[ -f "$HOME/.config/mackas/projects/meta-ai.conf" ]
}

@test "adopt: an existing config file at the target requires confirmation" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/existing"
	echo "MACKAS_ROOT='/somewhere/else'" > "$TESTDIR/existing/c.conf"
	run "$MACKAS" --set MACKAS_RELOCATE_VOLUMES=0 \
		adopt "$FOREIGN" --write-config "$TESTDIR/existing/c.conf" <<< "n"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'declined'
	grep -qxF "MACKAS_ROOT='/somewhere/else'" "$TESTDIR/existing/c.conf"
}

@test "adopt: accepting the overwrite confirmation replaces the existing config" {
	make_foreign_root_with_project
	mkdir -p "$TESTDIR/existing"
	echo "MACKAS_ROOT='/somewhere/else'" > "$TESTDIR/existing/c.conf"
	mk adopt "$FOREIGN" --write-config "$TESTDIR/existing/c.conf"
	[ "$status" -eq 0 ]
	# Compared resolved: on macOS /var/folders/... is itself a symlink to
	# /private/var/folders/..., and adopt correctly stores the canonical form.
	grep -qxF "MACKAS_ROOT='$(cd "$FOREIGN" && pwd -P)'" "$TESTDIR/existing/c.conf"
}

# ---------------------------------------------------------------------------
# Hands off to setup
# ---------------------------------------------------------------------------

@test "adopt: hands off to setup, which completes for real" {
	make_foreign_root_with_project
	mk adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'mackas setup'
	printf '%s\n' "$output" | grep -qi '^Done$'
	[ -f "$FOREIGN/env.sh" ]
	[ -f "$FOREIGN/gitconfig" ]
	[ -f "$FOREIGN/work/meta-ai/kas/macos-local.yml" ]
	printf '%s\n' "$output" | grep -qF "Adopted"
	printf '%s\n' "$output" | grep -qF "$TESTDIR/newconfig.conf"
}

# ---------------------------------------------------------------------------
# --dry-run mutates nothing
# ---------------------------------------------------------------------------

@test "adopt --dry-run writes no config file and mutates nothing" {
	make_foreign_root_with_project
	mk --dry-run adopt "$FOREIGN" --write-config "$TESTDIR/newconfig.conf"
	[ "$status" -eq 0 ]
	[ ! -f "$TESTDIR/newconfig.conf" ]
	[ ! -f "$FOREIGN/env.sh" ]
	[ ! -L "$HOME/oe-meta-ai" ]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "adopt --help prints usage and does nothing" {
	mk adopt --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'bring a foreign MACKAS_ROOT'
	[ ! -d "$HOME/.config/mackas" ]
}
