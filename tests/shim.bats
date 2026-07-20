#!/usr/bin/env bats
#
# Tests for bin/docker -- the docker -> Apple `container` translation shim.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Every test here points the shim at tests/mock/container via
# MACKAS_CONTAINER_BIN, so the real Apple container runtime is never invoked
# and the suite runs anywhere, with no VM and no sudo.

load helpers

# ---------------------------------------------------------------------------
# Engine detection: what kas-container actually probes
# ---------------------------------------------------------------------------

@test "docker -v output starts with 'Docker' (kas engine probe)" {
	run_shim -v
	[ "$status" -eq 0 ]
	# kas-container does: docker -v 2>/dev/null | grep -q '^Docker'
	printf '%s\n' "$output" | grep -q '^Docker'
}

@test "docker --version and 'docker version' also report Docker" {
	run_shim --version
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q '^Docker'

	run_shim version
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q '^Docker'
}

@test "docker -v does not shell out to the container binary" {
	# Even if `container` is missing entirely, the version probe must work.
	MACKAS_CONTAINER_BIN=/nonexistent/definitely-not-here run "$SHIM" -v
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -q '^Docker'
}

@test "docker context show prints exactly 'default'" {
	run_shim context show
	[ "$status" -eq 0 ]
	[ "$output" = "default" ]
}

@test "docker context show does not contain 'rootless'" {
	# kas-container greps this for 'rootless' to pick a privileged workaround
	# path that Apple container cannot support.
	run_shim context show
	[ "$status" -eq 0 ]
	! printf '%s\n' "$output" | grep -q 'rootless'
}

# ---------------------------------------------------------------------------
# Dropped flags: Apple container rejects these with exit 64 "Unknown option"
# ---------------------------------------------------------------------------

@test "--log-driver=none is dropped (combined form)" {
	run_shim run --log-driver=none alpine true
	[ "$status" -eq 0 ]
	refute_arg "--log-driver=none"
	refute_arg "--log-driver"
	assert_arg "alpine"
}

@test "--log-driver none is dropped along with its value (separate form)" {
	run_shim run --log-driver none alpine true
	[ "$status" -eq 0 ]
	refute_arg "--log-driver"
	refute_arg "none"
	assert_arg "alpine"
}

@test "--security-opt is dropped in both forms" {
	run_shim run --security-opt seccomp=unconfined alpine true
	[ "$status" -eq 0 ]
	refute_arg "--security-opt"
	refute_arg "seccomp=unconfined"
	assert_arg "alpine"

	run_shim run --security-opt=label=disable alpine true
	[ "$status" -eq 0 ]
	refute_arg "--security-opt=label=disable"
	assert_arg "alpine"
}

@test "--userns is dropped in both forms" {
	run_shim run --userns keep-id alpine true
	[ "$status" -eq 0 ]
	refute_arg "--userns"
	refute_arg "keep-id"
	assert_arg "alpine"

	run_shim run --userns=host alpine true
	[ "$status" -eq 0 ]
	refute_arg "--userns=host"
	assert_arg "alpine"
}

@test "--group-add is dropped in both forms" {
	run_shim run --group-add docker alpine true
	[ "$status" -eq 0 ]
	refute_arg "--group-add"
	refute_arg "docker"
	assert_arg "alpine"

	run_shim run --group-add=video alpine true
	[ "$status" -eq 0 ]
	refute_arg "--group-add=video"
	assert_arg "alpine"
}

@test "--privileged is dropped (boolean: consumes no value)" {
	run_shim run --privileged alpine true
	[ "$status" -eq 0 ]
	refute_arg "--privileged"
	assert_arg "alpine"
	assert_arg "true"
}

@test "--privileged does not swallow the following token" {
	# Regression guard: --privileged takes no value, so treating it like a
	# value flag would eat the image name.
	run_shim run --privileged alpine echo hi
	[ "$status" -eq 0 ]
	assert_arg "alpine"
	assert_arg "echo"
	assert_arg "hi"
}

@test "several dropped flags together still yield a clean command line" {
	run_shim run --rm --log-driver=none --privileged --security-opt x \
		--userns y --group-add z -v /host:/ctr:ro alpine sh -c "echo ok"
	[ "$status" -eq 0 ]
	refute_arg "--log-driver=none"
	refute_arg "--privileged"
	refute_arg "--security-opt"
	refute_arg "--userns"
	refute_arg "--group-add"
	refute_arg "x"
	refute_arg "y"
	refute_arg "z"
	# The good stuff survives.
	assert_arg "--rm"
	assert_arg "-v"
	assert_arg "/host:/ctr:ro"
	assert_arg "alpine"
	assert_arg "echo ok"
}

# ---------------------------------------------------------------------------
# Hard failures: no equivalent, must not be silently dropped
# ---------------------------------------------------------------------------

@test "--device hard-fails rather than being dropped" {
	run_shim run --device /dev/kvm alpine true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'device'
}

@test "--device=... (combined form) hard-fails too" {
	run_shim run --device=/dev/fuse alpine true
	[ "$status" -ne 0 ]
}

@test "--network host hard-fails (separate form)" {
	run_shim run --network host alpine true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'network host'
}

@test "--network=host hard-fails (combined form)" {
	run_shim run --network=host alpine true
	[ "$status" -ne 0 ]
	printf '%s\n' "$output" | grep -qi 'network host'
}

@test "--network with a non-host value is passed through" {
	run_shim run --network mynet alpine true
	[ "$status" -eq 0 ]
	assert_arg "--network"
	assert_arg "mynet"
}

# ---------------------------------------------------------------------------
# Quoting: arguments with spaces must survive translation intact
# ---------------------------------------------------------------------------

@test "a -v volume path containing spaces survives as ONE argument" {
	run_shim run -v "/Volumes/My Build Disk/oe:/repo:rw" alpine true
	[ "$status" -eq 0 ]
	assert_arg "/Volumes/My Build Disk/oe:/repo:rw"
	# And must not have been split on the spaces.
	refute_arg "/Volumes/My"
	refute_arg "Build"
}

@test "an -e env value containing spaces survives as ONE argument" {
	run_shim run -e "SSTATE_MIRRORS=file://.* http://linux-computer.local:8100/PATH" \
		alpine true
	[ "$status" -eq 0 ]
	assert_arg "SSTATE_MIRRORS=file://.* http://linux-computer.local:8100/PATH"
	refute_arg "file://.*"
}

@test "spaces survive even when mixed with dropped flags" {
	run_shim run --privileged -v "/a b/c:/repo" --log-driver=none \
		-e "X=y z" alpine true
	[ "$status" -eq 0 ]
	assert_arg "/a b/c:/repo"
	assert_arg "X=y z"
	refute_arg "--privileged"
}

@test "an empty-string argument is preserved" {
	run_shim run -e "EMPTY=" alpine true
	[ "$status" -eq 0 ]
	assert_arg "EMPTY="
}

# ---------------------------------------------------------------------------
# The IMAGE positional boundary: everything after it is forwarded verbatim
# ---------------------------------------------------------------------------

@test "flags after the IMAGE positional are forwarded verbatim, not translated" {
	# --privileged here is an argument to the container's command, not to
	# docker run. It must survive untouched.
	run_shim run --rm alpine sh -c "echo --privileged"
	[ "$status" -eq 0 ]
	assert_arg "alpine"
	assert_arg "sh"
	assert_arg "-c"
	assert_arg "echo --privileged"
}

@test "a --device after the IMAGE positional does NOT trigger the hard fail" {
	run_shim run --rm alpine myprog --device /dev/null
	[ "$status" -eq 0 ]
	assert_arg "--device"
	assert_arg "/dev/null"
}

@test "--network host after the IMAGE positional is forwarded, not refused" {
	run_shim run --rm alpine myprog --network host
	[ "$status" -eq 0 ]
	assert_arg "--network"
	assert_arg "host"
}

@test "argv order is preserved exactly" {
	run_shim run --rm -v /a:/b alpine cmd one two
	[ "$status" -eq 0 ]
	# `run` is prepended by the shim; the rest keeps its relative order.
	want=$(printf 'run\n--rm\n-v\n/a:/b\nalpine\ncmd\none\ntwo\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "the image is forwarded when it is the only argument" {
	run_shim run alpine
	[ "$status" -eq 0 ]
	want=$(printf 'run\nalpine\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

# ---------------------------------------------------------------------------
# Pass-through flags Apple container supports natively
# ---------------------------------------------------------------------------

@test "-v with :ro and :rw suffixes passes through unrewritten" {
	run_shim run -v /h:/c:ro -v /h2:/c2:rw alpine true
	[ "$status" -eq 0 ]
	assert_arg "/h:/c:ro"
	assert_arg "/h2:/c2:rw"
}

@test "cpu and memory flags pass through (mackas relies on these for bitbake)" {
	run_shim run -c 18 -m 42g alpine true
	[ "$status" -eq 0 ]
	assert_arg "-c"
	assert_arg "18"
	assert_arg "-m"
	assert_arg "42g"
}

@test "an unrecognized flag is passed through opaquely" {
	run_shim run --some-future-flag alpine true
	[ "$status" -eq 0 ]
	assert_arg "--some-future-flag"
	assert_arg "alpine"
}

# ---------------------------------------------------------------------------
# Subcommand mapping (docker names -> Apple container names)
# ---------------------------------------------------------------------------

@test "docker pull -> container image pull" {
	run_shim pull alpine
	[ "$status" -eq 0 ]
	want=$(printf 'image\npull\nalpine\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "docker images -> container image ls (not 'images')" {
	run_shim images
	[ "$status" -eq 0 ]
	want=$(printf 'image\nls\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "docker ps -> container list (not 'ps')" {
	run_shim ps -a
	[ "$status" -eq 0 ]
	want=$(printf 'list\n-a\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "docker rmi -> container image rm" {
	run_shim rmi alpine
	[ "$status" -eq 0 ]
	want=$(printf 'image\nrm\nalpine\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "docker volume passes through to container volume" {
	run_shim volume create -s 200G oe-build
	[ "$status" -eq 0 ]
	want=$(printf 'volume\ncreate\n-s\n200G\noe-build\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

@test "an unmapped subcommand is passed straight through" {
	run_shim system start
	[ "$status" -eq 0 ]
	want=$(printf 'system\nstart\n')
	got=$(mock_argv)
	[ "$got" = "$want" ]
}

# ---------------------------------------------------------------------------
# Failure propagation
# ---------------------------------------------------------------------------

@test "a failure from the container binary propagates to the caller" {
	MOCK_CONTAINER_FAIL=42 MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" \
		run "$SHIM" run alpine true
	[ "$status" -eq 42 ]
}

@test "the deprecated DOCKER_SHIM_CONTAINER_BIN alias still works" {
	DOCKER_SHIM_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" run alpine true
	[ "$status" -eq 0 ]
	assert_arg "alpine"
}

@test "MACKAS_CONTAINER_BIN wins over the deprecated alias" {
	DOCKER_SHIM_CONTAINER_BIN=/nonexistent/nope \
	MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" run alpine true
	[ "$status" -eq 0 ]
	assert_arg "alpine"
}

# ---------------------------------------------------------------------------
# docker inspect: try `container inspect`, fall back to `container image
# inspect`. docker's inspect works on both containers and images; Apple
# `container` splits them, so the shim tries the container form and, on
# failure, execs the image form.
# ---------------------------------------------------------------------------

INSPECT_MOCK="$BATS_TEST_DIRNAME/fixtures/inspect-container"

@test "docker inspect falls back to 'container image inspect' when 'container inspect' fails" {
	# container inspect fails; the fallback must fire, print the image-inspect
	# output, and exit 0.
	INSPECT_MODE=image-only MACKAS_CONTAINER_BIN="$INSPECT_MOCK" \
		run "$SHIM" inspect alpine
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qxF "IMAGE-INSPECT-OK:alpine"
	# The container-inspect stderr must NOT leak: the shim captured it with 2>&1
	# and discarded it on the successful fallback.
	! printf '%s\n' "$output" | grep -q 'no such container'
}

@test "docker inspect propagates the image-inspect exit status when BOTH fail" {
	# Neither container nor image inspect knows the name: the shim must exit with
	# the image-inspect status (5 here), not a masked 0.
	INSPECT_MODE=both-fail MACKAS_CONTAINER_BIN="$INSPECT_MOCK" \
		run "$SHIM" inspect ghost
	[ "$status" -eq 5 ]
	printf '%s\n' "$output" | grep -qF 'no such image: ghost'
}

@test "docker inspect forwards ALL its arguments to the fallback" {
	# The fallback is `exec container image inspect "$@"`, so a name after flags
	# must reach it intact -- the mock echoes ${3:-}, i.e. the third arg of
	# `image inspect <name>`.
	INSPECT_MODE=image-only MACKAS_CONTAINER_BIN="$INSPECT_MOCK" \
		run "$SHIM" inspect busybox
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qxF "IMAGE-INSPECT-OK:busybox"
}

# ---------------------------------------------------------------------------
# known_value_flags as a CLASS: every value-taking flag must keep its value
# paired, so the value is never re-read as the IMAGE positional. The flag list
# is EXTRACTED from the shim source, so the test tracks it rather than pinning a
# stale copy.
# ---------------------------------------------------------------------------

# Pull the known_value_flags=( ... ) array body straight out of the shim.
extract_known_value_flags() {
	awk '/known_value_flags=\(/ {f=1; next} f && /\)/ {f=0} f' "$SHIM"
}

@test "shim: the known_value_flags array is actually extractable and non-trivial" {
	# Guards the class loop below from passing vacuously on an empty list.
	local flags
	flags="$(extract_known_value_flags)"
	[ -n "$flags" ]
	local n
	n="$(printf '%s\n' $flags | grep -c .)"
	[ "$n" -ge 40 ]
	# A couple of representatives really are in there.
	printf '%s\n' $flags | grep -qxF -- '-v'
	printf '%s\n' $flags | grep -qxF -- '--memory'
}

@test "shim: every known value flag keeps its value paired, plain and dash-leading" {
	local flags f seen=0
	flags="$(extract_known_value_flags)"
	for f in $flags; do
		seen=$((seen + 1))

		# Plain value: the whole line survives, alpine is the image, true after.
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" run "$f" VALUE alpine true
		if [ "$status" -ne 0 ]; then
			echo "flag $f: plain value gave status $status" >&2; return 1
		fi
		assert_arg "alpine"
		assert_arg "true"

		# Dash-leading value: --device is a HARD-FAIL flag on its own. If $f did
		# NOT consume it as a value, the shim would parse --device as a fresh
		# flag and refuse (exit 1). That it stays paired -- alpine still the
		# image, --device still present -- proves the value is never re-read as
		# the image positional.
		MACKAS_CONTAINER_BIN="$MOCK_CONTAINER" run "$SHIM" run "$f" --device alpine true
		if [ "$status" -ne 0 ]; then
			echo "flag $f: dash-leading value hard-failed (status $status)" >&2; return 1
		fi
		assert_arg "alpine"
		assert_arg "--device"
		assert_arg "true"
	done
	[ "$seen" -ge 40 ]
}
