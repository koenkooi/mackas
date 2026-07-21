# mackas

![mackas in action](docs/demo.svg)

**mac** + **kas**. Run [kas-container](https://github.com/siemens/kas)
OpenEmbedded builds on macOS, on Apple's native `container` runtime. No Docker
Desktop, no Lima, no Colima.

The project to build — its git repo, branch and kas config — is
configuration (`MACKAS_PROJECT_URL` / `_BRANCH` / `_DIR` and
`MACKAS_KAS_CONFIG`). There is no built-in default project: `setup` does its
whole job (volumes, kas-container, the shim, gitconfig) with none of this
set, and just skips the project checkout step until you configure one. The
worked example throughout this README is
[qualcomm-linux/meta-ai](https://github.com/qualcomm-linux/meta-ai) (branch
`wrynose`, kas config `kas/base.yml:kas/qemuarm64.yml`) — the layer set the
tool has actually been exercised against end to end — and `smoketest` will
offer to use it for a single, ephemeral run (never persisted, removed again
afterward) if you run it with nothing configured at all.

## Why this exists

macOS is not a supported `kas-container` host. kas-container assumes Linux
with Docker or Podman: it detects its engine by grepping `docker -v` for
`^Docker`, and it passes `docker run` flags (`--privileged`,
`--security-opt`, `--userns`, `--group-add`) that Apple's `container`
(v1.1.0) does not implement. Apple's runtime is a solid Linux VM for Apple
silicon; its CLI is not Docker's. mackas bridges the two without touching
kas.

### Zero patches to kas — the central design goal

**mackas does not patch, fork, or vendor kas. Not one line.** It downloads a
pinned, sha256-verified `kas-container` release (currently v5.4) and runs it
unmodified. All adaptation lives in two places: `bin/docker` (the
compatibility shim) and the environment plus kas fragment that `mackas setup`
generates. The payoff: upstream kas releases are tracked for free, and the
adaptation surface stays small enough to reason about.

> **If a kas patch ever looks necessary, that is a bug in the shim.** Fix the
> shim, the generated environment, or the config. A local kas checkout for
> reading and debugging is fine
> ([testing.md](docs/testing.md#debugging-against-upstream-kas)); patching it
> is not.

## Quick start

`MACKAS_ROOT` has no baked-in default. Leave it unset and every command falls
back to the current directory, with a loud warning — fine for a quick look,
not for a real build. Set it properly in `~/.mackas.conf` (`echo
'MACKAS_ROOT=/Volumes/oe' >> ~/.mackas.conf`) or pass it per-invocation with
`--set MACKAS_ROOT=...`. It must be a directory on a case-sensitive volume —
[see below](#configuration) for how to make one — and on a case-insensitive
root `setup` offers to mount a case-sensitive workspace image at `work/` and
**refuses to proceed** if you decline, rather than finish "Done" on a root
that would corrupt the first build.

```sh
./mackas check              # feasibility report. Changes nothing. This is the default.
./mackas --dry-run setup    # see exactly what setup would do.
./mackas setup              # do it. Idempotent; re-runnable.
source ~/oe/env.sh          # setup generates this and prints the real path
./mackas smoketest          # parse-only, then the kas config's own default build
```

`./mackas` with no arguments does `check`, which touches nothing.

`setup` generates `env.sh` and prints its path. Source it in every shell you
build from — the later commands assume you have. It puts the `docker` shim
ahead of `/usr/local/bin` on `PATH` and exports the `KAS_*` variables
kas-container reads, plus `BB_NUMBER_THREADS`/`PARALLEL_MAKE`. It
deliberately does **not** export `KAS_BUILD_DIR`, `DL_DIR` or `SSTATE_DIR` —
those would make kas bind-mount an APFS directory over the ext4 volumes
([why](docs/architecture.md#how-they-get-mounted-and-why-kas_build_dir-must-stay-unset)).
It lives at `~/oe/env.sh` once `setup` has made the short symlink, or in
`MACKAS_ROOT` if you set `MACKAS_SHORT_LINK=`; `./mackas status` prints
where.

Requirements: Apple silicon, Apple `container` v1.1.0
(`brew install container`), and a case-sensitive filesystem with room for the
build.

### Driving kas directly

`mackas smoketest` and `mackas shell` are wrappers; underneath this is ordinary
kas. Once `env.sh` is sourced, run kas yourself from the **work directory**
(the parent of the layer checkouts, as upstream kas expects — the config path
is relative to it):

```sh
source ~/oe/env.sh
cd "$MACKAS_BASE/work"          # ~/oe/work — meta-ai and the other layers live here

# build a target
kas-container build meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml --target tensorflow-lite

# or get a shell and drive bitbake yourself
kas-container shell meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml -c 'bitbake tensorflow-lite'
kas-container shell meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml -c 'bitbake -c menuconfig virtual/kernel'
kas-container shell meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml   # interactive
```

Compose `:kas/macos-local.yml` onto the end for the tuning fragment
(parallelism, `BB_DISKMON_DIRS`, `BB_HASHSERVE_DB_DIR`, mirrors) that mackas
passes for you when it drives kas.

> **`kas-container` here is a shell function, not the program on your
> `PATH`.** `env.sh` defines it to supply `--runtime-args` (the ext4 volumes
> and CPU/memory limits), point `GITCONFIG_FILE` at the generated
> `safe.directory` config, and blank `KAS_BUILD_DIR`/`DL_DIR`/`SSTATE_DIR`.
> None of that is optional — see
> [architecture.md](docs/architecture.md#the-ext4-volumes).
>
> `command kas-container`, an absolute path, or an unsourced shell bypasses
> the function and builds wrong: no volumes, Apple's default 4 CPUs / 1 GB —
> and, with a pipx or pip kas on `PATH`, possibly a different kas release
> than the 5.4 mackas pins. `mackas check` reports which `kas-container`
> wins.

## Files

| File | What it is |
|---|---|
| `mackas` | The whole tool. bash 3.2 compatible (macOS stock bash). |
| `bin/docker` | The `docker` → Apple `container` shim. Installed to `$MACKAS_ROOT/bin/docker` by `setup`. |
| `mackas.conf.example` | Annotated config. Copy, edit, drop somewhere on the search path. |
| `mirror-server/mackas-mirrord` | The HTTP mirror server. **Optional.** Single file, Python 3.7+, stdlib only — scp it to a mirror host, or run it locally. See [storage.md](docs/storage.md#http-mirrors--optional-and-not-just-an-nfs-bridge). |
| `mirror-server/mackas-mirrord.service` | Hardened systemd unit for it (Debian 13). |
| `mirror-server/mackas-mirrord.conf.example` | Annotated config for it. |
| `tests/` | bats test suite. See [testing.md](docs/testing.md). |
| `run-tests.sh`, `Makefile` | Test entry points (`./run-tests.sh` or `make test`). |
| `COPYING` | GPLv3. |

Plus two files `setup` **generates** rather than ships:

| Generated file | What it is |
|---|---|
| `$MACKAS_BASE/env.sh` | The environment to `source` before building — shim on `PATH`, `KAS_*`, `BB_NUMBER_THREADS`/`PARALLEL_MAKE`, and a `kas-container` wrapper that supplies the volumes and limits. Defaults to `~/oe/env.sh`. |
| `$MACKAS_BASE/gitconfig` | Forwarded into the container as `GITCONFIG_FILE` so git can operate on `/repo` despite the virtiofs ownership quirk — see [architecture.md](docs/architecture.md#git-dubious-ownership--the-blocker). Never written over a `GITCONFIG_FILE` you already export yourself. |

## Commands

| Command | Does |
|---|---|
| `check` | Preflight only. PASS/WARN/FAIL, each with the remediation command. **Default.** |
| `setup` | Full setup, idempotent. Safe to re-run after a crash or Ctrl-C. Takes an optional root path and `--tmpdir-size`/`--sstate-size`/`--downloads-size`; asks interactively for whichever is still unconfigured. Skips the project checkout step if none is configured. |
| `smoketest` | The validation ladder (see below). Offers the meta-ai example, for one ephemeral run only, if no project is configured at all. |
| `status` | Every setting in effect, every derived path, what exists on disk. |
| `shell` | `kas shell` for the project's kas config. |
| `retrieve` | Copy build outputs (`buildstats`/`logs`/`deploy`) out of the ext4 TMPDIR volume, where macOS cannot see them. |
| `buildstats` | Work with buildstats already retrieved, e.g. `buildstats analyze`. |
| `clean` | Drop the TMPDIR volume (recreated empty). Keeps the downloads/sstate volumes and the checkout. |
| `destroy` | Remove all four volumes (including a rarely-present legacy one), `$MACKAS_ROOT`, the symlink. Makes you type `DESTROY`. |
| `volume` | Manage the ext4 volumes: `list`, `fstrim` (reclaim disk from a sparse image; `all`/`--all`/`-a` for every active volume), `duplicate`, `destroy` one or every volume (`--all`/`-a`), `move` one to another disk, `recover` a hand-moved one. |
| `set` / `get` / `unset` | Persist, read back, or remove one setting in the config file — see [Configuration](#configuration). |

Options: `--config FILE`, `--set NAME=VALUE`, `--dry-run`, `-y/--yes` (or
`-f/--force`), `-v/--verbose`, `--version`, `--help`.

### The smoketest ladder

`mackas smoketest` runs rung 1 (universal) then either one build rung per
target in `MACKAS_SMOKETEST_TARGETS`, or, when that list is empty (the
built-in default), a single build rung with no `--target` at all, stopping on
the first failure:

1. `bitbake -p` — parse only. Proves all layers fetched and parse. Always run.
2…n. `bitbake <target>` for each target in `MACKAS_SMOKETEST_TARGETS` — or, if
the list is empty, one plain `kas build` with no target, so kas/bitbake builds
whatever default target the kas config itself names.

`MACKAS_SMOKETEST_TARGETS` is empty by default: the ladder exercises exactly
what the kas config says to build, nothing project-specific baked in. Set your
own project's targets to go further than that default (order the list
smallest-first so failures stay cheap and specific), or use `bash` as a
trivial fallback target if your kas config has no sensible bare default of its
own. `mackas.conf.example` ships meta-ai's own ladder, commented out, as a
worked example — `flatbuffers-tflite-native` (smallest native, proves the
toolchain), `flatbuffers-tflite` (same recipe cross-compiled), then
`tensorflow-lite` + `llama-cpp` (its real targets, **hours** cold).

Each rung streams to `$MACKAS_ROOT/logs/` and stops the ladder on failure.
See [testing.md](docs/testing.md#the-smoketest-ladder) for what it composes
and why.

### Getting build outputs off the volume

`TMPDIR` is inside the `oe-build-tmp` ext4 image, so `tmp/buildstats`,
`tmp/log` and `tmp/deploy` are invisible from macOS. `mackas retrieve` copies
them out with a throwaway container; `mackas buildstats analyze` then
summarises what was fetched:

```sh
./mackas retrieve buildstats                    # -> $MACKAS_BASE/artifacts/
./mackas retrieve buildstats logs deploy         # also tmp/log and tmp/deploy
./mackas retrieve buildstats --dest ~/out        # elsewhere
./mackas buildstats analyze                      # summarise what's in artifacts/buildstats
./mackas buildstats analyze ~/out/buildstats      # summarise an explicit path
```

`deploy` (the images and ipks) can be tens of GB. `buildstats analyze` runs
[`tools/mackas-buildstats-analyze`](tools/mackas-buildstats-analyze) over the
path given (or the default `retrieve` destination).

Because only **one VM may hold an ext4 image at a time**, `retrieve` refuses
while a build (`smoketest`/`shell`) still has the volume attached — stop it first.
That constraint is also why the copy runs through a container rather than a
second mount ([TODO.md](TODO.md) item 5).

### Managing the volumes

`mackas volume` operates on the ext4 container volumes directly.

```sh
./mackas volume list                       # every volume: cap, on-disk cost, in-use
./mackas volume fstrim oe-build-tmp         # reclaim host disk from the sparse image
./mackas volume fstrim all                  # the three mackas volumes, skipping busy ones
./mackas volume duplicate oe-build-sstate sstate-backup   # sstate-backup is a new NAME you choose, an APFS copy-on-write clone of oe-build-sstate
./mackas volume destroy sstate-backup       # remove ONE volume
./mackas volume move oe-build-tmp /Volumes/Fast/oe   # relocate one image to another disk
```

A sparse ext4 image only ever grows: deleting files inside the guest never
shrinks `volume.img`. `volume list`'s **on-disk** column is where you see one
that has ratcheted up, and `volume fstrim` hands the freed space back to the
host — it runs guest `fstrim`, whose discards the hypervisor turns into host
hole-punches ([storage.md](docs/storage.md#reclaiming-disk-from-a-grown-volume-mackas-volume-fstrim)).
`duplicate` is a near-free CoW clone (it shares blocks with its source until
written). All three refuse a volume a running build still holds — the
**one-VM rule** — and for `duplicate` that guard is on the *source*, since
cloning a live image is inconsistent. `volume destroy` removes one arbitrary
volume; the top-level `destroy` removes all three plus `$MACKAS_ROOT` and the
symlink.

`volume move` relocates a single volume's image to another directory (put a
big TMPDIR on a roomier disk while sstate stays put). It leaves a symlink where
the runtime expects the volume, so nothing else needs reconfiguring; `status`
and `volume list` resolve and report the real location. It refuses a volume
that is in use. If you ever move an image by hand and the symlink goes stale,
`mackas volume recover` finds it again with Spotlight and offers to re-point.

## Configuration

Precedence, lowest to highest:

```
built-in defaults  ->  config file  ->  environment  ->  command-line flags
```

Config file, first match wins:

1. `$MACKAS_CONF`
2. `~/.config/mackas/config`
3. `~/.mackas.conf`

`./mackas.conf` is deliberately **not** searched. The config is sourced as
shell, so a cwd config would let any untrusted tree you `cd` into (an unpacked
tarball, a cloned repo) run code the moment you invoke `mackas`. To use a
per-project config, name it out loud: `mackas --config ./mackas.conf ...`.

It is sourced as shell, so keep it to assignments. Every setting is also an
environment variable of the same name, overridable per-invocation with
`--set`:

```sh
MACKAS_MEMORY=48g ./mackas setup         # via the environment
./mackas --set MACKAS_MEMORY=48g setup   # via a flag; beats the environment
```

`--set` only affects the one command it rides along with. For a *persistent*
override — written into the config file so every future invocation picks it
up too — use `mackas set`/`get`/`unset` instead:

```sh
./mackas set MACKAS_MEMORY 48g   # persist it
./mackas get MACKAS_MEMORY       # 48g -- resolved through the full precedence chain
./mackas unset MACKAS_MEMORY     # remove it again; a no-op if never persisted
```

These operate on whatever config file the invocation is actually pointed at
(`--config`/`$MACKAS_CONF`/the default search path above), including one that
does not exist yet — `mackas --config ~/other-project.conf set ...` is how
you bootstrap a new per-project config, which matters if you switch between
several projects' configs in a day.

`./mackas status` prints what is in effect and which config file (if any) was
used. `mackas.conf.example` has the full annotated list.

| Setting | Default | Meaning |
|---|---|---|
| `MACKAS_ROOT` | *(no baked-in default; falls back to `$PWD` with a warning)* | Where everything lives. Must be a dir on a case-sensitive volume — `setup` refuses otherwise; see below. |
| `MACKAS_SHORT_LINK` | `$HOME/oe` | Short, space-free symlink to `MACKAS_ROOT`. |
| `MACKAS_VOLUME_NAME` | `oe-build` | Stem for the three ext4 volumes (`-tmp`, `-dl`, `-sstate`). Must be space-free. |
| `MACKAS_VOLUME_SIZE_TMP` | `120G` | Cap on the TMPDIR volume. |
| `MACKAS_VOLUME_SIZE_DL` | `40G` | Cap on the downloads volume. |
| `MACKAS_VOLUME_SIZE_SSTATE` | `40G` | Cap on the sstate volume. |
| `MACKAS_RELOCATE_VOLUMES` | `1` | Symlink container's volume dir onto the SSD. |
| `KAS_IMAGE` | `ghcr.io/siemens/kas/kas:5.4` | kas container image. |
| `MACKAS_CPUS` | physical cores − 2 | Passed as `-c`. |
| `MACKAS_MEMORY` | ⅔ of host RAM | Passed as `-m`. |
| `MACKAS_PROJECT_URL` | *(no baked-in default)* | Repo `setup` clones. With this empty, `setup` skips the checkout step entirely; `smoketest` offers qualcomm-linux/meta-ai for one ephemeral run instead. |
| `MACKAS_PROJECT_BRANCH` | *(empty)* | Branch to check out. |
| `MACKAS_PROJECT_DIR` | *(empty)* | Checkout name under `work/`; also the cwd kas runs in. |
| `MACKAS_KAS_CONFIG` | *(empty)* | kas files to compose (checkout-relative). `macos-local.yml` is appended. |
| `MACKAS_SMOKETEST_TARGETS` | *(empty)* | Space-separated smoketest build targets after the parse rung. Empty means one build rung with no `--target`, so kas builds its own default; see [mackas.conf.example](mackas.conf.example) for meta-ai's ladder as an example override. |
| `MACKAS_OVERHEAD` | `1` | Sample host CPU-seconds and peak RSS per smoketest rung and append it to the rung log. Set `0` to disable. See [performance.md](docs/performance.md) for what a build actually costs the Mac (measured). |
| `MACKAS_OVERHEAD_INTERVAL` | `5` | Seconds between host-overhead samples. Spikes shorter than this are invisible. |
| `MACKAS_FSTRIM_AUTO` | `1` | `fstrim` the three volumes before and after every kas run, so the sparse images don't ratchet up. Set `0` to disable. |
| `MACKAS_USE_HTTP_MIRRORS` | `0` | Opt in to HTTP mirrors. **Optional** — see [storage.md](docs/storage.md). |
| `MACKAS_USE_NFS_MIRRORS` | `0` | Opt in to NFS mirrors. **Optional**, and not the recommended mirror path — see [storage.md](docs/storage.md). |
| `MACKAS_FREE_SPACE_MARGIN_GB` | `20` | Headroom `check` insists on. |

`MACKAS_ROOT` has no baked-in default, deliberately: OE needs a case-sensitive
filesystem, and a stock Mac's boot volume — so `$HOME` — is case-insensitive
APFS, so there is no `$HOME`-based default that would actually work. Leave it
unset and every command falls back to the current directory (with a red
warning) rather than refuse outright — useful for a quick look, not for a real
build. `setup` goes further: if `work/` (the layer checkouts — the only part
that needs case sensitivity) probes case-insensitive, it offers to create a
case-sensitive APFS sparse image (`MACKAS_WORKSPACE_SIZE`, default `40G`,
sparse) and mount it at `work/`, preserving any existing checkout; decline,
and it **refuses to proceed** (`die`, exit 1) rather than finish "Done" on a
root that would corrupt the layer checkouts on the very first build. (That
gate is `MACKAS_REQUIRE_CASE_SENSITIVE=1` by default; set it to `0` only if
the case-sensitive parts genuinely live elsewhere.)

Make a case-sensitive volume once and point `MACKAS_ROOT` at a directory on
it:

```sh
diskutil apfs addVolume <disk> "Case-sensitive APFS" oe   # see: diskutil list
# or a case-sensitive sparse image (one file, lives anywhere):
hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size 200g -volname oe ~/oe.sparseimage
hdiutil attach ~/oe.sparseimage
```

A space in the volume name is fully supported (the short symlink and careful
quoting handle it); `check` still warns, since some recipes mishandle spaces.

`MACKAS_CONTAINER_BIN` (read by `bin/docker`) overrides which `container`
binary the shim calls; it exists so the test suite can point the shim at a
mock.

### Env prefix: `MACKAS_*`

This project was previously called `oe-container` and used `OE_*` settings;
**those names are gone**, not aliased — `OE_*` collides with OpenEmbedded's
own namespace, precisely the namespace this tool builds inside. Rename
`OE_FOO` to `MACKAS_FOO` in an old config. The one exception the shim keeps
is `DOCKER_SHIM_CONTAINER_BIN`, a deprecated alias for
`MACKAS_CONTAINER_BIN`.

## Documentation

The design decisions, the negative results, and the reasons behind both:

| Page | What is in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The `docker` shim; git "dubious ownership" (the blocker that stood between a failing and a passing parse); the ext4 volumes and how they actually get mounted; the short symlink; resources; case sensitivity. |
| [docs/storage.md](docs/storage.md) | What lives where and why; HTTP mirrors and their client config; serving local files instead of bind-mounting them; NFS inside the container (a dead end); disk images on network shares; Time Machine. |
| [docs/mirror-server.md](docs/mirror-server.md) | `mackas-mirrord`'s threat model, and the bugs a review found in it. |
| [docs/performance.md](docs/performance.md) | What a build costs the Mac, measured: host CPU/RSS overhead, local SSD vs a network share, sstate economics. |
| [docs/homebrew.md](docs/homebrew.md) | What actually depends on Homebrew, and what it would take to stop. |
| [docs/testing.md](docs/testing.md) | The test suite and what it deliberately does not cover; debugging against upstream kas; recovering from a crash. |
| [docs/security.md](docs/security.md) | Security posture: dependency surface, isolation, supply-chain integrity, CRA readiness. |
| [TODO.md](TODO.md) | Every known gap, prioritised. |

## Known limitations

- `--privileged`, `--device`, `--network host`, `--security-opt`,
  `--group-add` and `--userns` have no Apple `container` equivalent — the
  shim drops the harmless ones and refuses the rest. So kas's **Isar mode and
  rootless-Docker paths are not supported**: plain OpenEmbedded only, which
  is what meta-ai needs.
- **No NFS client in the guest kernel**, so mounting NFS inside the container
  is [a dead end](docs/storage.md#nfs-inside-the-container--a-dead-end).
- `container` v1.1.0 has no `container system property set`, so per-container
  cpu/memory must be passed on every run.
- **A container volume cannot be grown after creation.** Getting
  `MACKAS_VOLUME_SIZE_TMP`/`_DL`/`_SSTATE` badly wrong means deleting that
  volume and recreating it. Splitting TMPDIR from the caches limits the blast
  radius: resizing TMPDIR no longer costs you sstate.
- **`DL_DIR`/`SSTATE_DIR` live inside ext4 images and are not visible from
  macOS** — the deliberate cost of correct filesystem semantics. Read them
  via `mackas shell`, or serve them with `mackas-mirrord`.
- The kernel may need `container system kernel set --recommended --force`
  once after install. `check` probes this by booting a throwaway container.
- **In an unsourced shell, a kas-container installed by other means wins.**
  `env.sh`'s shell function shadows `PATH` only when sourced; a bare
  `kas-container` in a fresh shell runs whatever pipx or pip put on `PATH`
  (typically `~/.local/bin/kas-container`) — silently, with no volumes,
  Apple's 4 CPUs / 1 GB, and whatever kas version that install happens to
  be. `check` reports which one wins.

## Status

What has and has not been verified. See [TODO.md](TODO.md) for the full list.

**The plumbing is verified.** A real `kas-container checkout` ran end-to-end,
git clone over HTTPS worked, and files landed on the host owned by the
invoking user. `container volume create` produces a genuine sparse ext4 with
working hardlinks. `setup` has run for real — including into a temporary
`MACKAS_ROOT` *containing spaces* — producing the volumes, checkout,
`kas-container` and `env.sh` that `mackas status` reports.

**The build is verified too — by observation, not inference.** All of this
ran on macOS/aarch64 via Apple `container`:

- **`bitbake -p`**: 2006 recipes parse, 0 errors — after four fixes, all now
  encoded in `mackas`, of which git's ["dubious
  ownership"](docs/architecture.md#git-dubious-ownership--the-blocker)
  refusal on `/repo` was the actual blocker.
- **`bitbake bash`, from scratch**: `Attempted 4491 tasks of which 0 didn't
  need to be rerun and all succeeded.` 1938.9 s wall (32.3 min), 64.3% CPU.
- **`bitbake tensorflow-lite`**, a real meta-ai target: `Attempted 4716 tasks
  of which 4468 didn't need to be rerun and all succeeded` — **sstate reuse
  across builds works**. Real artifacts, listed inside the container:
  `/build/tmp/deploy/ipk/cortexa57/tensorflow-lite-tools_2.20.0-r0_cortexa57.ipk`.
- **`bitbake llama-cpp`**, the last of meta-ai's smoketest targets: `Attempted
  1371 tasks of which 1349 didn't need to be rerun and all succeeded` — so the
  whole meta-ai ladder (`bash`, `tensorflow-lite`, `llama-cpp`) is green on
  macOS/aarch64.
- **`kas-container shell` via `env.sh`**: `/dev/vdc on /build type ext4
  (rw,relatime)`, `nproc` 19 (18+1) — the volumes and limits reach a real
  container.

So "no aarch64-host blockers" rests on a completed build of a real target,
not on the absence of restrictions in the recipes.

From `bash`'s buildstats: **14.45× parallelism** (28,016 s CPU / 1939 s wall)
against 18 allocated CPUs, and **78.9 GB written vs 4.6 GB read** — which is
why TMPDIR is on local ext4. The same `do_configure` parallelism problem shows
up again, measured in more detail, in
[docs/performance.md](docs/performance.md).

**The mirror server** works locally: a real process, real HTTP, auth
accepted and rejected, traversal and symlink escapes refused,
`Range`/`If-Modified-Since`/405/404 correct, TLS 1.2+ against an
`openssl`-generated cert, `~/.netrc` auth, clean `SIGTERM`. An independent
review then found real, proven exploits — TOCTOU escape via an intermediate
directory, header-memory flood, a TLS handshake wedging the accept loop, CL.0
smuggling, PBKDF2 as a CPU amplifier — all fixed;
[docs/mirror-server.md](docs/mirror-server.md) describes the code as it now
stands.

A real `container run` alpine **can** reach an HTTP server on the Mac itself,
via both the vmnet gateway (`192.168.64.1`) and the Mac's LAN IP, with Basic
auth
([details](docs/storage.md#serving-local-files-instead-of-bind-mounting-them)).
That proves container-to-Mac reachability only, not container-to-LAN-host.

**Still not verified:**

- The NFS mirror path, end to end.
- The mirror server **against a real mirror host**: it has never been pointed
  at a populated NFS mount, and no build has ever consumed it. Whether the
  container can reach such a host over the vmnet NAT is unconfirmed.
- That `BB_DISKMON_DIRS`'s HALT actually fires at the 2 GiB / 100k inode
  thresholds. The syntax is confirmed accepted by a real bitbake; the trigger
  needs a volume driven near full, which no run has done.

## Licence

GPLv3-or-later. See [COPYING](COPYING) for the full text.

Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>

mackas is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
