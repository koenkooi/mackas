#!/usr/bin/env bats
#
# Tests for mackas configuration resolution:
#   built-in defaults -> config file -> environment -> command-line flags
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# These drive `mackas status`, which resolves the full configuration and
# prints it without mutating anything.

load helpers

setup() {
	TESTDIR="$(make_tmpdir)"
	# Run from an empty dir so a stray ./mackas.conf in the repo or in the
	# invoker's cwd can never leak into a test.
	cd "$TESTDIR"
	# Likewise, make sure the caller's environment cannot leak in.
	unset MACKAS_CONF MACKAS_MEMORY MACKAS_CPUS MACKAS_ROOT MACKAS_KAS_CONFIG
	unset MACKAS_VOLUME_SIZE_TMP MACKAS_OVERHEAD MACKAS_OVERHEAD_INTERVAL
	unset MACKAS_VOLUME_NAME MACKAS_VOLUME_DL_NAME MACKAS_VOLUME_SSTATE_NAME
	unset MACKAS_PROJECT_URL MACKAS_PROJECT_BRANCH MACKAS_PROJECT_DIR MACKAS_SMOKETEST_TARGETS
	# Point HOME at the throwaway dir so ~/.config/mackas/config and
	# ~/.mackas.conf cannot be picked up from the real home directory.
	export HOME="$TESTDIR"

	# `status` now queries the real container daemon for a volume's live cap
	# (Configuration shows it in place of MACKAS_VOLUME_SIZE_* once a volume
	# exists -- see display_volume_setting). MACKAS_VOLUME_NAME defaults to
	# "oe-build" regardless of MACKAS_ROOT/HOME, so on a dev Mac that already
	# has real oe-build-* volumes from actual use, an unfaked `container`
	# would answer with THAT real cap here -- these tests are about setting
	# PRECEDENCE, not live disk state, so make sure none ever exist.
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
	rm -rf "$TESTDIR"
}

# Read one setting out of `mackas status` output.
setting() {
	printf '%s\n' "$output" | awk -v k="$1" '$1 == k { $1=""; sub(/^ +/,""); print; exit }'
}

# The volume names `status` reports in its "ext4 volumes" section, in order.
# The fake `container` above answers "running" with an empty volume list, so
# every line is the "[ no]" form; both forms are matched anyway.
ext4_volume_names() {
	printf '%s\n' "$output" | sed -n 's/^  \[[ a-z]*\] \([^ ]*\) .*/\1/p'
}

# ---------------------------------------------------------------------------
# Level 1: built-in defaults
# ---------------------------------------------------------------------------

@test "defaults: a known default appears when nothing else is set" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "120G" ]
	[ "$(setting MACKAS_VOLUME_SIZE_DL)" = "40G" ]
	[ "$(setting MACKAS_VOLUME_SIZE_SSTATE)" = "40G" ]
}

@test "defaults: status reports that no config file was used" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'built-in defaults'
}

@test "defaults: host-side overhead sampling is ON with a 5 s interval" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_OVERHEAD)" = "1" ]
	[ "$(setting MACKAS_OVERHEAD_INTERVAL)" = "5" ]
}

@test "overhead: the settings ride the normal precedence machinery" {
	MACKAS_OVERHEAD=0 run "$MACKAS" status
	[ "$status" -eq 0 ]
	# Environment beats the default...
	[ "$(setting MACKAS_OVERHEAD)" = "0" ]
	# ...and --set beats even the environment.
	MACKAS_OVERHEAD_INTERVAL=9 run "$MACKAS" --set MACKAS_OVERHEAD_INTERVAL=2 status
	[ "$(setting MACKAS_OVERHEAD_INTERVAL)" = "2" ]
}

# ---------------------------------------------------------------------------
# Level 2: config file beats defaults
# ---------------------------------------------------------------------------

@test "config file beats the built-in default" {
	echo 'MACKAS_VOLUME_SIZE_TMP="99G"' > "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "99G" ]
}

@test "config file is reported in status" {
	echo 'MACKAS_VOLUME_SIZE_TMP="99G"' > "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "$TESTDIR/c.conf"
}

# ---------------------------------------------------------------------------
# ./mackas.conf is NOT searched. This is the important one.
#
# It used to be, which made `cd` into an untrusted tree enough to run its
# author's shell code as you: a config file is SOURCED, and every subcommand
# loaded one. These tests pin the fix from both ends -- the cwd file is not
# read for its VALUES, and, separately, its CODE does not run.
# ---------------------------------------------------------------------------

@test "./mackas.conf in cwd is NOT sourced automatically" {
	echo 'MACKAS_KAS_CONFIG="kas/pwned.yml"' > "$TESTDIR/mackas.conf"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	# The built-in default (empty -- no baked-in project), not the value the
	# cwd file asked for.
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
	printf '%s\n' "$output" | grep -q 'built-in defaults'
}

@test "./mackas.conf in cwd does not EXECUTE (the RCE)" {
	# The real payload shape: a config file in a directory you merely
	# walked into, doing something other than assigning a variable.
	cat > "$TESTDIR/mackas.conf" <<-EOF
	touch "$TESTDIR/PWNED"
	MACKAS_KAS_CONFIG="pwned"
	EOF
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/PWNED" ]
	[ "$(setting MACKAS_KAS_CONFIG)" != "pwned" ]
}

@test "a cwd mackas.conf executes for NO subcommand, help included" {
	# Every entry point loaded config, so every entry point was affected --
	# --version was the lone exception, because it exits during arg parsing.
	cat > "$TESTDIR/mackas.conf" <<-EOF
	touch "$TESTDIR/PWNED"
	EOF
	local c
	for c in help status check --version; do
		rm -f "$TESTDIR/PWNED"
		run "$MACKAS" "$c"
		if [ -e "$TESTDIR/PWNED" ]; then
			echo "cwd config executed for subcommand: $c" >&2
			return 1
		fi
	done
}

@test "a per-project config still works when named explicitly" {
	# Dropping ./mackas.conf from the search path must not take the use case
	# with it. It only stops being implicit.
	echo 'MACKAS_KAS_CONFIG="kas/pwned.yml"' > "$TESTDIR/mackas.conf"
	run "$MACKAS" --config ./mackas.conf status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "kas/pwned.yml" ]
}

# ---------------------------------------------------------------------------
# `help` never loads config at all
# ---------------------------------------------------------------------------

@test "help does not load the config file" {
	# Not just the cwd one. help cannot act on a setting, so it has no reason
	# to source ANY config -- including a perfectly legitimate ~/.mackas.conf.
	cat > "$HOME/.mackas.conf" <<-EOF
	touch "$TESTDIR/HOME_CONF_RAN"
	EOF
	run "$MACKAS" help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/HOME_CONF_RAN" ]
}

@test "help does not load even an explicitly given --config" {
	cat > "$TESTDIR/c.conf" <<-EOF
	touch "$TESTDIR/EXPLICIT_RAN"
	EOF
	run "$MACKAS" --config "$TESTDIR/c.conf" help
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/EXPLICIT_RAN" ]
}

@test "-h does not load the config file either" {
	cat > "$HOME/.mackas.conf" <<-EOF
	touch "$TESTDIR/HOME_CONF_RAN"
	EOF
	run "$MACKAS" -h
	[ "$status" -eq 0 ]
	[ ! -e "$TESTDIR/HOME_CONF_RAN" ]
}

@test "help still prints usage with its settings filled in" {
	# Skipping load_config must not leave the settings usage interpolates
	# unset -- set -u would turn that into a crash instead of a help message.
	# No project is configured by default, so usage() takes its "nothing
	# configured yet" branch -- still an interpolated settings-derived line,
	# still proof the unset-variable path didn't crash.
	run "$MACKAS" help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'USAGE'
	printf '%s\n' "$output" | grep -qi 'no project configured'
}

@test "help no longer advertises ./mackas.conf as a searched path" {
	run "$MACKAS" help
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -qE '^\s+\./mackas\.conf\s*$'
}

@test "help honours --set and the environment, just not the config file" {
	# usage() only prints the branch when a project is configured at all --
	# give it a URL too, or this is testing "no project configured" instead.
	run "$MACKAS" --set MACKAS_PROJECT_URL=https://example.invalid/x.git \
		--set MACKAS_PROJECT_BRANCH=fromflag help
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'fromflag'
}

# ---------------------------------------------------------------------------
# A searched config must be ours, and only ours
# ---------------------------------------------------------------------------

@test "a group-writable searched config is ignored, with a warning" {
	echo 'MACKAS_KAS_CONFIG="from-home"' > "$HOME/.mackas.conf"
	chmod g+w "$HOME/.mackas.conf"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
	printf '%s\n' "$output" | grep -qi 'ignoring'
}

@test "a world-writable searched config is ignored" {
	echo 'MACKAS_KAS_CONFIG="from-home"' > "$HOME/.mackas.conf"
	chmod o+w "$HOME/.mackas.conf"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

@test "a searched config in a group-writable directory is ignored" {
	# The file itself is 0644 and ours. The DIRECTORY is what lets someone
	# else swap it out, which is just as good as editing it. A group-writable
	# \$HOME is a real configuration, not a hypothetical one.
	echo 'MACKAS_KAS_CONFIG="from-home"' > "$HOME/.mackas.conf"
	chmod 644 "$HOME/.mackas.conf"
	chmod g+w "$HOME"
	run "$MACKAS" status
	chmod g-w "$HOME"
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

@test "a normal 0644 config in a 0755 home is still used" {
	# The other side of the check: it must not reject the ordinary setup.
	# The maintainer's own ~/.mackas.conf is exactly this, and the live build
	# depends on the MACKAS_ROOT it sets.
	echo 'MACKAS_KAS_CONFIG="from-home"' > "$HOME/.mackas.conf"
	chmod 644 "$HOME/.mackas.conf"
	chmod 755 "$HOME"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-home" ]
}

@test "~/.config/mackas/config is still searched, and checked the same way" {
	mkdir -p "$HOME/.config/mackas"
	echo 'MACKAS_KAS_CONFIG="from-xdg"' > "$HOME/.config/mackas/config"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-xdg" ]

	chmod g+w "$HOME/.config/mackas/config"
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

@test "an explicit --config is used even when group-writable" {
	# The ownership check is for files mackas goes LOOKING for. A path the
	# user named is a decision already made, and refusing it would break a
	# config kept on a shared volume for no gain.
	echo 'MACKAS_KAS_CONFIG="explicit"' > "$TESTDIR/c.conf"
	chmod g+w "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "explicit" ]
}

# ---------------------------------------------------------------------------
# $MACKAS_CONF pointing at nothing
# ---------------------------------------------------------------------------

@test "\$MACKAS_CONF naming a missing file dies with guidance" {
	# --config had this check; the env var did not, so it fell through to the
	# bare `.` and printed a localized "No such file or directory" naming
	# neither mackas nor the variable at fault.
	MACKAS_CONF="$TESTDIR/nope.conf" run "$MACKAS" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not readable'
	printf '%s\n' "$output" | grep -qF "$TESTDIR/nope.conf"
	# It must say what to do about it, and name the knob.
	printf '%s\n' "$output" | grep -q 'next:'
	printf '%s\n' "$output" | grep -q 'MACKAS_CONF'
	# And it must not be the raw shell error.
	! printf '%s\n' "$output" | grep -qi 'No such file or directory'
}

@test "\$MACKAS_CONF naming an unreadable file dies with guidance" {
	echo 'MACKAS_KAS_CONFIG="x"' > "$TESTDIR/unreadable.conf"
	chmod 000 "$TESTDIR/unreadable.conf"
	MACKAS_CONF="$TESTDIR/unreadable.conf" run "$MACKAS" status
	chmod 644 "$TESTDIR/unreadable.conf"
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not readable'
}

@test "\$MACKAS_CONF points at a config file" {
	echo 'MACKAS_KAS_CONFIG="from-env-conf"' > "$TESTDIR/env.conf"
	MACKAS_CONF="$TESTDIR/env.conf" run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-env-conf" ]
}

@test "--config beats \$MACKAS_CONF" {
	echo 'MACKAS_KAS_CONFIG="from-env-conf"' > "$TESTDIR/env.conf"
	echo 'MACKAS_KAS_CONFIG="from-flag-conf"' > "$TESTDIR/flag.conf"
	MACKAS_CONF="$TESTDIR/env.conf" run "$MACKAS" --config "$TESTDIR/flag.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-flag-conf" ]
}

@test "an unreadable --config file is a hard error" {
	run "$MACKAS" --config "$TESTDIR/does-not-exist.conf" status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'config'
}

@test "a config value containing spaces survives" {
	printf 'MACKAS_ROOT="/Volumes/My Build Disk/oe"\n' > "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_ROOT)" = "/Volumes/My Build Disk/oe" ]
}

# ---------------------------------------------------------------------------
# Level 3: environment beats config file
# ---------------------------------------------------------------------------

@test "environment beats the config file" {
	echo 'MACKAS_VOLUME_SIZE_TMP="99G"' > "$TESTDIR/c.conf"
	MACKAS_VOLUME_SIZE_TMP="77G" run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "77G" ]
}

@test "environment beats the default when there is no config file" {
	MACKAS_KAS_CONFIG="from-env" run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "from-env" ]
}

@test "an env value containing spaces survives" {
	MACKAS_ROOT="/a b/c d" run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_ROOT)" = "/a b/c d" ]
}

@test "an unset env var does not override the config file" {
	# Regression guard for the snapshot/restore mechanism: only variables
	# genuinely present in the environment may win over the config file.
	echo 'MACKAS_VOLUME_SIZE_TMP="99G"' > "$TESTDIR/c.conf"
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "99G" ]
}

# ---------------------------------------------------------------------------
# Level 4: --set beats everything
# ---------------------------------------------------------------------------

@test "--set beats the environment" {
	MACKAS_VOLUME_SIZE_TMP="77G" run "$MACKAS" --set MACKAS_VOLUME_SIZE_TMP=55G status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "55G" ]
}

@test "--set beats the config file and the environment together" {
	echo 'MACKAS_VOLUME_SIZE_TMP="99G"' > "$TESTDIR/c.conf"
	MACKAS_VOLUME_SIZE_TMP="77G" run "$MACKAS" --config "$TESTDIR/c.conf" \
		--set MACKAS_VOLUME_SIZE_TMP=55G status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "55G" ]
}

@test "--set=NAME=VALUE combined form works" {
	run "$MACKAS" --set=MACKAS_VOLUME_SIZE_TMP=55G status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "55G" ]
}

@test "--set is repeatable" {
	run "$MACKAS" --set MACKAS_VOLUME_SIZE_TMP=55G --set MACKAS_KAS_CONFIG=qemux86-64 status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_VOLUME_SIZE_TMP)" = "55G" ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "qemux86-64" ]
}

@test "--set handles a value containing spaces" {
	run "$MACKAS" --set "MACKAS_ROOT=/a b/c d" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_ROOT)" = "/a b/c d" ]
}

@test "--set splits on the first '=' only, so values may contain '='" {
	run "$MACKAS" --set "MACKAS_ROOT=/tmp/a=b" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_ROOT)" = "/tmp/a=b" ]
}

@test "--set rejects an unknown setting name" {
	run "$MACKAS" --set NOT_A_SETTING=1 status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'unknown setting'
}

@test "--set rejects a value with no '='" {
	run "$MACKAS" --set MACKAS_VOLUME_SIZE_TMP status
	[ "$status" -ne 0 ]
}

@test "--set with no argument is an error" {
	run "$MACKAS" --set
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

@test "derived paths follow an overridden MACKAS_ROOT" {
	run "$MACKAS" --set "MACKAS_ROOT=/tmp/mackas-derive-test" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "/tmp/mackas-derive-test/work"
	printf '%s\n' "$output" | grep -qF "/tmp/mackas-derive-test/env.sh"
	# There is deliberately no .../downloads or .../sstate to assert on any
	# more: those are ext4 volumes, not host directories. See volumes.bats.
}

@test "an explicit MACKAS_NFS_MOUNT is not overwritten by the derivation" {
	run "$MACKAS" --set "MACKAS_NFS_MOUNT=/mnt/explicit" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_NFS_MOUNT)" = "/mnt/explicit" ]
}

@test "kas files argument is MACKAS_KAS_CONFIG with macos-local.yml appended" {
	run "$MACKAS" --set MACKAS_KAS_CONFIG=kas/base.yml:kas/qemux86-64.yml status
	[ "$status" -eq 0 ]
	# The generated fragment is composed LAST so it wins.
	printf '%s\n' "$output" | grep -qF "kas/base.yml:kas/qemux86-64.yml:kas/macos-local.yml"
}

@test "an empty MACKAS_KAS_CONFIG yields a fragment-only kas files arg (no leading colon)" {
	# A leading ':' would be a kas parse error, not an empty element.
	run "$MACKAS" --set MACKAS_KAS_CONFIG= status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '^  kas files +kas/macos-local.yml$'
	! printf '%s\n' "$output" | grep -qE '^  kas files +:'
}

# ---------------------------------------------------------------------------
# HTTP mirror knobs -- same precedence chain as everything else
# ---------------------------------------------------------------------------

@test "MACKAS_USE_HTTP_MIRRORS defaults to off" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_USE_HTTP_MIRRORS)" = "0" ]
}

@test "MACKAS_HTTP_MIRROR_SSTATE default points at port 8100" {
	# 8100 is mackas-mirrord's own default port. The host is a placeholder,
	# not a real machine.
	run "$MACKAS" status
	[ "$(setting MACKAS_HTTP_MIRROR_SSTATE)" = "http://linux-computer.local:8100/sstate" ]
	[ "$(setting MACKAS_HTTP_MIRROR_DL)" = "http://linux-computer.local:8100/downloads" ]
}

@test "a config file can set the HTTP mirror URLs" {
	cat > "$TESTDIR/c.conf" <<-EOF
	MACKAS_USE_HTTP_MIRRORS=1
	MACKAS_HTTP_MIRROR_SSTATE="http://conf:1/ss"
	EOF
	run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$(setting MACKAS_USE_HTTP_MIRRORS)" = "1" ]
	[ "$(setting MACKAS_HTTP_MIRROR_SSTATE)" = "http://conf:1/ss" ]
}

@test "env beats the config file for the HTTP mirror URL" {
	cat > "$TESTDIR/c.conf" <<-EOF
	MACKAS_HTTP_MIRROR_SSTATE="http://conf:1/ss"
	EOF
	MACKAS_HTTP_MIRROR_SSTATE="http://env:2/ss" run "$MACKAS" --config "$TESTDIR/c.conf" status
	[ "$(setting MACKAS_HTTP_MIRROR_SSTATE)" = "http://env:2/ss" ]
}

@test "--set beats env for the HTTP mirror URL" {
	MACKAS_HTTP_MIRROR_SSTATE="http://env:2/ss" run "$MACKAS" \
		--set MACKAS_HTTP_MIRROR_SSTATE="http://cli:3/ss" status
	[ "$(setting MACKAS_HTTP_MIRROR_SSTATE)" = "http://cli:3/ss" ]
}

# ---------------------------------------------------------------------------
# MACKAS_ROOT has no baked-in default (OE needs a case-sensitive filesystem and
# a stock Mac's $HOME is case-insensitive APFS). `status` and `check` RUN with
# it unset (they are how you find out it is missing); every mutating command
# falls back to $PWD with a loud warning, rather than refusing or crashing.
# ---------------------------------------------------------------------------

@test "MACKAS_ROOT has no built-in default" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ -z "$(setting MACKAS_ROOT)" ]
}

@test "status runs with MACKAS_ROOT unset and says it is not set" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q 'MACKAS_ROOT is not set'
	# The guidance names the case-sensitive volume recipe.
	printf '%s\n' "$output" | grep -qi 'case-sensitive'
}

@test "setup falls back to \$PWD with a warning (no crash) when MACKAS_ROOT is unset" {
	run "$MACKAS" --dry-run -y setup
	printf '%s\n' "$output" | grep -q 'MACKAS_ROOT is not set'
	printf '%s\n' "$output" | grep -qF 'using the current directory'
	# A crash would look like a bash 'unbound variable' or a syntax error.
	! printf '%s\n' "$output" | grep -qi 'unbound variable'
	! printf '%s\n' "$output" | grep -qi 'syntax error'
}

@test "setup --tmpdir-size 512K is refused (unrecognised unit)" {
	run "$MACKAS" --dry-run -y setup --tmpdir-size 512K
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'not a size'
}

@test "smoketest falls back to \$PWD with a warning when MACKAS_ROOT is unset" {
	run "$MACKAS" --dry-run -y smoketest
	printf '%s\n' "$output" | grep -q 'MACKAS_ROOT is not set'
	printf '%s\n' "$output" | grep -qF 'using the current directory'
}

@test "check reports MACKAS_ROOT unset as a WARN, not a crash" {
	run "$MACKAS" check
	# The unset root is a warning now (there is a $PWD fallback); the point is
	# check ran to its summary and named it, rather than crashing.
	printf '%s\n' "$output" | grep -q 'MACKAS_ROOT is not set'
	printf '%s\n' "$output" | grep -qi 'current directory'
}

# ---------------------------------------------------------------------------
# The project settings (URL / branch / dir / kas config) drive the clone and
# the composed kas files. There is no baked-in default project -- meta-ai is
# only the worked EXAMPLE in mackas.conf.example.
# ---------------------------------------------------------------------------

@test "project settings default to empty (no built-in project)" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_PROJECT_URL)" = "" ]
	[ "$(setting MACKAS_PROJECT_BRANCH)" = "" ]
	[ "$(setting MACKAS_PROJECT_DIR)" = "" ]
	[ "$(setting MACKAS_KAS_CONFIG)" = "" ]
}

@test "MACKAS_PROJECT_DIR names the checkout directory under work/" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set MACKAS_PROJECT_DIR=my-layers status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF "/tmp/mackas test dir/work/my-layers"
}

@test "MACKAS_PROJECT_URL is what setup would clone" {
	# setup's preflight dies if `container` is not on PATH, so this test is only
	# hermetic with a fake one -- otherwise it silently depends on the host
	# having Apple container installed (it green on a dev Mac, red anywhere
	# else). The mock echoes "status running" for the one query setup makes and
	# exits 0 for everything else; --dry-run prints the rest rather than running
	# it. This test is about the clone command, not the runtime.
	mkdir -p "$TESTDIR/fakebin"
	cat > "$TESTDIR/fakebin/container" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
	"system status"*) echo "status running" ;;
esac
exit 0
MOCK
	chmod +x "$TESTDIR/fakebin/container"
	MACKAS_ROOT="/tmp/mackas test dir" PATH="$TESTDIR/fakebin:$PATH" \
		run "$MACKAS" --dry-run \
		--set MACKAS_PROJECT_URL=https://example.invalid/foo.git \
		--set MACKAS_PROJECT_BRANCH=main setup
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'git clone --branch main https://example.invalid/foo.git'
}

@test "the default smoketest targets are empty -- kas builds its own default" {
	run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_SMOKETEST_TARGETS)" = "" ]
}

# ---------------------------------------------------------------------------
# A4: MACKAS_CPUS / MACKAS_MEMORY are word-split into --runtime-args, so a
# space in either smuggles extra container arguments past every other check.
# ---------------------------------------------------------------------------

@test "MACKAS_MEMORY with an embedded flag is refused, not smuggled" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_MEMORY=8g -v /Users:/host' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_MEMORY'
}

@test "MACKAS_CPUS that is not a whole number is refused" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_CPUS=18 --privileged' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_CPUS'
}

@test "a plain MACKAS_MEMORY size is still accepted" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set MACKAS_MEMORY=16g status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_MEMORY)" = "16g" ]
}

@test "MACKAS_VOLUME_NAME with a space is refused, not smuggled" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_VOLUME_NAME=oe build' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_VOLUME_NAME'
}

@test "MACKAS_VOLUME_NAME empty is refused" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_VOLUME_NAME=' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_VOLUME_NAME'
}

@test "MACKAS_VOLUME_DL_NAME with a space is refused, not word-split" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_VOLUME_DL_NAME=shared dl' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_VOLUME_DL_NAME'
	printf '%s\n' "$output" | grep -qi 'whitespace'
}

@test "MACKAS_VOLUME_SSTATE_NAME with a space is refused, not word-split" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_VOLUME_SSTATE_NAME=shared sstate' status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_VOLUME_SSTATE_NAME'
	printf '%s\n' "$output" | grep -qi 'whitespace'
}

@test "an empty MACKAS_VOLUME_DL_NAME is accepted -- empty is how you say 'derive it'" {
	# The stem refuses empty; these two must not, or the documented default
	# would be un-settable.
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set 'MACKAS_VOLUME_DL_NAME=' status
	[ "$status" -eq 0 ]
	[ -z "$(setting MACKAS_VOLUME_DL_NAME)" ]
}

@test "both volume-name overrides are listed in the resolved configuration, empty by default" {
	MACKAS_ROOT="/tmp/mackas test dir" run "$MACKAS" status
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qF 'MACKAS_VOLUME_DL_NAME'
	printf '%s\n' "$output" | grep -qF 'MACKAS_VOLUME_SSTATE_NAME'
	[ -z "$(setting MACKAS_VOLUME_DL_NAME)" ]
	[ -z "$(setting MACKAS_VOLUME_SSTATE_NAME)" ]
}

@test "the overrides reach status with the same names whether MACKAS_ROOT is set or not" {
	# derive_paths() has TWO branches -- an early return for an unset
	# MACKAS_ROOT, and the main one. `status`, `help` and `volume list` on a
	# machine with no root configured go through the FIRST, so deriving in
	# only one makes mackas PRINT one set of names and OPERATE on another.
	run "$MACKAS" --set MACKAS_VOLUME_DL_NAME=shared-dl \
		--set MACKAS_VOLUME_SSTATE_NAME=shared-sstate status
	[ "$status" -eq 0 ]
	# Prove this really was the no-root branch, not a $PWD fallback.
	printf '%s\n' "$output" | grep -qF 'MACKAS_ROOT is not set'
	local noroot; noroot="$(ext4_volume_names)"

	MACKAS_ROOT="$TESTDIR/oe" run "$MACKAS" --set MACKAS_VOLUME_DL_NAME=shared-dl \
		--set MACKAS_VOLUME_SSTATE_NAME=shared-sstate status
	[ "$status" -eq 0 ]
	local withroot; withroot="$(ext4_volume_names)"

	[ -n "$noroot" ]
	[ "$noroot" = "$withroot" ]
	[ "$noroot" = "oe-build-tmp
shared-dl
shared-sstate" ]
}

@test "a garbage MACKAS_VOLUME_SIZE_TMP dies before reaching the container CLI" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set MACKAS_VOLUME_SIZE_TMP=lol status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_VOLUME_SIZE_TMP'
}

@test "an unrecognised size unit on MACKAS_VOLUME_SIZE_DL is refused" {
	MACKAS_ROOT="/tmp/mackas test dir" \
		run "$MACKAS" --set MACKAS_VOLUME_SIZE_DL=512K status
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'MACKAS_VOLUME_SIZE_DL'
}

@test "valid MACKAS_VOLUME_SIZE_SSTATE shapes are all accepted" {
	for v in 1T 200G 512M 42; do
		MACKAS_ROOT="/tmp/mackas test dir" \
			run "$MACKAS" --set "MACKAS_VOLUME_SIZE_SSTATE=$v" status
		[ "$status" -eq 0 ]
		[ "$(setting MACKAS_VOLUME_SIZE_SSTATE)" = "$v" ]
	done
}

@test "defaults: auto-fstrim is ON" {
	MACKAS_ROOT="/tmp/mackas test dir" run "$MACKAS" status
	[ "$status" -eq 0 ]
	[ "$(setting MACKAS_FSTRIM_AUTO)" = "1" ]
}
