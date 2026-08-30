#!/usr/bin/env bats
#
# Tests for the project selector: `--project NAME` / $MACKAS_PROJECT_SELECT,
# which choose WHICH config file load_config sources, and `mackas projects`,
# which lists the pinned ones without sourcing any of them.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The selector derives a path from a bare name, in a fixed and entirely
# guessable place -- so unlike --config, it is held to config_file_is_safe().
# Most of what follows is about that, and about the name never escaping the
# directory it is supposed to name a file in.

bats_require_minimum_version 1.5.0

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	# An empty cwd, so no stray ./mackas.conf can leak in, and a throwaway
	# HOME, so neither the real ~/.mackas.conf nor the real pinned projects
	# can either.
	cd "$TESTDIR"
	unset MACKAS_CONF MACKAS_PROJECT_SELECT MACKAS_KAS_CONFIG MACKAS_MEMORY
	unset MACKAS_ROOT MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR
	export HOME="$TESTDIR/home"
	PROJDIR="$HOME/.config/mackas/projects"
	mkdir -p "$PROJDIR"

	# Same reason config.bats fakes it: `status` asks the daemon for a
	# volume's live cap, and a dev Mac with real oe-build-* volumes would
	# answer with real state in tests that are about config resolution.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"system status") echo "status running"; exit 0 ;;
	"volume ls") echo "NAME TYPE DRIVER OPTIONS"; exit 0 ;;
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

# Read one setting out of `mackas status` output.
setting() {
	printf '%s\n' "$output" | awk -v k="$1" '$1 == k { $1=""; sub(/^ +/,""); print; exit }'
}

# Write a pinned project config named $1 from stdin.
pin() {
	cat > "$PROJDIR/$1.conf"
	chmod 600 "$PROJDIR/$1.conf"
}

# ---------------------------------------------------------------------------
# The happy path: a name selects a file
# ---------------------------------------------------------------------------

@test "--project NAME sources ~/.config/mackas/projects/NAME.conf" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	run "$MACKAS" --project meta-ai status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-meta-ai.yml" ]
	printf '%s\n' "$output" | grep -qF "$PROJDIR/meta-ai.conf"
}

@test "--project=NAME, the combined form, works too" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	run "$MACKAS" --project=meta-ai status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-meta-ai.yml" ]
}

@test "\$MACKAS_PROJECT_SELECT selects the same way" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/from-meta-ai.yml" ]
}

@test "--project beats \$MACKAS_PROJECT_SELECT" {
	pin from-env <<-'EOF'
	MACKAS_KAS_CONFIG="kas/env.yml"
	EOF
	pin from-flag <<-'EOF'
	MACKAS_KAS_CONFIG="kas/flag.yml"
	EOF
	MACKAS_PROJECT_SELECT=from-env run "$MACKAS" --project from-flag status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/flag.yml" ]
}

@test "status names the selected project, and only when one was selected" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="kas/from-meta-ai.yml"
	EOF
	run "$MACKAS" --project meta-ai status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  project selected +meta-ai$'

	run "$MACKAS" status
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'project selected'
}

@test "the selector adds no precedence rung: env still beats the file, --set beats env" {
	pin meta-ai <<-'EOF'
	MACKAS_MEMORY="8g"
	EOF
	run "$MACKAS" --project meta-ai status
	[ "$(setting MACKAS_MEMORY)" = "8g" ]

	MACKAS_MEMORY=16g run "$MACKAS" --project meta-ai status
	[ "$(setting MACKAS_MEMORY)" = "16g" ]

	MACKAS_MEMORY=16g run "$MACKAS" --project meta-ai --set MACKAS_MEMORY=32g status
	[ "$(setting MACKAS_MEMORY)" = "32g" ]
}

@test "a project that was never pinned dies with guidance, naming the path" {
	run "$MACKAS" --project nope status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "$PROJDIR/nope.conf"
	printf '%s\n' "$output" | grep -q 'next:'
	printf '%s\n' "$output" | grep -q 'projects'
}

@test "--project with no NAME after it is an error" {
	run "$MACKAS" --project
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a name'
}

# ---------------------------------------------------------------------------
# The safety surface: a DERIVED path is held to config_file_is_safe()
#
# Each of these plants a `touch` in the config, so "was it refused" is proven
# by the sentinel not existing rather than only by an exit status.
# ---------------------------------------------------------------------------

@test "the control: a 0600 project config in a 0755 dir IS sourced" {
	# Without this, every refusal test below could be passing for the wrong
	# reason (a broken path, a typo in the fixture).
	pin ok <<-EOF
	touch "$TESTDIR/RAN"
	MACKAS_KAS_CONFIG="from-project"
	EOF
	chmod 755 "$PROJDIR"
	run "$MACKAS" --project ok status
	[ "$status" -eq 0 ]
	[ -e "$TESTDIR/RAN" ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-project" ]
}

@test "a group-writable project config is refused, exactly like a searched one" {
	pin pwned <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod g+w "$PROJDIR/pwned.conf"
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
	printf '%s\n' "$output" | grep -q 'chmod go-w'
}

@test "a world-writable project config is refused" {
	pin pwned <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod o+w "$PROJDIR/pwned.conf"
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
}

@test "a project config in a group-writable directory is refused" {
	# The file is 0600 and ours. Being able to REPLACE it is as good as being
	# able to edit it, and ~/.config/mackas/projects/ is a fixed, guessable
	# path -- which is the whole reason the derived selector is checked and
	# a typed --config is not.
	pin pwned <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod g+w "$PROJDIR"
	run "$MACKAS" --project pwned status
	chmod g-w "$PROJDIR"
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
}

@test "an unsafe project config is refused, NOT silently replaced by the search path" {
	# Falling through would load a DIFFERENT project's settings than the one
	# asked for -- worse than stopping, because it looks like it worked.
	pin pwned <<-'EOF'
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod g+w "$PROJDIR/pwned.conf"
	echo 'MACKAS_KAS_CONFIG="from-home"' > "$HOME/.mackas.conf"
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	! printf '%s\n' "$output" | grep -q 'from-home'
}

# ---------------------------------------------------------------------------
# ...and graded on what is really there, never on a symlink standing in for it
#
# `ln -s` applies the umask, so a link's own mode is only ever a record of
# that umask -- measured on macOS: 022 -> 755, 002 -> 775, 000 -> 777,
# 077 -> 700. 755 is squarely inside what path_is_owned_and_unwritable_by_others
# accepts, so grading the LINK accepts anything it points at. Each of these
# builds the link under an explicit `umask 022`, so the fixture pins that
# measured 755 rather than inheriting whatever umask ran the suite.
# ---------------------------------------------------------------------------

@test "a projects directory that is a symlink is graded by the real directory" {
	# The demonstrated hole: with the link graded instead of its target, a
	# config sitting in a 0777 directory anyone can write gets sourced.
	rmdir "$PROJDIR"
	mkdir -p "$TESTDIR/shared"
	chmod 777 "$TESTDIR/shared"
	( umask 022 && ln -s "$TESTDIR/shared" "$PROJDIR" )
	[ "$(stat -f '%Lp' "$PROJDIR")" = "755" ]   # the link itself: the umask, nothing more
	cat > "$TESTDIR/shared/pwned.conf" <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod 600 "$TESTDIR/shared/pwned.conf"
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
}

@test "a project config that is a symlink is graded by the file it points at" {
	# The same blindness on the file side: the link is ours and 0755, the
	# file it names is world-writable.
	cat > "$TESTDIR/real.conf" <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod 666 "$TESTDIR/real.conf"
	( umask 022 && ln -s "$TESTDIR/real.conf" "$PROJDIR/pwned.conf" )
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	printf '%s\n' "$output" | grep -qi 'refusing to source'
}

@test "a project config symlinked into a world-writable directory is refused" {
	# Link and target are both 0600 and ours; the DIRECTORY the target sits
	# in is the hole, and it is only reachable by resolving the link.
	mkdir -p "$TESTDIR/shared"
	chmod 777 "$TESTDIR/shared"
	cat > "$TESTDIR/shared/real.conf" <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="from-unsafe"
	EOF
	chmod 600 "$TESTDIR/shared/real.conf"
	( umask 022 && ln -s "$TESTDIR/shared/real.conf" "$PROJDIR/pwned.conf" )
	run "$MACKAS" --project pwned status
	[ "$status" -ne 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
}

@test "a project config kept as a symlink to a safe file IS still sourced" {
	# The other side of the check: a dotfiles-style link into a directory
	# that passes on its own merits must keep working, or the fix above is
	# just a refusal of every symlink.
	mkdir -p "$TESTDIR/dotfiles"
	chmod 755 "$TESTDIR/dotfiles"
	cat > "$TESTDIR/dotfiles/real.conf" <<-EOF
	touch "$TESTDIR/RAN"
	MACKAS_KAS_CONFIG="from-dotfiles"
	EOF
	chmod 600 "$TESTDIR/dotfiles/real.conf"
	( umask 022 && ln -s "$TESTDIR/dotfiles/real.conf" "$PROJDIR/ok.conf" )
	run "$MACKAS" --project ok status
	[ "$status" -eq 0 ]
	[ -e "$TESTDIR/RAN" ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-dotfiles" ]
}

@test "'projects' reports a config in a symlinked unsafe directory as unsafe" {
	# The third caller of config_file_is_safe: it never sources, but it
	# reports the same verdict, so it must not be fooled either.
	rmdir "$PROJDIR"
	mkdir -p "$TESTDIR/shared"
	chmod 777 "$TESTDIR/shared"
	( umask 022 && ln -s "$TESTDIR/shared" "$PROJDIR" )
	echo 'MACKAS_KAS_CONFIG="from-unsafe"' > "$TESTDIR/shared/p.conf"
	chmod 600 "$TESTDIR/shared/p.conf"
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'unsafe'
}

@test "a DIRECTORY at NAME.conf is refused before it reaches the shell" {
	# Readable, ours, 0755 -- so it passes the safety grade untouched and
	# used to land on `. "$f"` as a raw, localized "is a directory" error.
	mkdir -p "$PROJDIR/p.conf"
	run "$MACKAS" --project p status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a regular file'
}

@test "--config is still exempt from the check the selector enforces" {
	# The asymmetry is the design, not an oversight: a typed path is a
	# request, a derived one is an ambush surface.
	echo 'MACKAS_KAS_CONFIG="explicit"' > "$TESTDIR/c.conf"
	chmod g+w "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "explicit" ]
}

# ---------------------------------------------------------------------------
# The name is validated before it is ever turned into a path
# ---------------------------------------------------------------------------

@test "--project ../../etc/passwd is refused, and never reaches the file it aims at" {
	# Plant a real, readable, perfectly safe config at exactly the path the
	# UNVALIDATED name would resolve to -- <projects_dir>/../../etc/passwd.conf,
	# which lands in $HOME/.config/etc/ here. Only the name check keeps it from
	# being sourced, so this cannot pass merely because the file is missing.
	mkdir -p "$HOME/.config/etc"
	echo 'MACKAS_KAS_CONFIG="traversed"' > "$HOME/.config/etc/passwd.conf"
	chmod 600 "$HOME/.config/etc/passwd.conf"
	[ -r "$PROJDIR/../../etc/passwd.conf" ]
	run "$MACKAS" --project ../../etc/passwd status
	[ "$status" -ne 0 ]
	! printf '%s\n' "$output" | grep -q 'traversed'
}

@test "--project . is refused" {
	# Would be <projects_dir>/..conf -- a legal filename, so nothing but the
	# name check stops it.
	printf 'MACKAS_KAS_CONFIG="dotdot"\n' > "$PROJDIR/..conf"
	chmod 600 "$PROJDIR/..conf"
	run "$MACKAS" --project . status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "cannot be '.' or contain"
	! printf '%s\n' "$output" | grep -q 'dotdot'
}

@test "--project -x is refused rather than read as a flag" {
	run "$MACKAS" --project -x status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi "cannot start with '-'"
}

@test "a project name outside the allowed character class is refused" {
	# Each name gets a real, safe, readable config planted at the exact path
	# it would resolve to, so a refusal here is the name check doing its job
	# and never just a missing file.
	local n
	mkdir -p "$PROJDIR/a"
	for n in 'a b' 'a/b' 'a$(id)' 'a;b' 'a\b' 'a*'; do
		echo 'MACKAS_KAS_CONFIG="class-escaped"' > "$PROJDIR/$n.conf"
		chmod 600 "$PROJDIR/$n.conf"
		[ -r "$PROJDIR/$n.conf" ]
		run "$MACKAS" --project "$n" status
		if [ "$status" -eq 0 ]; then
			echo "accepted a bad project name: $n" >&2
			return 1
		fi
		if printf '%s\n' "$output" | grep -q 'class-escaped'; then
			echo "sourced the file a bad project name pointed at: $n" >&2
			return 1
		fi
	done
}

@test "the ordinary names adopt produces are accepted" {
	# The refusals above must not take the legitimate case with them: adopt
	# tr's a checkout name down to [A-Za-z0-9-], and '.'/'_' are allowed too.
	local n
	for n in meta-ai meta_ai qcom.6.12 a; do
		pin "$n" <<-EOF
		MACKAS_KAS_CONFIG="ok-$n"
		EOF
		run "$MACKAS" --project "$n" status
		[ "$status" -eq 0 ]
		[ "$(setting MACKAS_KAS_CONFIG)" = "ok-$n" ]
	done
}

# ---------------------------------------------------------------------------
# Mutual exclusion with the path-naming knobs
# ---------------------------------------------------------------------------

@test "--project together with --config is refused, naming both" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-project"
	EOF
	echo 'MACKAS_KAS_CONFIG="from-config"' > "$TESTDIR/c.conf"
	run "$MACKAS" --project meta-ai --config "$TESTDIR/c.conf" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q -- '--project'
	printf '%s\n' "$output" | grep -q -- '--config'
	printf '%s\n' "$output" | grep -qF 'meta-ai'
	printf '%s\n' "$output" | grep -qF "$TESTDIR/c.conf"
	# Neither may have been applied on the way to the refusal.
	! printf '%s\n' "$output" | grep -qE 'from-(project|config)'
}

@test "--project together with \$MACKAS_CONF is refused, naming both" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-project"
	EOF
	echo 'MACKAS_KAS_CONFIG="from-env-conf"' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" run "$MACKAS" --project meta-ai status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q -- '--project'
	printf '%s\n' "$output" | grep -q 'MACKAS_CONF'
}

@test "\$MACKAS_PROJECT_SELECT together with \$MACKAS_CONF is refused" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-project"
	EOF
	echo 'MACKAS_KAS_CONFIG="from-env-conf"' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q 'MACKAS_PROJECT_SELECT'
}

@test "--project after the command word is redirected, not silently dropped" {
	run "$MACKAS" get MACKAS_MEMORY --project meta-ai
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'must come BEFORE'

	# runtime-args is the one tail-capturing command the selector sweep
	# missed: it redirected --config/--set and left --project to fall
	# through to a generic "unknown option".
	run "$MACKAS" runtime-args --project meta-ai
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'must come BEFORE'

	run "$MACKAS" runtime-args --project=meta-ai
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'must come BEFORE'
}

# ---------------------------------------------------------------------------
# help still sources nothing
# ---------------------------------------------------------------------------

@test "help with --project sources nothing" {
	pin meta-ai <<-EOF
	touch "$TESTDIR/PROJECT_CONF_RAN"
	EOF
	run "$MACKAS" --project meta-ai help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/PROJECT_CONF_RAN" ]
	printf '%s\n' "$output" | grep -q 'USAGE'
}

@test "-h with \$MACKAS_PROJECT_SELECT sources nothing either" {
	pin meta-ai <<-EOF
	touch "$TESTDIR/PROJECT_CONF_RAN"
	EOF
	MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" -h
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/PROJECT_CONF_RAN" ]
}

@test "help documents --project" {
	run "$MACKAS" help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q -- '--project NAME'
	printf '%s\n' "$output" | grep -q 'MACKAS_PROJECT_SELECT'
}

# ---------------------------------------------------------------------------
# The selector is not a setting
# ---------------------------------------------------------------------------

@test "MACKAS_PROJECT_SELECT is not a setting: set/get/unset all refuse it" {
	run "$MACKAS" set MACKAS_PROJECT_SELECT meta-ai
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a mackas setting'

	run "$MACKAS" get MACKAS_PROJECT_SELECT
	[ "$status" -ne 0 ]

	run "$MACKAS" unset MACKAS_PROJECT_SELECT
	[ "$status" -ne 0 ]
}

@test "MACKAS_PROJECT_SELECT is not listed among the resolved settings" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-project"
	EOF
	run "$MACKAS" --project meta-ai status
	[ "$status" -eq 0 ]
	[ -z "$(setting MACKAS_PROJECT_SELECT)" ]
}

@test "a project config setting MACKAS_PROJECT_SELECT does not re-select anything" {
	# A selector written into the file it selects is circular; it must be
	# inert data there, not a second lookup.
	pin meta-ai <<-'EOF'
	MACKAS_PROJECT_SELECT="other"
	MACKAS_KAS_CONFIG="from-meta-ai"
	EOF
	pin other <<-'EOF'
	MACKAS_KAS_CONFIG="from-other"
	EOF
	run "$MACKAS" --project meta-ai status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-meta-ai" ]
}

# ---------------------------------------------------------------------------
# set / get / unset against a selected project
# ---------------------------------------------------------------------------

@test "set --project bootstraps a project config that does not exist yet" {
	rm -rf "$HOME/.config"
	run "$MACKAS" --project brand-new set MACKAS_MEMORY 48g
	[ "$status" -eq 0 ]
	[ -f "$PROJDIR/brand-new.conf" ]
	grep -qF "MACKAS_MEMORY='48g'" "$PROJDIR/brand-new.conf"
}

@test "get --project reads back through the selected file" {
	pin meta-ai <<-'EOF'
	MACKAS_MEMORY="8g"
	EOF
	run "$MACKAS" --project meta-ai get MACKAS_MEMORY
	[ "$status" -eq 0 ]
	[ "$output" = "8g" ]
}

@test "unset --project removes the line from the selected file" {
	pin meta-ai <<-'EOF'
	MACKAS_MEMORY="8g"
	MACKAS_KAS_CONFIG="keep-me"
	EOF
	run "$MACKAS" --project meta-ai unset MACKAS_MEMORY
	[ "$status" -eq 0 ]
	assert_fails grep -q '^MACKAS_MEMORY=' "$PROJDIR/meta-ai.conf"
	grep -q 'keep-me' "$PROJDIR/meta-ai.conf"
}

@test "set --project on an UNSAFE existing project config is refused, nothing written" {
	pin meta-ai <<-'EOF'
	MACKAS_MEMORY="8g"
	EOF
	chmod g+w "$PROJDIR/meta-ai.conf"
	run "$MACKAS" --project meta-ai set MACKAS_MEMORY 48g
	[ "$status" -ne 0 ]
	grep -qF 'MACKAS_MEMORY="8g"' "$PROJDIR/meta-ai.conf"
}

# ---------------------------------------------------------------------------
# `mackas projects` -- greps, never sources
# ---------------------------------------------------------------------------

@test "projects does NOT execute what is in a listed config" {
	# The whole point of the command: it reads a directory of files that are
	# each SHELL. Sourcing them to list them would be the search-path RCE
	# rebuilt, with a directory of candidates instead of one.
	pin evil <<-EOF
	MACKAS_ROOT="\$(touch "$TESTDIR/SENTINEL")"
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/SENTINEL" ]
	printf '%s\n' "$output" | grep -q 'evil'
}

@test "projects does not execute a bare command line in a listed config either" {
	pin evil <<-EOF
	touch "$TESTDIR/SENTINEL"
	MACKAS_ROOT="/tmp"
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/SENTINEL" ]
}

@test "projects does not execute an UNSAFE listed config, and says it is unsafe" {
	pin evil <<-EOF
	touch "$TESTDIR/SENTINEL"
	MACKAS_ROOT="/tmp"
	EOF
	chmod g+w "$PROJDIR/evil.conf"
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/SENTINEL" ]
	printf '%s\n' "$output" | grep -qi 'unsafe'
}

@test "projects lists each pinned config with the settings that locate it" {
	pin meta-ai <<-'EOF'
	MACKAS_ROOT='/tmp'
	MACKAS_PROJECT_DIR='meta-ai'
	MACKAS_VOLUME_NAME='mackas-meta-ai'
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'meta-ai'
	printf '%s\n' "$output" | grep -qE 'MACKAS_VOLUME_NAME +mackas-meta-ai'
	# shq()'s single quotes are stripped, not printed back out.
	! printf '%s\n' "$output" | grep -q "'mackas-meta-ai'"
}

@test "projects marks the one this invocation selected" {
	pin meta-ai <<-'EOF'
	MACKAS_ROOT='/tmp'
	EOF
	pin other <<-'EOF'
	MACKAS_ROOT='/tmp'
	EOF
	run "$MACKAS" --project meta-ai projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  .*meta-ai.*selected'
	! printf '%s\n' "$output" | grep -qE '^  .*other.*selected'
}

@test "projects flags a pin whose MACKAS_ROOT is gone" {
	pin meta-ai <<-EOF
	MACKAS_ROOT='$TESTDIR/vanished'
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'stale'
}

@test "projects with nothing pinned says so instead of printing nothing" {
	rm -rf "$HOME/.config"
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qi 'none pinned yet'
}

@test "projects --help explains itself and mentions the grep-not-source rule" {
	run "$MACKAS" projects --help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'USAGE'
	printf '%s\n' "$output" | grep -qi 'grepping'
}

# ---------------------------------------------------------------------------
# Bootstrapping the projects directory must not defeat the selector's own
# safety check
# ---------------------------------------------------------------------------

@test "set --project creates the projects directory unwritable by group, whatever the umask" {
	# `umask 002` is a real login configuration, not a hypothetical one -- it
	# is the case config_file_is_safe's own comment names. Inheriting it here
	# would make ~/.config/mackas/projects group-writable, and --project would
	# then refuse the very file this bootstrap just wrote.
	rm -rf "$HOME/.config"
	( umask 002; "$MACKAS" --project fresh set MACKAS_VOLUME_NAME lax-umask )
	[ -f "$PROJDIR/fresh.conf" ]

	local mode
	for d in "$HOME/.config" "$HOME/.config/mackas" "$PROJDIR"; do
		mode="$(stat -f '%Lp' "$d")"
		case "${mode%?}" in *[2367]) echo "group-writable: $d ($mode)" >&2; return 1 ;; esac
		case "${mode#??}" in [2367]) echo "other-writable: $d ($mode)" >&2; return 1 ;; esac
	done

	# The check that actually matters: the file is readable back through the
	# selector, rather than refused as unsafe.
	run "$MACKAS" --project fresh get MACKAS_VOLUME_NAME
	[ "$status" -eq 0 ]
	[ "$output" = "lax-umask" ]
}

# ---------------------------------------------------------------------------
# config_grep_setting's assignment shapes, read back through `projects` (the
# only caller). MACKAS_VOLUME_* rather than MACKAS_ROOT, so nothing here also
# trips the "its MACKAS_ROOT does not exist" note.
# ---------------------------------------------------------------------------

@test "projects: reads an 'export NAME=' assignment, and drops a trailing comment from a bare value" {
	pin shapes <<-'EOF'
	export MACKAS_VOLUME_NAME=exported-bare # and a trailing comment
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^ +MACKAS_VOLUME_NAME +exported-bare$'
}

@test "projects: the LAST assignment wins, as sourcing the file would give" {
	pin shapes <<-'EOF'
	MACKAS_VOLUME_NAME='first'
	MACKAS_VOLUME_NAME='middle'
	MACKAS_VOLUME_NAME='last-wins'
	EOF
	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^ +MACKAS_VOLUME_NAME +last-wins$'
	! printf '%s\n' "$output" | grep -q 'first'
}

@test "projects: a value 'set' wrote with an apostrophe in it reads back unmangled" {
	# shq() renders an embedded apostrophe as '\'' ; printing that back raw
	# is a corrupt listing of a file mackas itself wrote.
	run "$MACKAS" --project apos set MACKAS_VOLUME_NAME "it's-here"
	[ "$status" -eq 0 ]
	grep -qF "MACKAS_VOLUME_NAME='it'\\''s-here'" "$PROJDIR/apos.conf"

	run "$MACKAS" projects
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE "^ +MACKAS_VOLUME_NAME +it's-here\$"
}

# ---------------------------------------------------------------------------
# The empty-value form of the flag
# ---------------------------------------------------------------------------

@test "--project= with nothing after it is an error, not a silent fall-through" {
	# The separated form already dies; without the same check here, '--project='
	# would quietly drop back to the search path (or to an exported
	# \$MACKAS_PROJECT_SELECT), selecting something other than what was asked.
	echo 'MACKAS_KAS_CONFIG="from-search-path"' > "$HOME/.mackas.conf"
	chmod 600 "$HOME/.mackas.conf"
	run "$MACKAS" --project= status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'needs a NAME'
	! printf '%s\n' "$output" | grep -q 'from-search-path'
}

@test "--project= does not fall back to an exported \$MACKAS_PROJECT_SELECT either" {
	pin other <<-'EOF'
	MACKAS_KAS_CONFIG="from-other"
	EOF
	MACKAS_PROJECT_SELECT=other run "$MACKAS" --project= status
	[ "$status" -ne 0 ]
	! printf '%s\n' "$output" | grep -q 'from-other'
}

# The refusal's HINT, not just its exit status. This fires most often from a
# --project wrapper meeting a $MACKAS_CONF exported in a shell rc, where the
# selector named in the error is one the user never set -- so the hint has to
# show both resolved values and give the escape for whichever one they control.

@test "selector conflict: the hint shows BOTH resolved values, not just the names" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-pin"
	EOF
	printf 'MACKAS_KAS_CONFIG="from-env"\n' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -q "meta-ai"
	printf '%s\n' "$output" | grep -qF "$TESTDIR/env.conf"
}

@test "selector conflict: the hint gives the command to blank \$MACKAS_CONF" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-pin"
	EOF
	printf 'MACKAS_KAS_CONFIG="from-env"\n' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_CONF= <your command>'
	printf '%s\n' "$output" | grep -qF 'unset MACKAS_CONF'
}

@test "selector conflict: a FLAG-sourced path says drop the flag, not unset a variable" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-pin"
	EOF
	printf 'MACKAS_KAS_CONFIG="from-env"\n' > "$TESTDIR/env.conf"
	MACKAS_PROJECT_SELECT=meta-ai run "$MACKAS" --config "$TESTDIR/env.conf" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'drop the --config flag'
	# It must NOT tell them to unset a variable they never set.
	! printf '%s\n' "$output" | grep -qF 'unset MACKAS_CONF'
}

@test "selector conflict: a FLAG-sourced selector says drop the flag, not unset a variable" {
	pin meta-ai <<-'EOF'
	MACKAS_KAS_CONFIG="from-pin"
	EOF
	printf 'MACKAS_KAS_CONFIG="from-env"\n' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" run "$MACKAS" --project meta-ai status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'drop the --project flag'
	! printf '%s\n' "$output" | grep -qF 'unset MACKAS_PROJECT_SELECT'
}

@test "--config= (empty) is refused exactly like --config \"\"" {
	run "$MACKAS" --config= status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF -- '--config needs a FILE'
}

@test "--config= does not fall back to an exported \$MACKAS_CONF" {
	printf 'MACKAS_KAS_CONFIG="from-env"\n' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" run "$MACKAS" --config= status
	[ "$status" -ne 0 ]
	! printf '%s\n' "$output" | grep -q 'from-env'
}

# The generated wrapper freezes MACKAS_WORK/KAS_IMAGE/gitconfig but recomputes
# volumes LIVE, so a config resolving a different root would hand a build
# another project's ext4 volumes while its sources and gitconfig stay put.
# Identity is compared rather than the config path being frozen into the
# wrapper, so an ambient $MACKAS_CONF keeps working whenever it agrees.

@test "--expect-work: a matching root still prints args" {
	mkdir -p "$TESTDIR/rootA/work"
	printf 'MACKAS_ROOT=%s\n' "$TESTDIR/rootA" > "$TESTDIR/A.conf"
	MACKAS_CONF="$TESTDIR/A.conf" run "$MACKAS" runtime-args --expect-work "$TESTDIR/rootA/work"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q -- '-v .*:/build'
}

@test "--expect-work: a DIFFERENT root is refused, naming both" {
	mkdir -p "$TESTDIR/rootA/work" "$TESTDIR/rootB/work"
	printf 'MACKAS_ROOT=%s\n' "$TESTDIR/rootB" > "$TESTDIR/B.conf"
	MACKAS_CONF="$TESTDIR/B.conf" run "$MACKAS" runtime-args --expect-work "$TESTDIR/rootA/work"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/rootA/work"
	printf '%s\n' "$output" | grep -qF "$TESTDIR/rootB/work"
}

@test "--expect-work: the refusal prints NO args string to accidentally use" {
	mkdir -p "$TESTDIR/rootA/work" "$TESTDIR/rootB/work"
	printf 'MACKAS_ROOT=%s\n' "$TESTDIR/rootB" > "$TESTDIR/B.conf"
	MACKAS_CONF="$TESTDIR/B.conf" run "$MACKAS" runtime-args --expect-work "$TESTDIR/rootA/work"
	[ "$status" -ne 0 ]
	! printf '%s\n' "$output" | grep -q -- '-v .*:/build'
}

@test "--expect-work: the refusal says how to drop \$MACKAS_CONF" {
	mkdir -p "$TESTDIR/rootA/work" "$TESTDIR/rootB/work"
	printf 'MACKAS_ROOT=%s\n' "$TESTDIR/rootB" > "$TESTDIR/B.conf"
	MACKAS_CONF="$TESTDIR/B.conf" run "$MACKAS" runtime-args --expect-work "$TESTDIR/rootA/work"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'unset MACKAS_CONF'
}

@test "--expect-work needs a value" {
	run "$MACKAS" runtime-args --expect-work
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF -- '--expect-work needs a DIR'
}
