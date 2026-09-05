# mackas

![mackas in action](docs/demo.svg)

**mac** + **kas**. Run [kas-container](https://github.com/siemens/kas)
OpenEmbedded builds on macOS, on Apple's native `container` runtime. No Docker
Desktop, no Lima, no Colima.

The project to build is configuration (`MACKAS_PROJECT_URL` / `_BRANCH` /
`_DIR` and `MACKAS_KAS_CONFIG`); there is no built-in default project.
`setup` does its whole job — volumes, kas-container, the shim, gitconfig —
with none of it set, skipping only the project checkout. The worked example
throughout is
[qualcomm-linux/meta-ai](https://github.com/qualcomm-linux/meta-ai) (branch
`wrynose`, kas config `kas/base.yml:kas/qemuarm64.yml`), the layer set the
tool is exercised against end to end; `smoketest` offers it for a single
ephemeral run (never persisted, removed afterward) when nothing is configured.

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
pinned, sha256-verified `kas-container` release (currently v5.5) and runs it
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

Requirements: Apple silicon, macOS 26 (Tahoe) or newer, Apple `container`
v1.0.0 or newer (`brew install container`) — v1.1.0 is what mackas is
tested against, and `check` warns below it — and a case-sensitive filesystem
with room for the build.

`MACKAS_ROOT` has no baked-in default. Leave it unset and every command falls
back to the current directory, with a loud warning — fine for a quick look,
not for a real build. Set it in `~/.mackas.conf` (`echo
'MACKAS_ROOT=/Volumes/oe' >> ~/.mackas.conf`) or per-invocation with
`--set MACKAS_ROOT=...`. It must be a directory on a case-sensitive volume —
[see Configuration](#configuration) for how to make one and what `setup`
does (offer a workspace image, or refuse) on a case-insensitive root.

```sh
./mackas check              # feasibility report. Changes nothing. This is the default.
./mackas --dry-run setup    # see exactly what setup would do.
./mackas setup              # do it. Idempotent; re-runnable.
source ~/oe/env.sh          # setup generates this and prints the real path
./mackas smoketest          # parse-only, then the kas config's own default build
```

`setup` generates `env.sh` and prints its path. Source it in every shell you
build from — the later commands assume you have. It puts the `docker` shim
ahead of `/usr/local/bin` on `PATH` and exports the `KAS_*` variables
kas-container reads, plus `BB_NUMBER_THREADS`/`PARALLEL_MAKE`. It
deliberately does **not** export `KAS_BUILD_DIR`, `DL_DIR` or `SSTATE_DIR` —
those would make kas bind-mount an APFS directory over the ext4 volumes
([why](docs/architecture.md#how-they-get-mounted-and-why-kas_build_dir-must-stay-unset)).
It lives at `~/oe/env.sh` once `setup` has made the short symlink, or in
`MACKAS_ROOT` if you set `MACKAS_SHORT_LINK=`; `./mackas status` prints where.
With a project selected (`--project NAME` / `$MACKAS_PROJECT_SELECT`), it is
`env-NAME.sh` instead, so two pinned projects on one `MACKAS_ROOT` never
share a generated file; that file also exports `MACKAS_PROJECT_SELECT` for
you, guarded the same way `GITCONFIG_FILE` is — a value your shell already
has always wins over the one this file was generated for.

### Directory layout

Everything lives under `MACKAS_ROOT` (reached through the short-link alias
`MACKAS_BASE`, normally `~/oe`, when one resolves):

```
$MACKAS_ROOT/
├── bin/          the docker->container shim, kas-container, GNU realpath
├── kas/          the canonical generated tuning fragment (macos.yml;
│                 macos-NAME.yml once a project is selected)
├── logs/         smoketest/build logs (logs/NAME/ once a project is
│                 selected, so two pinned projects never share one)
├── env.sh        generated; source this
├── gitconfig     generated; forwarded as GITCONFIG_FILE
└── work/         <- every layer checkout lives HERE, as a sibling
    ├── meta-angstrom/
    ├── meta-openembedded/
    └── ...
```

**`work/` is the one directory that matters for multi-layer work.** It is
what `KAS_WORK_DIR` is set to, and kas-container bind-mounts it whole into
the container — any checkout under it, whether `setup` cloned it or you put
it there, is visible to kas and reusable across builds with nothing
re-cloned. `bin/`, `kas/` and `logs/` do not participate; only `work/` is
what kas sees. A real multi-layer BSP — a dozen `meta-*` repos, not just the
single project `setup` clones — goes under `work/` as siblings; see
[Driving kas directly](#driving-kas-directly).

Selecting a project does not move anything already sitting flat under
`logs/` from before a project was ever selected on this root — an older
`dump-*.yml` or `smoketest-*.log` stays exactly where it was written.

## Commands

| Command | Does |
|---|---|
| `check` | Preflight only. PASS/WARN/FAIL, each with the remediation command. **Default.** |
| `setup` | Full setup, idempotent. Safe to re-run after a crash or Ctrl-C. Takes an optional root path and `--tmpdir-size`/`--sstate-size`/`--downloads-size`; asks interactively for whichever is still unconfigured. |
| `adopt` | Bring a `MACKAS_ROOT` set up by another Mac back to a working build here — see [below](#adopting-a-root-from-another-mac). |
| `project add` | Pin a project workspace under *this* Mac's own root — the in-root sibling of `adopt` — see [below](#pinning-a-project-workspace). |
| `smoketest` | The validation ladder (see below). |
| `status` | Every setting in effect, every derived path, what exists on disk. |
| `shell` | `kas shell` for the project's kas config. |
| `exec` | `exec CMD` runs a one-off read-only command against the checkout with kas's repo-mutating setup steps always skipped — see [below](#driving-kas-directly). `mackas exec --help`. |
| `retrieve` | Copy build outputs (`buildstats`/`logs`/`deploy`/`buildhistory`/`sbom`) out of the ext4 TMPDIR volume, where macOS cannot see them. |
| `buildstats` | `buildstats analyze [PATH]` summarises the newest retrieved build's wall time/parallelism/io and renders bootchart SVGs. |
| `buildhistory` | `buildhistory analyze [PATH] [--from REV] [--to REV] [--detail] [--json]` summarises what changed between two builds — recipes added/removed/upgraded, the biggest PKGSIZE movers, per-image size/content deltas. `mackas buildhistory --help`. |
| `sstate` | `sstate prune --older-than N[d]` deletes sstate objects bitbake hasn't reused in N days; `sstate push` publishes new ones to a mirror over rsync/ssh. `mackas sstate --help`. |
| `monitor` | `monitor [--port N] [--once] [--notify]` prints live bitbake progress from a build started with `MACKAS_MONITOR=1`. Exits 0 on a build that succeeded, 1 on one that failed, 2 when no bridge is reachable — a usable scripted probe. |
| `clean` | Drop the TMPDIR volume (recreated empty; also drops deploy, buildhistory and conf/) and clear the log dir — the selected project's own `logs/NAME/`, or, with none selected, the whole flat `logs/` including every `logs/NAME/` under it. Keeps the downloads/sstate volumes and the checkout. Or one narrower target: `clean tmp+deploy` (keeps buildhistory/conf), `clean downloads`, `clean sstate` — `mackas clean --help`. `downloads`/`sstate` refuse a volume another pinned project shares (see [below](#pinning-a-project-workspace)). |
| `destroy` | Remove all four volumes (including a rarely-present legacy one), `$MACKAS_ROOT`, the symlink. Makes you type `DESTROY`. Refuses a downloads/sstate volume another pinned project shares. |
| `volume` | Manage the ext4 volumes: `list`, `fstrim` (`all`/`--all`/`-a` for every active volume), `duplicate`, `destroy` one or all (`--all`/`-a`), `move`, `resize` (grow), `fsck` (repair ext4 corruption after a crash), `recover`. |
| `set` / `get` / `unset` | Persist, read back, or remove one setting in the config file — see [Configuration](#configuration). |
| `projects` | List the pinned per-project configs under `~/.config/mackas/projects/` that `--project` selects between, by *grepping* each one — never sourcing it. (The plural, read-only sibling of `project add`, which creates one.) |
| `runtime-args` | Plumbing: prints the effective `--runtime-args` string. The generated `kas-container` wrapper calls it itself on every hand-typed invocation (with `--require-volumes-free`, which applies the one-VM rule first and prints nothing if a volume is held); you rarely type it, except to check what a setting did. |
| `lock` | `kas lock` against the project's kas config — pins every declared repo to its exact current commit, written into the checkout. |
| `dump` | `kas dump --skip repos_checkout --skip repos_apply_patches --resolve-env --resolve-local --resolve-refs` — saves the fully-resolved config to `$MACKAS_LOGS/dump-<timestamp>.yml` (`logs/NAME/` once a project is selected), a reproducibility record next to a build's own logs. The two `--skip` flags keep it from resetting a clean sibling repo the way resolving a floating branch/tag otherwise would. |

Options: `--config FILE`, `--project NAME`, `--set NAME=VALUE`, `--dry-run`,
`-y/--yes` (or `-f/--force`), `-v/--verbose`, `--version`, `--help`.

### The smoketest ladder

Rung 1 is `bitbake -p` — parse only, proves all layers fetched and parse.
Then one build rung per target in `MACKAS_SMOKETEST_TARGETS`, or, when that
list is empty (the default), a single plain `kas build` with no `--target`,
so bitbake builds whatever default the kas config itself names — nothing
project-specific baked in. Set your own targets to go further, ordered
smallest-first so failures stay cheap and specific; `bash` is a trivial
fallback if your kas config has no sensible bare default.
[mackas.conf.example](mackas.conf.example) ships meta-ai's ladder, commented
out, as a worked example (smallest native recipe → same recipe
cross-compiled → the real targets, **hours** cold). Each rung streams to
`$MACKAS_ROOT/logs/` (`logs/NAME/` once a project is selected) and stops the
ladder on failure. See
[testing.md](docs/testing.md#the-smoketest-ladder). `smoketest` and `shell`
obey the **one-VM rule** like everything else: if another build already holds
one of the three volumes, they refuse by name up front instead of letting
Virtualization.framework reject the second attach mid-run.

### Getting build outputs off the volume

`TMPDIR` is inside the `oe-build-tmp` ext4 image, so `tmp/buildstats`,
`tmp/log` and `tmp/deploy` — and `buildhistory`, one level up — are invisible
from macOS. `mackas retrieve` copies them out with a throwaway container:

```sh
./mackas retrieve buildstats                # -> $MACKAS_BASE/artifacts/
./mackas retrieve buildstats logs deploy    # also tmp/log and tmp/deploy; deploy can be tens of GB
./mackas retrieve deploy images [MACHINE]   # just the boot images for one board, not the whole feed
./mackas retrieve buildhistory              # what each build produced, if the project inherits it
./mackas retrieve buildstats --dest ~/out   # elsewhere
./mackas buildstats analyze [PATH]          # summarise what was fetched
./mackas buildhistory analyze [PATH]        # what changed between two builds
```

Every object resolves its real guest path from bitbake itself
(`BUILDSTATS_BASE`, `LOG_DIR`, `DEPLOY_DIR`, `BUILDHISTORY_DIR`), never from
the textbook layout — a distro is free to move any of them, and Angstrom moves
`DEPLOY_DIR`. `buildhistory` in particular is **not** under `tmp/`: its class
default is `${TOPDIR}/buildhistory`, which inside the container is
`/build/buildhistory`. Nothing writes it unless the project inherits the class
(`INHERIT += "buildhistory"` in your kas config's `local_conf_header` or
`conf/local.conf`), and `retrieve buildhistory` says exactly that when it finds
nothing, instead of reporting a missing directory. Because that default sits in
the same volume bare `mackas clean` drops wholesale, retrieve it before
cleaning, point `BUILDHISTORY_DIR` somewhere that survives, or use
`mackas clean tmp+deploy` instead of bare `clean` — it keeps buildhistory
(and conf/) intact, clearing only TMPDIR and DEPLOY_DIR.

`buildhistory analyze` reads the retrieved tree with host `git` (`git diff
--name-status` plus one `git cat-file --batch`, no container) and prints a
rollup: recipes added/removed/upgraded, the biggest PKGSIZE movers (listed
past >1% or >64 KiB, everything smaller still counted into the net total),
and per-image IMAGESIZE/installed-package deltas. `--detail` additionally
runs openembedded-core's own `scripts/buildhistory-diff` in a throwaway
kas-image container for the per-field detail (`RDEPENDS` version-constraint
changes, unified diffs of `pkg_postinst`, ...) — best-effort, needs a
checkout under `$MACKAS_ROOT/work`. `--json` emits the summary as JSON
instead (refuses `--detail`). `retrieve buildhistory` runs the summary layer
automatically on what it just copied; re-run it later without re-copying
with `mackas buildhistory analyze`. Needs `BUILDHISTORY_COMMIT = "1"` (most
projects' default) for there to be build-to-build history to diff — with it
off, this shows the current state instead (no comparison).

`buildstats analyze` runs
[`tools/mackas-buildstats-analyze`](tools/mackas-buildstats-analyze) over
the newest build in the path (default: the `retrieve` destination), then
renders a pybootchartgui bootchart SVG per build not already charted — in a
throwaway kas-image container (pybootchartgui needs pycairo, which the Mac's
own Python lacks), best-effort, skipped quietly with no checkout yet. Each
`retrieve buildstats` lands in its own timestamped subdirectory, so
retrievals never merge — important for a project whose `BUILDNAME` doesn't
vary per build, where bitbake never resets `tmp/buildstats` between builds
([storage.md](docs/storage.md#buildstats-and-a-constant-buildname),
`MACKAS_BUILDSTATS_ACCUMULATE`). Because only **one VM may hold an ext4
image at a time**, `retrieve` refuses while a build still has the volume
attached — stop it first. That constraint is also why the copy runs through
a container rather than a second mount.

### Managing the volumes

```sh
./mackas volume list                        # every volume: cap, on-disk cost, in-use
./mackas volume fstrim oe-build-tmp         # reclaim host disk from the sparse image ('all' for every volume)
./mackas volume duplicate oe-build-sstate sstate-backup   # CoW clone under a new name you choose
./mackas volume destroy sstate-backup       # remove ONE volume
./mackas volume move oe-build-tmp /Volumes/Fast/oe   # relocate one image to another disk
./mackas volume resize oe-build-tmp 1T      # GROW one, keeping its contents, by copying
```

A sparse ext4 image only ever grows: deleting files inside the guest never
shrinks `volume.img`. `volume list`'s **on-disk** column shows one that has
ratcheted up; `volume fstrim` hands the space back via guest `fstrim`, whose
discards become host hole-punches — on APFS hosts only
([storage.md](docs/storage.md#reclaiming-disk-from-a-grown-volume-mackas-volume-fstrim)).
`duplicate` is a near-free APFS copy-on-write clone. Everything here obeys
the **one-VM rule** — a volume a running build holds is refused
([storage.md](docs/storage.md#managing-the-volumes)).

`volume move` relocates one image (big TMPDIR on a roomier disk, sstate
stays put), leaving a symlink where the runtime expects it; `volume recover`
re-points a symlink gone stale after a hand-move, finding the image with
Spotlight
([storage.md](docs/storage.md#relocating-a-volume-and-recovering-a-hand-moved-one)).
`volume resize` **grows** a volume, keeping its contents, by copying it into
a new one of the requested size. There is no in-place grow — container
volumes carry ext4's `sparse_super2`, which the guest kernel cannot resize
online, and an offline resize would need the filesystem unmounted, which a
volume never is. **Shrinking is refused**: the same copy would work, but
silently discarding data that no longer fits is not something mackas does on
your behalf. See
[storage.md](docs/storage.md#growing-a-volume-mackas-volume-resize).

### Pruning the sstate cache

bitbake never removes an sstate object on its own — the cache only grows,
and `mackas clean` deliberately keeps it. `mackas sstate prune
--older-than N[d]` deletes objects bitbake hasn't reused in at least N days.
bitbake touches an object's mtime every time it reuses it, so "untouched for
N days" genuinely means "nothing built in N days has needed this", not
"written N days ago" — and hash-addressing makes a wrong guess cheap: a
pruned object still needed just gets rebuilt, one task, never a correctness
risk. The scan is real even under `--dry-run` (so the reported count/size
are real); deletion happens only after confirmation or `-y`, and the one-VM
rule applies. A successful prune fstrims the sstate volume automatically
afterward, so freed space is reclaimed on the host without a separate
`mackas volume fstrim oe-build-sstate` step (`MACKAS_FSTRIM_AUTO=1`, the same
knob `clean tmp+deploy` uses). For surgical pruning — keep only what one checkout's
stamps still reference — use openembedded-core's own
`scripts/sstate-cache-management.py`; `sstate prune` solves the coarser
"nothing has touched this in months" case. For a full wipe instead of
age-based pruning, `mackas clean sstate` deletes and recreates the whole
volume.

### Publishing sstate to a mirror

`mackas sstate push` is the write half of the mirror story: the read half
(`MACKAS_USE_HTTP_MIRRORS`, `mackas-mirrord`) has always been there, but
nothing put objects *on* a mirror. Set `MACKAS_SSTATE_PUSH_DEST` to an
rsync/ssh target — `mirror@host:/srv/mackas/sstate`, the directory
`mackas-mirrord` serves — and run it after a build:

```sh
mackas set MACKAS_SSTATE_PUSH_DEST mirror@linux-computer.local:/srv/mackas/sstate
mackas sstate push
```

Objects newer than this volume+destination's own stamp are copied out of the
ext4 volume into a host staging directory and **verified there** with the
same checksum manifest `mackas retrieve` uses — a real >18 GB artifact was
once copied with the right size and the wrong content, and a shared mirror is
the last place to skip that check. Only then is the volume released and the
transfer made, as two `rsync --ignore-existing` passes: every object first,
the `.siginfo` files second, so a consumer reading the mirror mid-push never
finds a signature whose object is missing. Nothing is ever sent with
`--inplace`; published objects are immutable and the first writer wins, which
is also why two machines pushing at once need no locking. The stamp advances
only after rsync exits clean — and only when the scan that produced it
provably ran and provably matched nothing, so a probe that broke costs a
rescan rather than silently dropping objects below the cutoff. An interrupted
push simply re-offers the same objects next time.

The cutoff is mtime, and bitbake touches an sstate object every time it
*reuses* one, so a push offers what recent builds wrote **or reused**. It
never misses; it does mean the staging directory wants room for the reuse
set, not just the new one.

**Push before you prune.** Once an object is on the mirror, pruning it locally
downgrades from "forced rebuild" to "HTTP refetch".

The destination is an ssh target rather than an HTTP upload on purpose:
`mackas-mirrord` is read-only, and that is a security property worth keeping.
`--full` ignores the stamp; `--dry-run` shows the shape without transferring.
Details: [storage.md](docs/storage.md#publishing-sstate-mackas-sstate-push).

### Watching a build live

A build inside the container is invisible to macOS in real time beyond
mackas's own coarse rung/log reporting. `MACKAS_MONITOR=1` opts a build into
a live progress bridge; `mackas monitor` polls it (`--once` for a single
snapshot) on `MACKAS_MONITOR_PORT` (default `8801`) — it never starts a
build. Each poll shows status, task counts and percent, the current
recipe:task, elapsed time, sstate coverage once the run queue has settled,
and — for tasks that report it, which covers ninja-generated compiles,
`do_rootfs` and downloads — how far along and how long the running task
itself has been at it, redrawn in place rather than scrolled; the
`MACKAS_MONITOR_POLL_INTERVAL` environment variable (default 2 seconds) sets
how often it polls. With `MACKAS_MONITOR_NOTIFY=1` (or `--notify`) it also
posts a native macOS notification on build start/success/failure, after a
one-time Notification Center grant (`mackas monitor --help`). A build that
publishes the bridge says so in one line as it starts, and one that cannot —
no checkout yet, a space in a path — warns instead of leaving you watching a
port that will never open. If Apple `container`'s port forward accepts the
connection and then resets it — a runtime bug, not a bridge one — the poller
asks the runtime which running container publishes that port and re-polls it
on the container's own address instead, so the build stays watchable. The
bridge is a real bitbake UI module tee'd into
the event stream, not a second observer client;
it stays **off by default** because enabling it mounts an overlay, shadows
the container's `bitbake`, and runs a background HTTP thread on every build.
How it becomes the real UI client without patching bitbake:
[architecture.md](docs/architecture.md#live-build-progress-the-monitor-bridge);
its JSON contract is a stable API ([monitor-app.md](docs/monitor-app.md)).

## Driving kas directly

`mackas smoketest` and `mackas shell` are wrappers; underneath is ordinary
kas. Once `env.sh` is sourced, run kas yourself from the **work directory**
(the parent of the layer checkouts, as upstream kas expects — the config
path is relative to it):

```sh
source ~/oe/env.sh
cd "$MACKAS_BASE/work"
kas-container build meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml --target tensorflow-lite
kas-container shell meta-ai/kas/base.yml:meta-ai/kas/qemuarm64.yml -c 'bitbake -c menuconfig virtual/kernel'
```

**The `cd` is not optional.** `kas-container` mounts your current directory
at `/repo` and resolves every kas config path relative to it — it will not
`cd` anywhere for you (`mackas shell`/`smoketest` do this internally).
Running from anywhere else — most importantly from `MACKAS_ROOT` itself
rather than `MACKAS_BASE` if the two differ, since `MACKAS_ROOT` is usually
the one with spaces in it — reintroduces exactly the argument word-splitting
kas-container has no defense against. Because `work/` is the `cd` target,
composing **multiple layers is just more colon-separated paths** — every
layer under `work/` is an equally-reachable sibling:

```sh
kas-container shell meta-angstrom/kas/angstrom.yml:meta-ti/kas/machine.yml
```

`kas-container` here is a **shell function**, not the program on your
`PATH`. `env.sh` defines it to do the two things only code running in *your*
shell can do: append the generated tuning fragment `:kas/macos-local.yml`
(parallelism, `BB_DISKMON_DIRS`, `BB_HASHSERVE_DB_DIR`, mirrors) onto the
file list, and derive
`MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG` from that list — exported into the
shell, never written to a config file, never overriding a value you set —
so a later `mackas retrieve` or `buildstats analyze` resolves
`DEPLOY_DIR`/`LOG_DIR`/`BUILDHISTORY_DIR` through bitbake instead of refusing
(or silently falling back to defaults your distro has redefined). It then
hands off to `$MACKAS_BIN/kas-container`, the generated protection wrapper
script, and that wrapper — not the function — is what supplies
`--runtime-args` (the ext4 volumes, CPU/memory limits, and the
live-progress-bridge args when `MACKAS_MONITOR=1`, recomputed live per call
via `mackas runtime-args --require-volumes-free`, never frozen at `setup`
time, so exporting a setting takes effect on the very next hand-typed build,
and a build that mackas refuses — a held volume, colliding volume names —
is refused here too rather than run on stale values), points `GITCONFIG_FILE` at
the generated `safe.directory` config, and blanks
`KAS_BUILD_DIR`/`DL_DIR`/`SSTATE_DIR`.
`MACKAS_KAS_AUTO_FRAGMENT=0` / `MACKAS_KAS_AUTO_PROJECT=0` disable the two
conveniences. **Piping the invocation loses the export**: `kas-container ... |
tail -3` runs the function in a subshell (any pipeline's left-hand side
does), so its `export MACKAS_PROJECT_DIR=...`/`MACKAS_KAS_CONFIG=...` dies
with that subshell and never reaches your interactive one — while the "info"
line announcing the derivation still prints, since that happens before the
pipe closes, so it silently looks like it worked. Run it unpiped if you need
the derived vars afterward. The wrapper finds the file list even behind
known flags, but **backs off untouched at any flag it does not recognize**
rather than guess — double-check the fragment got appended (`mackas
status`'s "kas files" line, or the command kas echoes back). Flag list and
mechanics:
[architecture.md](docs/architecture.md#running-kas-container-by-hand). A
chain spanning *sibling* layers (`meta-angstrom/…:meta-ti/…`) derives
nothing — mackas commands `cd` into a single checkout and a sibling would
fall outside the `/repo` mount — so keep driving those by hand from `work/`.
Bypassing the function (`command kas-container`, an absolute path, `nohup`,
`env`, an unsourced shell) still reaches `$MACKAS_BIN/kas-container` — a
generated protection wrapper script, not the raw upstream binary — so it
still gets the ext4 volumes and CPU/memory limits; only the auto-appended
fragment and the project-variable derivation are lost, since those remain
shell-function-only conveniences (see
[architecture.md](docs/architecture.md#running-kas-container-by-hand)).
The separate, still-real concern is a pipx/pip kas earlier on `PATH` than
`$MACKAS_BIN`: it resolves to a *different* kas-container release entirely,
not the 5.5 mackas pins. `check` does not inspect that ordering — it reports
the resolution order for `docker`, not for `kas-container` — so confirm it
yourself with `type -a kas-container`
([architecture.md](docs/architecture.md#running-kas-container-by-hand)).

> **For a one-off read-only command, use `mackas exec CMD` instead of typing
> `kas-container` by hand** (e.g. `mackas exec du -sh openembedded-core`) —
> it bakes in the repo-preserving `--skip` flags below and cannot be talked
> out of them, closing this off entirely rather than relying on remembering
> it. `mackas exec --help` for the full explanation.
>
> **`-k` does more than its name suggests, and dropping it is worse.** It
> skips writing `conf/local.conf`/`conf/bblayers.conf` as well as the repo
> checkout and patch steps, so adding the fragment to a file list has no
> effect on an already-configured checkout — but simply dropping `-k` re-runs
> `repos_checkout`/`repos_apply_patches` and can reset repos to their pinned
> commit. `mackas exec` covers this for anything it can reach; the hand-typed
> `--skip` recipe in
> [architecture.md](docs/architecture.md#running-kas-container-by-hand)
> is what's left for the case `exec` cannot help with — a sibling-layer
> chain, driven from `work/` directly (see above).

## Pinning a project workspace

`mackas adopt` pins a whole *foreign* root. `mackas project add <name>` is
its in-root sibling: it pins a project workspace *inside this Mac's own*
`MACKAS_ROOT`, so a second (or third) layer set builds alongside the first
with its own `work/<name>/` and, once selected, its own volumes — see
[Configuration](#configuration) for the selector itself and how the volume
stem derives from it.

```sh
./mackas project add meta-qcom --url https://example.com/meta-qcom.git --branch main
./mackas --project meta-qcom setup     # clones it, then builds out the rest
```

Both write the same kind of artifact `adopt` does: a standalone config at
`~/.config/mackas/projects/<name>.conf`, seeded from whatever settings are
in effect right now (`MACKAS_ROOT`, the checkout's URL/branch, and any
volume-name override already explicit in this invocation — sizes, CPUs/
memory and mirror settings are deliberately left out, so the file stays
readable and does not freeze today's machine-wide defaults into every future
project). `project add` only **pins**; it never clones or builds — that is
what `setup`, run afterwards under `--project <name>`, still does.

**A first-level directory under `work/` is a project workspace if and only
if a pinned config for that name exists** (#72). A plain, unpinned
`work/<name>/` — a checkout put there some other way — is just a checkout;
`project add <name>` refuses it outright rather than silently adopting it.
`--from <checkout>` is the deliberate opt-in: it converts that *exact*
`work/<name>/` entry in place, reading its remote URL and current branch
instead of asking for `--url`/`--branch`. It never renames or moves
anything — pointing `--from` at a *different* directory than `<name>` is
refused, not "fixed up" for you.

`--from` also asks the one question the design's migration path B depends
on: keep the checkout's existing volumes explicitly (`--keep-volumes`, e.g.
staying on `oe-build-*`, no data ever moved) or switch it to
`mackas-<name>-*` going forward (`--derive-volumes`; the old volumes are
left exactly as they are, not deleted). Interactively, with neither flag,
it asks; non-interactively (no tty, or `-y`) it keeps — the answer that
changes nothing and can never invalidate an existing download/sstate cache.

An already-pinned `<name>` is offered for overwrite, exactly like `adopt`
does for its own config file. `mackas project add --help` has the full flag
list; `mackas project --help` for the command family; `mackas projects`
lists what is already pinned.

Once selected, a pinned project's three volumes default to
`mackas-<name>-tmp`/`-dl`/`-sstate` — see [Configuration](#configuration) for
exactly how that derivation and its precedence-and-warn rule work. **All
three are private to the project by default.** `TMPDIR` has no sharing knob
at all — two builds in one `/build` is corruption, not contention — but the
two caches genuinely are safe to share (downloads are checksum-verified,
sstate is hash-keyed), so `MACKAS_VOLUME_DL_NAME` / `MACKAS_VOLUME_SSTATE_NAME`
*can* point two projects at the same volume. Nothing here does that for you:
sharing is opt-in per project, never the default and never the
recommendation — an ext4 volume can be mounted by only one VM at a time, so
sharing trades disk against sibling projects queuing on each other; an
[HTTP mirror](docs/storage.md#http-mirrors--optional-and-not-just-an-nfs-bridge)
buys the cross-project hit rate without that contention. Because of this,
`mackas destroy` and `mackas clean downloads`/`clean sstate` refuse to touch
a volume more than one pinned project references, naming the other
project(s) instead; the explicit way through is `mackas volume destroy
<name>`, which acts on a volume by its literal name regardless of who else
points at it. See [storage.md](docs/storage.md#naming-the-cache-volumes-outright)
for the full reasoning.

Two supported end states, and nobody is forced to move off the first one:
**(A) do nothing** — stay on `oe-build-*` indefinitely, fully supported, not
deprecated — or **(B) pin it** with `project add --from`, keeping
`oe-build-*` explicitly (`--keep-volumes`, no data ever moved) or deriving
`mackas-<name>-*` instead (`--derive-volumes`).

## Adopting a root from another Mac

`MACKAS_ROOT` is portable — an external SSD, or a disk image on a share, can
be physically moved to a second Mac. But that root carries a volume name, a
short link and an `env.sh` the *first* Mac chose, and its container volumes
may have been relocated to paths that don't exist here.
`mackas adopt /Volumes/ExternalSSD/oe` bridges that gap without clobbering
anything this Mac already has for an unrelated project. It introspects
`work/*/` for the project checkout (remote URL and branch; `--project-dir`
disambiguates when there is more than one, or none is found), **refuses
outright** if the path is already this Mac's own root (that is
`setup`/`check` territory), and derives a collision-free
`MACKAS_VOLUME_NAME` (`mackas-<name>`, suffixed if taken) and
`MACKAS_SHORT_LINK` (`~/oe-<name>`, reused on a re-adopt of the same root).

**Each adopted root gets its own config file** — by default
`~/.config/mackas/projects/<name>.conf`, or wherever `--write-config FILE`
says (note: `--write-config`, not the global `--config`, which loads an
*existing* file); from then on, drive that project with
`mackas --project <name> ...` — the default location is what makes the short
form work, and `mackas --config <that file> ...` always does too. adopt then
runs `volume recover` (so a
relocated volume Spotlight can find is re-pointed before `setup` would
create a fresh empty one over it), checks for `work/` files owned by the
other Mac's account and offers a recursive `chown` if the drive isn't
mounted `noowners`, and hands off to `setup`. If this Mac's machine-wide
volume-relocation symlink already belongs to a different live project,
`setup` detects that and *offers* — never silently does — to switch it.
`mackas adopt --help` has the full flag list.

## Files

| File | What it is |
|---|---|
| `mackas` | The whole tool. bash 3.2 compatible (macOS stock bash). |
| `bin/docker` | The `docker` → Apple `container` shim. Installed to `$MACKAS_ROOT/bin/docker` by `setup`. |
| `mackas.conf.example` | Annotated config. Copy, edit, drop somewhere on the search path. |
| `mirror-server/mackas-mirrord` | The HTTP mirror server. **Optional.** Single file, Python 3.7+, stdlib only — scp it to a mirror host, or run it locally. See [storage.md](docs/storage.md#http-mirrors--optional-and-not-just-an-nfs-bridge). |
| `mirror-server/mackas-mirrord.service` | Hardened systemd unit for it (Debian 13). |
| `mirror-server/mackas-mirrord.conf.example` | Annotated config for it. |
| `mackas-uibridge/` | The live-progress bridge (`MACKAS_MONITOR=1`): a bitbake UI module (`mackasjson.py`) and the `bitbake` wrapper mounted over the checkout's own. **Optional.** |
| `tools/` | Host-side helpers, stdlib Python: `mackas-buildstats-analyze` (`buildstats analyze`), `mackas-buildhistory-analyze` (`buildhistory analyze`), `mackas-overhead` (per-rung host CPU/RSS sampler), `mackas-monitor` (the `mackas monitor` poller), `mackas-ext4-dirty-bit` (the superblock dirty-bit probe `check` runs). |
| `tests/`, `run-tests.sh`, `Makefile` | bats test suite and its entry points (`./run-tests.sh` or `make test`). See [testing.md](docs/testing.md). |
| `COPYING` | GPLv3. |
| `$MACKAS_BASE/env.sh` | **Generated**, not shipped: the environment to `source` before building — shim on `PATH`, `KAS_*`, `BB_NUMBER_THREADS`/`PARALLEL_MAKE`, the `kas-container` wrapper function. Defaults to `~/oe/env.sh`; `env-NAME.sh` once a project is selected. |
| `$MACKAS_BASE/gitconfig` | **Generated**: forwarded as `GITCONFIG_FILE` so git can operate on `/repo` despite the virtiofs ownership quirk ([architecture.md](docs/architecture.md#git-dubious-ownership--the-blocker)). Never written over a `GITCONFIG_FILE` you already export. |

## Configuration

Precedence, lowest to highest:

```
built-in defaults  ->  config file  ->  environment  ->  command-line flags
```

Which file gets sourced, first match wins:

| | |
|---|---|
| `--config FILE` / `$MACKAS_CONF` | a path, named outright |
| `--project NAME` / `$MACKAS_PROJECT_SELECT` | `~/.config/mackas/projects/NAME.conf` |
| *(derived from `$PWD`, or from a hand-typed kas chain)* | whichever pinned project's workspace you are standing in |
| `~/.config/mackas/config` | |
| `~/.mackas.conf` | |

Naming a path and selecting a project are mutually exclusive — two answers to
the same question — so mackas refuses rather than ranking them, and the refusal
prints both resolved values plus the command to drop whichever one you did not
mean. An empty value is refused too: `--config=` and `--config ""` behave
identically, as do `--project=` and `--project ""`, so an explicit-but-empty
override can never quietly resolve to a different file.

`./mackas.conf` is deliberately **not** searched: the config is sourced as
shell, so a cwd config would let any untrusted tree you `cd` into (an
unpacked tarball, a cloned repo) run code the moment you invoke `mackas`. To
use a per-project config, name it out loud — `mackas --config ./mackas.conf
...` — and keep the file to assignments.

`--project NAME` selects a *pinned* project: the standalone config `mackas
adopt` or `mackas project add` writes under `~/.config/mackas/projects/`.
`mackas projects` lists them. It is a **selector, not a fifth precedence
rung** — it decides which single file is sourced, never a value in one, so
the chain above is unchanged. `MACKAS_PROJECT_SELECT` is therefore not a
setting: `mackas set` will not write it, and it takes no part in the config
file's own resolution. Naming a path and selecting a project are mutually
exclusive; combining them is refused rather than ranked, because silently
ignoring either one is how you build against a project you did not mean.

When neither an explicit selector nor an explicit path names a file, mackas
tries one more thing before falling back to the search path: it derives a
selection from where you are standing. It takes the *physical* `$PWD`
(`pwd -P`, so a symlinked short link such as `~/oe` resolves the same way on
both sides), and for every already-pinned project's config it **greps** —
never sources — the file for `MACKAS_ROOT`, forming
`<that root>/work/<the config's own name>` (the config's filename, not
whatever `MACKAS_PROJECT_DIR` it sets — volume identity keys off the selector
name alone) and resolving *that* physically too. If `$PWD` equals or sits
under exactly one such candidate, that project is selected through the exact
same strict path `--project` uses (the ownership check below included) —
inference only ever picks among identities you already pinned, it never
invents one, and a bare `work/foo` directory with no `foo.conf` decides
nothing. Zero matches falls straight through to the search path, byte-
identical to a build with no derivation at all. More than one match — only
reachable by deliberately nesting one pinned root's `work/` inside another's —
is refused, listing every candidate and pointing at `--project NAME` to break
the tie; it is never guessed. A `MACKAS_ROOT` that is not an absolute path
(relative, `~`, `$HOME`, a command substitution) is simply not a candidate —
it is printed by the grep, never evaluated or expanded. And a pinned config
this process cannot even read is *not* silently skipped while a selection is
being made: it could have been the match, so mackas dies naming the file
rather than guess "no". A derived path under a predictable, guessable
location is an ambush surface, not a request — the same reasoning that makes
`--project` itself stricter than `--config` below.

Standing in `work/` itself and hand-typing a `kas-container build
<layer>/kas/base.yml:...` defeats derivation from `$PWD` alone — `$PWD` there
is `work/`, the parent of every checkout, not any one project's own
directory. For exactly that case the generated wrapper also hands mackas the
chain's own leading path component (only when every colon-separated entry is
relative and agrees on it), and mackas tries `<physical $PWD>/<that
component>` as a second candidate the same way, only once `$PWD` alone found
nothing.

Whenever this derivation is what selects a project, mackas prints one line to
stderr the first time — naming the project, what it was derived from, and the
three resolved volume names — so a build run from inside a workspace never
mounts a different project's volumes with no visible trace. `./mackas status`
shows the same fact in its own "selected via" line (`--project`,
`$MACKAS_PROJECT_SELECT`, "derived from `$PWD`", or "derived from the kas
chain"), and `./mackas projects` flags a pin whose `work/<name>` has gone
missing — moved or renamed — the same way it flags a pin whose `MACKAS_ROOT`
itself is gone: identity is never re-minted from whatever *is* on disk, so
the fix is to move the checkout back or drop the pin, never for mackas to
guess a new one.

A workspace renamed or moved after being pinned simply stops matching — it
falls through to tier 4 exactly as an unpinned checkout always has, never
re-derived from the new name. And the generated `kas-container` wrapper
itself replays the pin it was built under (via `$MACKAS_PROJECT_SELECT`) so
that more than one in-root project can share one wrapper; if the directory
(or kas chain) a hand-typed build actually runs from derives a *different*
single pinned project than the one the wrapper was built for, mackas refuses
rather than silently handing that build the wrong project's volumes under the
wrapper's own frozen work dir — naming both projects and how to fix it
(re-run `setup` under the right one, or use that project's own `mackas`
commands instead of the hand-typed `kas-container`). A derived selection is
also never baked into a *generated* wrapper: `mackas setup` run from inside a
derived workspace still creates that project's volumes, but leaves the
wrapper's own pin empty, so derivation keeps deciding on every call rather
than freezing to whatever directory `setup` happened to run from.

A `--project` file is held to the same ownership check a *searched* config
is (a regular file, yours or root's, not group/world-writable, file and
directory both — and graded through symlinks, on the file that would really
be sourced and the directory it really sits in, because `ln -s` applies the
umask and a link's own mode therefore says nothing about its target), and
refused outright if it fails — deliberately stricter than `--config`, which
is exempt. mackas derives the `--project` path itself from a bare name in a
fixed, guessable place; a path you typed is a request, a path mackas guessed
is an ambush surface. Names are validated before they become a path: no path
separators, no `..`, no leading `-`, letters/digits/`.`/`_`/`-` only. When
`mackas set` has to create `~/.config/mackas/projects/` it does so at mode
`700` regardless of your umask, so a `umask 002` login cannot produce a
directory the same check then refuses.

`mackas --project NAME setup` also bakes the selector into the generated
`kas-container` wrapper. The wrapper recomputes `--runtime-args` on every
call, and it replays `NAME` into that recompute — so a hand-typed
`kas-container build ...` gets the volumes belonging to the project whose
work dir and gitconfig the wrapper was built with, not whatever the default
search path happens to find. The selector is passed explicitly even when
empty, so an exported `$MACKAS_PROJECT_SELECT` cannot re-aim one project's
wrapper at another project's volumes.

When a project is selected, the volume stem also defaults to
`mackas-<name>` (`mackas-<name>-tmp`/`-dl`/`-sstate`) instead of
`oe-build` — a **default, not a new rung**: `MACKAS_VOLUME_NAME` /
`MACKAS_VOLUME_DL_NAME` / `MACKAS_VOLUME_SSTATE_NAME` set in the
project's own config, the environment, or `--set` still win outright, the
same as always. `./mackas status` notes it, once and only informationally,
whenever an explicit value disagrees with what the selector would have
derived — keeping `oe-build-*` with no data move is a fully supported
choice, never something the note suggests fixing.

Every setting is also an environment variable of the same name, and
`--set NAME=VALUE` overrides both for the one command it rides along with.
For a *persistent* override use `mackas set MACKAS_MEMORY 48g` / `get`
(resolved through the full precedence chain) / `unset`. These operate on
whatever config file the invocation is pointed at, including one that does
not exist yet — `mackas --config ~/other-project.conf set ...`, or
`mackas --project newthing set ...`, is how you bootstrap a new per-project
config. `./mackas status` prints what is in effect, which config file (if
any) was used, and which project was selected.

The settings a new user actually needs:

| Setting | Default | Meaning |
|---|---|---|
| `MACKAS_ROOT` | *(none; falls back to `$PWD` with a warning)* | Where everything lives. Must be a dir on a case-sensitive volume — `setup` refuses otherwise; see below. |
| `MACKAS_SHORT_LINK` | `$HOME/oe` | Short, space-free symlink to `MACKAS_ROOT`. |
| `MACKAS_VOLUME_NAME` | `oe-build` (`mackas-<name>` once `--project NAME` is selected, unless set explicitly) | Stem for the three ext4 volumes (`-tmp`, `-dl`, `-sstate`). Must be space-free. |
| `MACKAS_VOLUME_DL_NAME` | *(empty: `${MACKAS_VOLUME_NAME}-dl`)* | Names the downloads volume outright instead of deriving it. Must be space-free. |
| `MACKAS_VOLUME_SSTATE_NAME` | *(empty: `${MACKAS_VOLUME_NAME}-sstate`)* | Names the sstate volume outright instead of deriving it. Must be space-free. |
| `MACKAS_VOLUME_SIZE_TMP` | `120G` | Cap on the TMPDIR volume. |
| `MACKAS_VOLUME_SIZE_DL` | `40G` | Cap on the downloads volume. |
| `MACKAS_VOLUME_SIZE_SSTATE` | `40G` | Cap on the sstate volume. |
| `KAS_IMAGE` | `ghcr.io/siemens/kas/kas:5.5` | kas container image. |
| `MACKAS_CPUS` | physical cores − 2 | Passed as `-c`. |
| `MACKAS_MEMORY` | ⅔ of host RAM | Passed as `-m`. |
| `MACKAS_PROJECT_URL` | *(empty)* | Repo `setup` clones. Empty: `setup` skips the checkout step; `smoketest` offers meta-ai for one ephemeral run. |
| `MACKAS_PROJECT_BRANCH` | *(empty)* | Branch to check out. |
| `MACKAS_PROJECT_DIR` | *(empty)* | Checkout name under `work/`; also the cwd kas runs in. |
| `MACKAS_KAS_CONFIG` | *(empty)* | kas files to compose (checkout-relative). `macos-local.yml` is appended. |
| `MACKAS_SMOKETEST_TARGETS` | *(empty)* | Space-separated smoketest build targets after the parse rung. Empty: one build rung with no `--target`. |
| `MACKAS_MONITOR` | `0` | Opt builds into the live progress bridge ([above](#watching-a-build-live)). |
| `MACKAS_WORKSPACE_IMAGE` | *(empty)* | The workspace image mounted at `work/`, once one exists. Written by `setup`, not by you: it is the record that gets `work/` reattached after a reboot. |

`MACKAS_PROJECT_SELECT` is deliberately **absent** from that table and from
every other list of settings: it chooses which file is read, so it cannot be
one of the things read out of it. `mackas set`/`get`/`unset` refuse it, and
it never participates in the precedence chain.

[mackas.conf.example](mackas.conf.example) is the authoritative, annotated
full list — mirrors, the host-overhead sampler, auto-`fstrim`, buildstats
accumulation, monitor port/notifications, `volume fsck`'s e2fsprogs image,
volume relocation, the free-space margin, and the rest all live there.
`MACKAS_CONTAINER_BIN` (read by `bin/docker`) overrides which `container`
binary the shim calls; it exists so the test suite can point the shim at a
mock.

`MACKAS_ROOT` has no default deliberately: OE needs a case-sensitive
filesystem, and a stock Mac's boot volume — so `$HOME` — is case-insensitive
APFS, so no `$HOME`-based default would actually work. If `work/` (the layer
checkouts — the only part that needs case sensitivity) probes
case-insensitive, `setup` offers to create a case-sensitive APFS sparse
image (`MACKAS_WORKSPACE_SIZE`, default `40G`, sparse) and mount it at
`work/`, preserving any existing checkout; decline, and it **refuses to
proceed** (`die`, exit 1) rather than finish "Done" on a root that would
corrupt the layer checkouts on the first build. That gate is
`MACKAS_REQUIRE_CASE_SENSITIVE=1` by default; set `0` only if the
case-sensitive parts genuinely live elsewhere.

Such an image is recorded in `MACKAS_WORKSPACE_IMAGE` and reattached on
demand. `hdiutil attach` does not survive a reboot, so every command that
touches `work/` checks the mount first, reattaches it if it can, and
**refuses to run** if it cannot: a detached image leaves `work/` a plain
case-insensitive directory, and building into one is the corruption the gate
exists to stop. `check` and `status` report the state. See
[storage.md](docs/storage.md#the-workspace-image).

Or make a case-sensitive volume once and point `MACKAS_ROOT` at it:

```sh
diskutil apfs addVolume <disk> "Case-sensitive APFS" oe   # see: diskutil list
# or a case-sensitive sparse image (one file, lives anywhere):
hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size 200g -volname oe ~/oe.sparseimage
hdiutil attach ~/oe.sparseimage
```

A space in the volume name is fully supported (the short symlink and careful
quoting handle it); `check` still warns, since some recipes mishandle spaces.

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
| [docs/architecture.md](docs/architecture.md) | The `docker` shim; git "dubious ownership" (the blocker that stood between a failing and a passing parse); the ext4 volumes and how they actually get mounted; running kas-container by hand; the short symlink; resources; case sensitivity. |
| [docs/storage.md](docs/storage.md) | What lives where and why; HTTP mirrors and their client config; serving local files instead of bind-mounting them; NFS inside the container (a dead end); disk images on network shares; volume caps, fstrim, move, resize; Time Machine. |
| [docs/mirror-server.md](docs/mirror-server.md) | `mackas-mirrord`'s threat model, and the bugs a review found in it. |
| [docs/performance.md](docs/performance.md) | What a build costs the Mac, measured: host CPU/RSS overhead, local SSD vs a network share, sstate economics. |
| [docs/homebrew.md](docs/homebrew.md) | What actually depends on Homebrew, and what it would take to stop. |
| [docs/testing.md](docs/testing.md) | The test suite and what it deliberately does not cover; debugging against upstream kas; recovering from a crash. |
| [docs/security.md](docs/security.md) | Security posture: dependency surface, isolation, supply-chain integrity, CRA readiness. |
| [docs/monitor-app.md](docs/monitor-app.md) | The progress bridge's JSON contract as a stable API, for anyone building a menubar or notification app against it. |
| [GitHub issues](https://github.com/koenkooi/mackas/issues) | Every known gap, prioritised. |

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
- **Apple `container` cannot resize a volume.** `mackas volume resize` grows
  one anyway, by creating a new volume at the requested size and copying the
  old volume's contents across (twice, to land back under the original
  name) — there is no in-place grow. Splitting TMPDIR from the caches limits
  the blast radius: resizing TMPDIR never costs you sstate.
- **`DL_DIR`/`SSTATE_DIR` live inside ext4 images and are not visible from
  macOS** — the deliberate cost of correct filesystem semantics. Read them
  via `mackas shell`, or serve them with `mackas-mirrord`.
- The kernel may need `container system kernel set --recommended --force`
  once after install. `check` probes this by booting a throwaway container.
- **A kas-container installed by other means can still win on `PATH`.**
  `env.sh`'s shell function is only one of the ways `kas-container` gets
  found; `$MACKAS_BIN/kas-container` (the generated protection wrapper
  script `$PATH` itself resolves to) is what a bare, unsourced, `nohup`- or
  `env`-launched `kas-container` reaches instead, and that wrapper still
  computes `--runtime-args` and blanks the dir vars — it is not the
  unprotected case this used to be. The concern that remains is PATH
  *ordering*: if pipx or pip installed their own `kas-container` earlier on
  `PATH` than `$MACKAS_BIN` (typically `~/.local/bin/kas-container`), a bare
  `kas-container` resolves to *that* script instead — a different kas
  version entirely, with none of mackas's protection. `type -a
  kas-container` shows which one wins; `check` does not inspect that
  ordering itself.

## Verification status

The claim of "no aarch64-host blockers" rests on completed builds of real
targets — all on macOS/aarch64 via Apple `container`, with the meta-ai layer
set — not on the absence of restrictions in the recipes:

- `setup` runs end to end, including into a `MACKAS_ROOT` *containing spaces*; `container volume create` produces a genuine sparse ext4 with working hardlinks; git clones over HTTPS land on the host owned by the invoking user.
- `bitbake -p`: 2006 recipes parse, 0 errors — after four fixes, all encoded in `mackas`, of which git's ["dubious ownership"](docs/architecture.md#git-dubious-ownership--the-blocker) refusal on `/repo` was the actual blocker.
- `bitbake bash`, from scratch: 4491 tasks attempted, none reused, all succeeded; 1938.9 s wall (32.3 min), 64.3% CPU.
- `bitbake tensorflow-lite`: 4716 tasks attempted, 4468 not rerun, all succeeded — **sstate reuse across builds works**; real artifact `/build/tmp/deploy/ipk/cortexa57/tensorflow-lite-tools_2.20.0-r0_cortexa57.ipk`.
- `bitbake llama-cpp`: 1371 tasks attempted, 1349 not rerun, all succeeded — the whole meta-ai ladder green.
- `kas-container shell` via `env.sh`: `/dev/vdc on /build type ext4 (rw,relatime)`, `nproc` 19 (18+1) — the volumes and limits reach a real container.

What that build cost the Mac, and the `do_configure` parallelism problem it
exposes, are measured in
[docs/performance.md](docs/performance.md#what-a-from-scratch-bash-build-costs).

The mirror server serves real HTTP correctly (`Range`, `If-Modified-Since`,
405/404, TLS 1.2+, `~/.netrc` auth, clean `SIGTERM`), refuses traversal and
symlink escapes, and has survived an independent review that found — and
fixed — proven exploits; [docs/mirror-server.md](docs/mirror-server.md)
documents its threat model and hardening. The HTTP mirror path is verified
against a real build, and a container can reach an HTTP server on the Mac
via both the vmnet gateway (`192.168.64.1`) and the Mac's LAN IP
([details](docs/storage.md#serving-local-files-instead-of-bind-mounting-them)).

`BB_DISKMON_DIRS`'s HALT is confirmed firing at its 2 GiB / 100k inode
thresholds — `tests/diskmon_real.bats` drives a real bitbake run to the
threshold and observes it (see [docs/testing.md](docs/testing.md#diskmon_realbats--proving-bb_diskmon_dirs-halt-actually-fires));
the open question is just the safety margin between the 1s heartbeat check
and how fast a task can write, tracked as
[koenkooi/mackas#34](https://github.com/koenkooi/mackas/issues/34).

Standing unknowns — an NFS-backed mirror root and the container →
separate-LAN-host network leg — are tracked, with everything else unproven,
in [the issue tracker](https://github.com/koenkooi/mackas/issues).

## Licence

GPLv3-or-later. See [COPYING](COPYING) for the full text.

Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>

mackas is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
