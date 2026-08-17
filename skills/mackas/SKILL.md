---
name: mackas
description: Drive OpenEmbedded builds on macOS through mackas (the kas-container wrapper for Apple's `container` runtime), and inspect what a build produced. Use when asked to build a recipe, image or machine for any OE layer set from a Mac; to look at buildhistory, deploy, logs or buildstats from a mackas build; or to manage the ext4 build volumes (fstrim, resize, clean, sstate prune). Covers the safe way to run one-off queries (`mackas exec`), the repo-reset and patch-skipping footguns of hand-typed `kas-container` calls, and the one-VM rule.
---

# Building and inspecting OpenEmbedded projects with mackas

Operational playbook for driving builds through mackas and reporting what they
produced. It assumes nothing about which layers or distro you are building —
mackas has no built-in project. The design rationale behind everything here
lives in this repo's own docs; this file is the **what to run, in what order,
and what to watch for**, and links out rather than re-deriving.

The one thing that shapes every step: `TMPDIR`, `DL_DIR` and `SSTATE_DIR` live
inside **ext4 volumes inside the container VM, invisible from macOS**. There is
nowhere to `cd` for them. Every inspection of build output runs inside a
container, via `mackas exec` or `mackas retrieve`, never a host-side `cd`.

## Environment layout

- **Always work from `$MACKAS_BASE/work`** — normally `~/oe/work`, sourced from
  `env.sh`. The short link (`MACKAS_SHORT_LINK`, default `$HOME/oe`) exists
  specifically to route around `kas-container` path problems (word-splitting on
  spaces, case-sensitivity), so it is not one of two equally-valid roots to
  pick between: always go through the link, never the path it points at.
  `mackas status` prints where the real storage lives; nothing in this
  playbook needs to reason about it.
- Every layer checkout is an ordinary macOS-visible directory under `work/`, as
  a sibling. Only build *output* is hidden.
- On a case-insensitive `MACKAS_ROOT`, `work/` may itself be a case-sensitive
  APFS sparse image that `setup` offered to create (`MACKAS_WORKSPACE_IMAGE`
  records it in the config). `hdiutil attach` does not survive a reboot, so
  after one, `work/` is a dangling symlink until something reattaches it:
  `mackas smoketest`/`shell`/`exec`/`lock`/`dump` reattach automatically, a
  hand-typed `kas-container` does not. If `cd "$MACKAS_BASE/work"` fails, run
  something like `mackas exec true` first — never recreate `work/` by hand, a
  plain directory there is on the case-insensitive drive and is exactly the
  corruption the image exists to prevent.
- Build output lives in three ext4 volumes (names stem from
  `MACKAS_VOLUME_NAME`, default `oe-build`):
  - `oe-build-tmp` → `/build` (`KAS_BUILD_DIR`/`TOPDIR`) → `TMPDIR` =
    `/build/tmp`, and `BUILDHISTORY_DIR` defaulting to `/build/buildhistory`
  - `oe-build-dl` → `/downloads` (`DL_DIR`)
  - `oe-build-sstate` → `/sstate` (`SSTATE_DIR`)

  Details: [architecture.md](../../docs/architecture.md#the-ext4-volumes),
  [storage.md](../../docs/storage.md).

## Preflight (every session)

```sh
source ~/oe/env.sh     # or $MACKAS_ROOT/env.sh if MACKAS_SHORT_LINK is empty
mackas status          # or ./mackas status from wherever you cloned mackas
```

Confirm: the container runtime is running, the pinned kas image is present, the
three volumes exist, and `docker resolves to` the shim under
`$MACKAS_ROOT/bin/docker` — **not** `/usr/local/bin/docker`. If anything is
off, `mackas check` names the fix for each item.

**Prefer the sourced shell function, but a bypass is no longer dangerous.** `env.sh` defines a `kas-container` shell function that appends the generated tuning fragment and derives `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG`, then hands off to `$MACKAS_BIN/kas-container` — a generated protection wrapper *script*, not the raw upstream binary, that computes `--runtime-args` (the three volumes, the `-c`/`-m` limits) live and blanks `KAS_BUILD_DIR`/`DL_DIR`/`SSTATE_DIR` on the host side so kas's own bind-mount logic stays out of the way. Because that wrapper script is what `$PATH` itself resolves `kas-container` to, `command kas-container`, an absolute path, `nohup`, `env`, `xargs`, or an unsourced shell all still reach it with the correct ext4 volumes, `-c`/`-m` limits and blanked dir vars — the only things such a bypass loses are the auto-appended tuning fragment and the `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG` derivation, both shell-function-only conveniences, not safety-critical. So `mackas smoketest`/`mackas shell`, or a properly sourced shell, is still the recommended, fully-featured way to work. If a build needs to be backgrounded, prefer redirecting in a sourced shell anyway — `kas-container build ... > log 2>&1 &` runs the function in the current shell and backgrounds the job, so the fragment and project derivation still happen. The one separate, still-real concern: a pipx/pip-installed kas sitting earlier on `PATH` than `$MACKAS_BIN` makes a bare `kas-container` resolve to a *different* kas-container script entirely, at whatever version that install happens to be. **`mackas check` does not catch that**: it verifies the file at `$MACKAS_BIN/kas-container` is present and is still a generated wrapper rather than the raw upstream script, but it never resolves the name through `$PATH`. Check that yourself — `command -v kas-container` must print `$MACKAS_BIN/kas-container`.

Before this wrapper existed (issue #27), a bypass reached kas-container's *raw upstream* script directly, completely skipping `env.sh`'s function — with no error or warning to distinguish it from a real mackas-driven build until much later. The build still ran, but unprotected: no ext4 volumes, Apple's bare 4 CPU / 1 GB defaults, and — because `KAS_BUILD_DIR` was genuinely unset rather than pointed at `/build` — kas fell back to `KAS_WORK_DIR/build` on the virtiofs bind mount, where `bitbake-server`'s control sockets got permanently stuck (a fresh `bind()` still works, but every later `stat`/`unlink` on that socket file fails with `OSError: [Errno 95] Operation not supported`, so a later restart just fails the identical way) — exactly what hit a real multi-machine batch build backgrounded with `nohup kas-container build ... &`, each run silently unprotected. Full writeup: [issue #27](https://github.com/koenkooi/mackas/issues/27).

### env.sh staleness — check this first when something "documented as fixed" isn't happening

**`env.sh` is generated by `mackas setup` and does NOT auto-update when the mackas script changes** — but a stale, previously-sourced `env.sh` is much less dangerous than it used to be. The protection wrapper it delegates to, `$MACKAS_BIN/kas-container`, is regenerated by `mackas setup` independent of any particular shell's sourced state, and it live-recomputes `--runtime-args` on every call rather than freezing it — so the wrapper a stale shell hands off to is not stale itself. What a stale `env.sh` *can* still have wrong is the sourced **function's own behaviour** — fragment auto-append, project derivation — since those are shell-function-only conveniences and are subject to staleness the way they always were. `mackas` itself never goes stale this way either — `env.sh` puts the mackas checkout on `PATH`, so `mackas <subcommand>` is always the live script.

Whenever you are told "mackas was updated", or a behaviour described in this
file demonstrably isn't happening, regenerate:

```sh
mackas --dry-run setup <MACKAS_ROOT>   # optional; --dry-run is a GLOBAL flag, before the subcommand
mackas -y setup <MACKAS_ROOT>
source ~/oe/env.sh
```

Idempotent: every step reports "already done" except rewriting `env.sh` and
harmless volume-ownership `chown`s, as long as `<MACKAS_ROOT>` matches the real
existing root (get it from `mackas status` or the config file). **Pass the root
explicitly.** Bare `mackas setup` with no argument and no config file falls back
to `$PWD` with a loud warning, and can offer to relocate volumes somewhere you
did not intend.

## `mackas exec` — the safe way to run one-off commands

**`mackas exec CMD [ARGS...]` is the standard tool for every one-off query** —
`bitbake-getvar`, `bitbake -c <task>`, git queries in buildhistory, `find`/`ls`
in deploy, `cat` of a task log. It runs CMD in a throwaway kas shell with kas's
four repo-mutating setup steps (`setup_dir`, `finish_setup_repos`,
`repos_checkout`, `repos_apply_patches`) **always skipped, with no flag to add
them back**.

It exists because a hand-typed `kas-container shell <files> -c '...'` without
those skips runs kas's normal checkout/patch dance — which has reset real
checkouts' local commits more than once. Prefer `exec` over hand-typing that
invocation **every time the command is a one-off rather than a build**.
`mackas exec --help` for the full contract.

```sh
mackas exec bitbake-getvar --value -q DEPLOY_DIR
mackas exec du -sh openembedded-core
mackas exec git -C openembedded-core status
mackas exec sh -c 'cd /build/buildhistory && git log --oneline -5'
```

Practical notes:

- `exec` takes no kas file list — it composes from `MACKAS_PROJECT_DIR` /
  `MACKAS_KAS_CONFIG` and appends the generated `kas/macos-local.yml` itself.
  In a multi-layer checkout where nothing configures those, **export them per
  shell, checkout-relative**:

  ```sh
  export MACKAS_PROJECT_DIR=<checkout-under-work>
  export MACKAS_KAS_CONFIG=kas/base.yml:kas/<machine>.yml
  ```

  Re-export `MACKAS_KAS_CONFIG` when switching machines mid-shell: an
  already-set value is never overridden by derivation.
- Each `exec` is a fresh container — nothing persists between calls except what
  is on the volumes. Chain with `mackas exec sh -c '... && ...'`.
- Same **one-VM rule** as everything else: it refuses while a build or
  `mackas shell` holds any volume.
- **It is not a sandbox.** `/repo` and the volumes are mounted read-write;
  `mackas exec touch openembedded-core/foo` still creates the file. The
  guarantee is only that *kas* will not touch a repo.
- **It always skips `repos_apply_patches`**, so a freshly added `patches:`
  entry is never applied by an `exec` run — same blind spot as the `--skip`
  pair below. That is the one case to use a real `kas-container` call instead.

## Never assume a path — ask bitbake

**`DEPLOY_DIR` is not reliably `${TMPDIR}/deploy`, and `BUILDHISTORY_DIR` is not
under `tmp/` at all.** Any distro conf is free to move either. Verify before
every inspection rather than trusting a remembered path:

```sh
mackas exec sh -c 'bitbake-getvar TMPDIR; bitbake-getvar DEPLOY_DIR; bitbake-getvar BUILDHISTORY_DIR'
```

`bitbake-getvar <VAR>` parses the config (not full recipes) and prints the
resolved value — cheap enough to run every time. `--value -q` gives the bare
value for scripting. Same for `DEPLOY_DIR_IMAGE`/`DEPLOY_DIR_IPK` when a step
needs the exact subdirectory.

> **Worked example that this is real, not theoretical:**
> [meta-angstrom](https://github.com/Angstrom-distribution/meta-angstrom)
> (branch `wrynose`) sets `DEPLOY_DIR = "${TOPDIR}/deploy"` in
> `conf/distro/angstrom.conf`, putting deploy at `/build/deploy` — a *sibling*
> of `tmp/`, not inside it. That is one distro's own choice, not a mackas fact
> and not an OE default. It is exactly why `mackas retrieve` and
> `mackas clean tmp+deploy` resolve every path through bitbake instead of the
> textbook layout — a project shaped exactly like this one is precisely what
> used to let `clean tmp+deploy` silently assume the textbook path and skip
> the real `DEPLOY_DIR` entirely, which is why it now refuses instead of
> guessing when that resolution fails.

`buildhistory` sits at `${TOPDIR}/buildhistory` by class default — inside the
same volume bare `mackas clean` discards, and it records nothing at all unless
the project inherits the class
([storage.md](../../docs/storage.md#buildhistory-and-the-volume-it-lives-in)).

## Building

All commands assume `env.sh` is sourced:

```sh
cd "$MACKAS_BASE/work"
```

**The `cd` is not optional, and it must be the short link, not wherever it
points.** `kas-container` mounts the current directory at `/repo` and resolves
every kas config path relative to it; it will not `cd` anywhere for you.

### Kas fragment composition

Compose a base config with a machine fragment, colon-separated, paths relative
to `work/`:

```sh
kas-container build <checkout>/kas/base.yml:<checkout>/kas/<machine>.yml --target <target>
```

Real example, verifiable:
[meta-angstrom](https://github.com/Angstrom-distribution/meta-angstrom) on
`wrynose` ships `kas/angstrom.yml` (distro, ~20 repos, `local_conf_header`
inheriting `buildhistory`/`buildstats`/`rm_work`) plus per-machine fragments
such as `kas/qemuarm64.yml`, composed as
`meta-angstrom/kas/angstrom.yml:meta-angstrom/kas/qemuarm64.yml`.

The generated `kas/macos-local.yml` tuning fragment
(`BB_NUMBER_THREADS`/`PARALLEL_MAKE` sized to `MACKAS_CPUS`, `BB_DISKMON_DIRS`
pointed at the three volumes, `BB_HASHSERVE_DB_DIR` pinned into `$SSTATE_DIR` so
hash equivalence survives a clean, mirrors) is appended automatically by every
mackas subcommand, and by the sourced wrapper on hand-typed
`build`/`shell`/`checkout` (`MACKAS_KAS_AUTO_FRAGMENT=1`, on by default). The
wrapper skips the append when the fragment is not installed in that checkout
yet, so on a multi-layer checkout mackas was not configured for, compose it
yourself as the last entry: `...:<checkout>/kas/macos-local.yml`. It is a
tuning/perf nicety — **do not block a build on it.**

The wrapper finds the file list even behind known flags but **backs off
untouched at any flag it does not recognise** rather than guess; double-check
the fragment landed (`mackas status`'s "kas files" line, or the command kas
echoes back). Mechanics:
[architecture.md](../../docs/architecture.md#running-kas-container-by-hand).

### 1. Record pre-build state (BEFORE building)

buildhistory auto-commits after every build. Capture HEAD from inside the
container — there is no host path to `git rev-parse` against:

```sh
mackas exec sh -c 'cd /build/buildhistory 2>/dev/null && git rev-parse HEAD || echo "(no buildhistory yet)"'
```

`mackas exec` never runs kas's checkout step, so this is safe even while sibling
layers carry local-only commits. A hand-typed `kas-container shell` here would
reset them exactly like a `build` would — a read-only query is **not** exempt.

### 2. Build

```sh
cd "$MACKAS_BASE/work"
kas-container build <checkout>/kas/base.yml:<checkout>/kas/<machine>.yml --target <target>
```

Run it in the background and tee to a log: even a fully-cached recipe streams
thousands of lines, and a from-scratch image build takes hours.

Watch the tail of the log:

- `Tasks Summary: Attempted N tasks ... all succeeded.` → success. The "not
  rerun" count is the sstate reuse ratio.
- `ERROR:` lines → failure. The failing task's `log.do_<task>` path is printed,
  but it is a path **inside the container** (`/build/tmp/work/...`) — read it
  with `mackas exec cat <path>`, not a host `cat`.

For a one-off task without a full build:

```sh
mackas exec bitbake -c <task> <target>
```

(Repo-safe by construction. The one time to use a real `kas-container shell
<files> -c "bitbake -c <task> <target>"` instead is when a freshly added
`patches:` entry must be applied first — see "When it backfires" below.)

### 3. Batch builds: one target across several machines/configs

Only one `kas-container` can hold the volumes at a time (the one-VM rule), so a
batch **must be sequential** — one shell loop over machines, backgrounded as a
whole, each machine logging to its own file:

```sh
LOGDIR=<a scratch dir outside the repo>
for m in <machine-a> <machine-b> <machine-c>; do
  LOG="$LOGDIR/<target>-${m}-build.log"
  kas-container build \
    <checkout>/kas/base.yml:<checkout>/kas/${m}.yml \
    --target <target> >> "$LOG" 2>&1
done
mackas volume fstrim all
```

(Add `--skip repos_checkout --skip repos_apply_patches` only when the
composition actually needs it — see the `--skip` section.)

**Report after each machine finishes, not once at the end of the whole batch.**
The loop only notifies on completion of the entire backgrounded script, which
can be 30+ minutes of silence. Poll each machine's log for its own completion
marker and emit one line per machine as it lands — a Monitor-style loop over
`grep -qE "Summary: There (was|were)"` per log, tracking which machines have
already been reported, ending when all have. Start it right after backgrounding
the build script, not after it finishes.

**Why the log, and not the live progress bridge.** `MACKAS_MONITOR=1` before a
hand-typed build does publish the progress bridge on `MACKAS_MONITOR_PORT`
(default `8801`) — the sourced wrapper recomputes `--runtime-args` live per call
via `mackas runtime-args` rather than freezing it at `setup` time, so exporting
the setting takes effect on the very next build (confirm with `mackas
runtime-args` before/after: the `mackasjson.py` mount and `-p 8801:8801` should
appear). But **each machine in the batch is a separate container and therefore a
separate bridge**, with a gap in between, and `mackas monitor` exits on the
first dead port — both still real reasons to prefer the log for a
multi-machine batch. That gap and the `prev_status` re-arming it needs are
documented in full in
[monitor-app.md](../../docs/monitor-app.md#the-same-gap-from-the-cli-side-multi-build-batches)
— do not re-derive them, and until the CLI grows a watch mode, use the
log-polling loop for batches. (The single-build end-of-build race is a
separate, narrower problem and is now mitigated bridge-side — the bridge
lingers after a terminal status before shutting down — but that does not
touch the batch gap above.) The bridge (with `--notify`, or
`mackas set MACKAS_MONITOR_NOTIFY 1`) is a nice-to-have for a human watching
*one* build interactively. Note also: "disconnected while `building`" means
**outcome unknown** — say nothing, never report it as a failure.

**A single build's completion, without polling anything, including from a
Claude workflow.** `mackas smoketest`/`mackas build`-shaped commands already
give a real done-signal: background the command itself and read its exit
code once it returns — `mackas smoketest -y > log 2>&1 & wait $!`, or the
backgrounding pattern this harness already uses for any long shell command.
That's a genuine non-polling wait (nothing here loops on HTTP), and it's
more reliable than `mackas monitor` for exactly the reasons above: it covers
kas-level failures the bridge can't see (a bad kas config, a container that
never starts), not just bitbake's own outcome, and `smoketest`'s parse-only
first rung no longer publishes a bridge at all (it used to, and made a
watcher see a false "done" the moment recipes finished parsing, minutes
before any real build started — fixed, not just documented). `mackas
monitor --once` is still fine as a cheap progress *check* alongside the
backgrounded build; it just should not be the thing a script blocks on for
the *result*. If genuinely following one build live is what's wanted,
`monitor --wait-for-start SECONDS` now tolerates the bridge not being up yet
(the parse rung + checkout + container start can take a while) instead of
failing the instant it's launched — still single-container-only, still not
the answer for a batch.

If driving `kas-container` by hand, two things matter for a background exit
code to actually mean what it looks like it means: background it with
`> log 2>&1 &` in a shell that has **sourced** `env.sh`, never by piping it
(`kas-container ... | tail -3` runs the function in a subshell, so its own
exports — including the derived `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG` —
vanish the moment the pipe closes); and `nohup`/`env`/an absolute path/
anything else that resolves `kas-container` via `$PATH` instead of the
sourced shell function still reaches the generated protection wrapper (real
volumes, real CPU/memory limits, a genuine exit code) but skips the shell
function's own auto-appended tuning fragment and project derivation — fine
for a trustworthy background exit code, not fine if the build also needs
either of those derived for you.

## Analysing results

### Buildhistory (what changed in package/image content)

**`mackas buildhistory analyze`** answers "what did the last build change"
directly: recipes added/removed/upgraded, the biggest `PKGSIZE` movers
(listed past >1% or >64 KiB; smaller ones still counted into the net
total), and per-image `IMAGESIZE`/installed-package deltas — read via host
`git` plumbing, no container. `mackas retrieve buildhistory` **copies the
whole tree to `$MACKAS_BASE/artifacts/buildhistory`** (a real host-side
directory, a git checkout when `BUILDHISTORY_COMMIT` is on) and then runs
this summary automatically on what it just copied, so a routine retrieve
already answers the question. Re-run it later without re-copying:

```sh
mackas buildhistory analyze                              # $MACKAS_BASE/artifacts/buildhistory, build-minus-1..HEAD
mackas buildhistory analyze --from HEAD~5 --to HEAD       # a wider comparison
mackas buildhistory analyze --detail                      # + upstream buildhistory-diff's per-field output
mackas buildhistory analyze --json                        # for scripting/piping
```

`--detail` additionally runs openembedded-core's own
`scripts/buildhistory-diff` in a throwaway kas-image container for
per-field semantics (`RDEPENDS` version-constraint comparisons, unified
diffs of `pkg_postinst`) the summary deliberately does not reimplement —
best-effort, needs a checkout under `$MACKAS_ROOT/work`. It resolves
`BUILDHISTORY_DIR` via bitbake, and says so specifically when the project
does not inherit the class instead of reporting a missing directory. With
`BUILDHISTORY_COMMIT` off there is no history to diff, so it reports the
CURRENT state instead (counts and sizes, no comparison).

`retrieve buildhistory` is a full copy each time, so for one quick lookup
without copying the tree, query inside the container instead:

```sh
mackas exec sh -c "cd /build/buildhistory && git log --oneline $PRE..HEAD && git diff --stat $PRE..HEAD"
```

A `git log` subject prefixed `No changes:` means output identical to the
previous build.

Per-recipe metadata lives under `packages/<TUNE_PKGARCH>/<recipe>/`. **The arch
string varies by machine and distro** (an armv7 hard-float machine and an armv8
one produce entirely different triplets, and the distro name is embedded in
some of them) — discover it rather than hard-coding:

```sh
mackas exec sh -c "
  cd /build/buildhistory &&
  A=\$(git show --name-only --oneline HEAD | grep -oE 'packages/[^/]+/<recipe>' | head -1) &&
  git show HEAD:\$A/latest &&
  git show HEAD:\$A/<recipe>/files-in-package.txt
"
```

Report: version (PV-PR), sub-packages produced, `RDEPENDS`, `PKGSIZE`, and
notable files (services, configs, binaries). Empty sub-packages (`-doc`,
`-locale`, `-staticdev`) have a zero-line `files-in-package.txt` and produce no
package file — call those out as **empty**, not missing.

For images, the same pattern against `images/<machine>/<libc>/<image>/` —
`image-info.txt`, `installed-package-names.txt`, `files-in-image.txt`; a
`git diff` between `$PRE` and `HEAD` shows added/removed packages. Prefer that
diff over the `.manifest` for package deltas.

### Deploy (the shippable artifacts)

Resolve `DEPLOY_DIR` first (above — do not assume it sits under `tmp/`). For
sizes, filenames and freshness, query in place; do not copy multi-GB artifacts
to macOS just to `ls` them:

```sh
mackas exec sh -c "
  D=\$(bitbake-getvar --value -q DEPLOY_DIR) &&
  find \$D/ipk -name '<recipe>*' -newermt '<HH:MM before build>' -printf '%TT  %10s  %p\n' | sort
"
```

- Package builds land under `deploy/<pkgformat>/<pkgarch>/`, plus `all/` and
  `<machine>/`. The package dir uses the **short** pkgarch while buildhistory
  uses the full triplet — they will not match textually.
- Image builds land in `deploy/images/<machine>/`.
- **The image filename stem is `IMAGE_BASENAME`, which an image recipe can
  override away from its own `PN`.** Check the recipe for an override before
  concluding a target "didn't produce anything" — buildhistory's image
  directory is named the same way. Real example:
  meta-angstrom's `recipes-images/angstrom/console-base-image.bb` sets
  `export IMAGE_BASENAME = "base-image"`, so building `console-base-image`
  produces `Angstrom-base-image-*` artifacts and a
  `buildhistory/images/<machine>/glibc/base-image/` directory.
- Machine-name normalisation differs between trees: buildhistory directory
  names can use underscores where deploy/images uses hyphens for the same
  machine.

### Getting files off the volumes

**Only when the artifact itself must leave the VM** (attach it, flash it, hand
it to the user):

```sh
mackas retrieve deploy                    # -> $MACKAS_BASE/artifacts/, can be tens of GB
mackas retrieve deploy images [MACHINE]   # just the boot images for one board, not the whole feed
mackas retrieve buildstats logs           # -> artifacts/{buildstats,logs}
mackas retrieve buildhistory
mackas retrieve buildstats --dest ~/out
mackas buildstats analyze                 # summarise the newest retrieved build
```

Five objects: `buildstats`, `logs`, `deploy`, `buildhistory`, `sbom`. Every one resolves
its real guest path from bitbake (`BUILDSTATS_BASE`, `LOG_DIR`, `DEPLOY_DIR`,
`BUILDHISTORY_DIR`, `DEPLOY_DIR_SPDX`), never a guessed layout. Same one-VM rule: stop the build
first.

That resolution needs `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG`. **Exporting them
yourself is the simplest and safest way** (no container invocation at all, so
none of the footguns below apply):

```sh
export MACKAS_PROJECT_DIR=<checkout-under-work>
export MACKAS_KAS_CONFIG=kas/base.yml:kas/<machine>.yml
```

Alternatively the sourced wrapper **derives both** from the file list of a
hand-typed `build`/`shell`/`checkout` and exports them into that shell only
(never to a config file, never overriding a value you set) — so after a real
build in the same shell, `retrieve` just works. If you rely on derivation:

- **It only lasts for that one shell session.** Confirm with
  `mackas retrieve --dry-run deploy`: the path it prints should be the project's
  real `DEPLOY_DIR`, not an OE-core default.
- **Never pipe the invocation.** `kas-container ... | tail -3` runs the function
  in a pipeline subshell, so its `export`s die there and never reach your shell
  — while the "derived MACKAS_PROJECT_DIR=…" info line still prints, so it looks
  like it worked right up until the next command silently falls back to a wrong
  default path. Redirecting to a file (`> log 2>&1`) is fine; that forks no
  subshell.
- **A derivation-only `shell … -c true` call is not exempt from the repo
  reset** — see the `--skip` section. Pass the `--skip` pair, or skip the whole
  dance by exporting the two variables.
- **A chain spanning sibling layers derives nothing** by design
  ([architecture.md](../../docs/architecture.md#deriving-mackas_project_dir-and-mackas_kas_config)).
- **Requires a fresh `env.sh`** (see Preflight).
- `mackas clean tmp+deploy` resolves the same way, but without it now refuses
  outright (an in-place `rm -rf` has no safe default to guess).
- `mackas buildstats analyze` needs **neither** variable: it never runs kas or
  bitbake at all. It reads what `retrieve buildstats` already copied to the
  host (`$MACKAS_BASE/artifacts/buildstats` by default, or an explicit `PATH`).

**Never run Apple's `container` CLI directly to work around any of this.**
mackas's volume-attachment guard only runs when the operation goes through
`mackas`; a raw `container` call skips that safety net. If a file genuinely
needs to come out and mackas cannot do it, raise it with the user rather than
solving it by hand. (`container list` as a pure read-only diagnostic is the one
exception — see Troubleshooting.)

### Report

1. Build result (success/fail) plus sstate reuse ratio (attempted vs. not
   rerun).
2. Buildhistory delta: new commit, version, sub-packages, `RDEPENDS`, size, key
   files.
3. Deploy: which artifacts were written, with sizes and paths.

Flag anything surprising — unexpected new `RDEPENDS`, size jumps, QA warnings,
empty packages.

## Debugging a failed build

`tmp/log` and `tmp/buildstats` are inside the invisible volume. Either read a
file in place:

```sh
mackas exec cat /build/tmp/work/.../temp/log.do_<task>
```

or pull a bundle out (`mackas retrieve buildstats logs`, then
`mackas buildstats analyze`). The `retrieve` half is under the same one-VM
rule and the same derivation caveats as `retrieve deploy`; `analyze` is
pure host-side work on what was already copied out and touches no volume (its
bootchart-SVG step does start a throwaway container, but only over host
directories).

Note that many projects inherit `rm_work`, which wipes each recipe's work dir
after it succeeds — a *failed* task's log is still there, but a *succeeded*
one's is not. Inspect results via buildhistory and deploy, not `tmp/work`.

## Disk: reclaiming, growing, cleaning

### After every build

```sh
mackas volume fstrim all
```

The volumes are sparse images that only ever grow: a from-scratch build can add
tens of GB that deleted intermediates never give back on their own. `fstrim`
hands the space back (APFS hosts only) and skips any volume still busy rather
than failing
([storage.md](../../docs/storage.md#reclaiming-disk-from-a-grown-volume-mackas-volume-fstrim)).

### Growing a volume

`mackas volume resize <name> <size>` **grows** one, keeping its contents — the
answer when `DL_DIR`/`SSTATE_DIR` need headroom without destroy-and-recreate
losing the cache. There is no in-place path: container volumes carry ext4's
`sparse_super2`, which the guest kernel cannot resize online, and an offline
resize would need the filesystem unmounted, which a volume never is. Shrinking
is refused outright
([storage.md](../../docs/storage.md#growing-a-volume-mackas-volume-resize)).

If the volume was **relocated** to another drive (`mackas status` shows this),
destroying it removes the daemon's *reference* while the image lives on the
other drive; mackas warns with the leftover's size and offers to remove it. If a
resize/destroy doesn't reclaim the space you expected, look for that prompt in
the output, and for the leftover directory on the relocated drive if it was
declined.

### Repairing ext4 corruption after a crash

A host crash mid-write can leave a volume's ext4 metadata inconsistent — the
symptom is bitbake dying with `OSError: [Errno 117] Structure needs
cleaning` on some path under `/build`. `mackas volume fsck <name> | all |
--all [--check-only]` repairs it with `e2fsck` on a `cp -c` clone of
`volume.img` — directly on the host if a working `e2fsck` is available
there (`brew install e2fsprogs`; detected, never required), else inside a
throwaway container. Either way the real volume is never reachable from the
repair process, and nothing is promoted back over it until an independent
second check pass confirms the repair is clean. The pre-repair image is
kept alongside it afterwards, forever; mackas never deletes it, not even
with `-y`
([storage.md](../../docs/storage.md#repairing-ext4-corruption-mackas-volume-fsck)).

`mackas check`/`mackas status` flag this on their own, without ever running
fsck: they read the kernel's own ext4 error bit straight off `volume.img`
(no mount, no daemon, works even with the container system down) and print
the `volume fsck <name>` fix hint right next to the affected volume
([storage.md](../../docs/storage.md#detecting-corruption-without-running-fsck-the-dirty-bit-check)).

### Cleaning

`mackas clean` with **no target** deletes and recreates the *whole* TMPDIR
volume and clears the logs dir. That drops everything under `TOPDIR`, not just
`tmp/` — deploy, **buildhistory**, `conf/` and `cache/` all go with it,
silently, with no warning that buildhistory is included. `DL_DIR`/`SSTATE_DIR`
are separate volumes and are never touched.

`mackas clean <target>` (repeatable, order irrelevant, each independently
confirmed):

- **`tmp+deploy`** — clears `TMPDIR` and `DEPLOY_DIR` **in place** inside the
  live volume, so buildhistory and `conf/` survive. Always both together:
  bitbake's stamps live under `TMPDIR` and record what already wrote
  `DEPLOY_DIR`, so clearing one alone leaves the other inconsistent — there is
  no "deploy only" or "tmp only". `SSTATE_DIR` survives, so the next build
  largely *restores* rather than recompiles (to force a genuinely fresh rebuild
  use `mackas shell` and e.g. `bitbake -f -c deploy <recipe>`). Being an
  in-place `rm -rf` it is slower than bare clean, and it auto-fstrims TMPDIR
  afterwards (`MACKAS_FSTRIM_AUTO=0` skips that).
- **`downloads`** — deletes and recreates the `DL_DIR` volume. Independent of
  the others.
- **`sstate`** — deletes and recreates the whole `SSTATE_DIR` volume.

**Prefer `mackas retrieve buildhistory` first, or `mackas clean tmp+deploy`
instead, whenever the buildhistory record still matters.**

### Pruning sstate by age

`mackas sstate prune --older-than N[d]` deletes sstate objects bitbake hasn't
*reused* in at least N days — the middle ground between doing nothing and a full
wipe. "N days old" means not reused in N days, not created N days ago: bitbake
touches an object's mtime on every reuse, so a months-old object still hit every
build stays fresh indefinitely.

Safe to prune aggressively — sstate is hash-addressed, so a pruned object that
turns out to be needed just gets rebuilt once. Never a correctness risk. The
scan is real even under `--dry-run` (the reported count/size have to be real to
be worth anything); deletion happens only after confirmation or `-y`. A
successful prune deletes in place inside the already-attached volume, so it
fstrims the sstate volume automatically afterward (`MACKAS_FSTRIM_AUTO=1`,
non-fatal, same knob `clean tmp+deploy` uses) rather than leaving reclaim as a
separate manual step. For surgical pruning — keep only what one checkout's
stamps still reference — use openembedded-core's own
`scripts/sstate-cache-management.py`; `sstate prune` solves the coarser
"nothing has touched this in months" case.

## The `--skip` flag family

Everything here is about **hand-typed `kas-container build/shell`
invocations**. `mackas exec` bakes the full four-step skip set in
unconditionally, so for one-off commands there is no flag to remember or to get
wrong. Full mechanism:
[architecture.md](../../docs/architecture.md#-k-bundles-five-steps-and-dropping-it-resets-repos).

### When it is needed: sibling layers with local-only commits

**kas force-resets clean repos to the configured branch head at build start.**
This is kas behaviour, not mackas's. Uncommitted modified *tracked* files
protect a repo ("Repo is dirty - no checkout"); untracked files do **not** count
— and neither do commits. A repo with local-only commits on the configured
branch gets silently reset and those commits vanish from the working tree
(recoverable via reflog).

**This bites hardest right after you fix something.** A repo that was dirty a
moment ago and protected the build is, the instant you `git commit` or `git am`
that fix, clean-but-ahead — and clean-but-ahead is not protected. A freshly
`git am`'d fix survives *zero* `kas-container` invocations before being reset,
with no error and no warning beyond an easy-to-miss "Repository X checked out
to `<old sha>`" log line. **Pass the pair proactively while any repo in the
composition carries local-only commits — do not wait to notice the loss.**

```sh
cd "$MACKAS_BASE/work"
kas-container build --skip repos_checkout --skip repos_apply_patches \
  <checkout>/kas/base.yml:<checkout>/kas/<machine>.yml --target <target>
```

`--skip repos_checkout` alone is not enough: kas then tries to re-apply the
config's `patches:` entries onto an already-patched tree and dies with "Could
not apply patch". Skipping both leaves every repo exactly as-is. Verify
afterwards that each repo's HEAD is still your commit stack — from the host, on
their normal paths under `work/<layer>`.

Note that `-k`/`--keep-config-unchanged` is **not** a synonym: it skips five
steps including `write_bbconfig`, so it also stops kas regenerating
`local.conf`/`bblayers.conf` — meaning adding a fragment to the file list has no
effect under `-k`. Use the explicit `--skip` pair, which is surgical. A
hand-typed `kas-container ... -k ...` through `env.sh` now prints a one-line
stderr heads-up about this rather than staying silent about it.

### When it backfires: blocking fresh patches

**Only pass the `--skip` pair when the *active* composition actually includes a
repo that needs it. Do not carry it over reflexively from other work in the same
session.**

`--skip repos_apply_patches` does not only protect already-patched repos from
re-patching: it blocks kas from applying **any** `patches:` block for **every**
repo in the composition — including a brand-new entry you just added.

Observed failure mode: after adding a new `patches:` entry for a repo with no
local commits, building with the habitual `--skip` pair silently used the
*pristine, unpatched* checkout. The patch was simply never applied, and bitbake
failed with exactly the original pre-patch error — **indistinguishable from "the
patch doesn't work"**, with no hint the skip flags were the cause.

kas only resets/patches repos actually declared in the *composed* config's
`repos:` block, so a fragment that never pulls in a given layer was not going to
touch it regardless — the pair buys no protection there and costs the new patch.
Check which repos the current composition declares before deciding whether
`--skip` is needed at all. **After adding a `patches:` entry, do at least one
build with no `--skip` flags** (or grep the log for
`Patch applied.*<new patch name>`) to confirm it really applied before trusting
the result. The same blind spot applies to `mackas exec`, which always skips
that step.

(For what a `patches:` entry looks like in practice, meta-angstrom's
`kas/angstrom.yml` on `wrynose` carries one against `openembedded-core`, sourced
from a sibling layer's `patches/` directory.)

### `mackas` commands never reset repos — except `lock`

`mackas exec`, `mackas retrieve` and `mackas clean tmp+deploy` all resolve
variables through one shared `kas_shell_ro()` helper that passes those four
`--skip` flags unconditionally, on every call. No variable lookup and no `exec`
can reset a checkout. This lives in the mackas script, not `env.sh`, so it
cannot go stale the way the wrapper can. (`mackas buildstats analyze` is not on
that list because it never runs kas at all — it only reads already-retrieved
files on the host.)

**`mackas lock` is the one exception, by design.** It runs `kas-container lock`,
whose entire job is to write a resolved lockfile into the checkout, so it is
deliberately *not* wrapped in the repo-preserving skips — and kas's own lock
plugin skips only `setup_dir`/`repos_apply_patches`/`setup_environ`/
`write_bbconfig`, leaving `repos_checkout` to run. Treat it like a build, not
like a query: run it when you actually want a fresh lock, and not while a
sibling layer carries local-only commits. `mackas dump` (resolved config to
`$MACKAS_LOGS/dump-<timestamp>.yml`) writes nothing into the checkout.

If a `retrieve`/`exec` call ever *does* reset a repo, treat
it as a signal that the mackas checkout is outdated or the fix regressed, and
check `git log <upstream>..HEAD` on the affected layer immediately (`git reflog`
holds the lost commits as recoverable entries).

## Troubleshooting

### VZError: "The storage device attachment is invalid"

`Error Domain=VZErrorDomain Code=2 "The storage device attachment is invalid"`
is the expected symptom of the **one-VM-per-volume rule** being violated.
Virtualization.framework refuses a second attach of the same ext4 image
outright, so this is an ugly refusal rather than a corrupted build — mackas's
own guard exists to turn it into a clear message first, but that guard only runs
when the operation goes through a `mackas` command.

Two distinct root causes give the identical message:

1. **Transient contention** — another `mackas`/test process actively holding a
   volume. Clears on its own; `ps aux | grep "container run"` shows it.
2. **An orphaned/stale `container` VM instance** left running from something
   unrelated (including a killed background build, or a `mackas check`
   verification container). This does **not** clear on retry.

`container list` (read-only, an inspection not a mutation, safe to run) tells
them apart: a real build's instance runs with the project's actual `-c`/`-m`
profile, so a lingering instance with a small default profile (4 CPU / 1 GB) is
the orphan. **When the error persists across 2-3 retries with no visible
contention, check `container list` before blindly retrying.** Stopping an
instance is a mutating command — diagnose with `mackas status`/`mackas check`
and raise a genuinely stuck volume with the user rather than resolving it
unilaterally with raw `container` calls.

### The forwarded gitconfig

mackas generates `$MACKAS_BASE/gitconfig` (`[safe] directory = *`) and forwards
it as `GITCONFIG_FILE`, because under Apple `container`'s virtiofs `/repo`'s
mount root appears owned by `0:0` and git then refuses to touch it at all —
which silently broke BBLAYERS resolution rather than merely warning
([architecture.md](../../docs/architecture.md#git-dubious-ownership--the-blocker)).

Current mackas checks the file is readable **and** contains `safe.directory = *`
before every kas run and dies with a clear message pointing at `mackas setup`,
so this should no longer reach you as a mystery. It still can if you bypass
mackas: a `GITCONFIG_FILE` your own shell exports always wins (`env.sh` only
sets it when unset, and never checks the file exists), and a hand-typed
`kas-container` from an unsourced shell gets nothing. The downstream symptom is
distinctive and nothing like a git error: kas's own root detection
(`git rev-parse --show-toplevel`) falls back to the wrong directory, producing
"`layer.conf` not found" or a patch `path:` resolving one directory off. **If
`kas-container` fails early with a layer.conf/patch "not found" that makes no
sense, check `ls $MACKAS_BASE/gitconfig` and `echo $GITCONFIG_FILE` first.**
The fix is `mackas setup <MACKAS_ROOT>` (which offers to fix a `GITCONFIG_FILE`
you set yourself too), or by hand:

```
[safe]
	directory = *
```

### Sibling-repo branch drift

**Verify each repo's `branch:` in the kas config actually matches where its real
work lives before treating it as the reset target.** A layer can be checked out
locally on a different branch than the kas config pins — a fork's feature branch
while the config still says `branch: master`. kas silently re-checks-out to the
*configured* branch the moment the repo is clean, discarding the real work from
the working tree with no error. If a build behaves as though branch-specific
fixes are simply missing, check `git -C work/<layer> branch -r` for a remote
branch the config does not reference, not just the working-tree state.

## Notes and gotchas

- Only **one VM** may hold an ext4 volume at a time. `retrieve`, `clean`,
  `exec`, `sstate prune` and every `volume` operation refuse while a build or
  `mackas shell` still has it attached. Stop the build first.
- `DL_DIR`/`SSTATE_DIR` are shared across every machine's build under the same
  two volumes — never point them at anything machine- or layer-specific.
- kas printing "Repo <x> is dirty - no checkout" is **expected and harmless**
  whenever sibling repos have uncommitted work; it does not fail the build.
- `mackas` global flags (`--dry-run`, `-y`/`--yes`, `-f`/`--force`, `-v`,
  `--version`) are always safe **before** the subcommand, and that placement
  is recommended; every subcommand, including `setup` and `adopt`, also
  accepts them after its own command word (e.g. `mackas setup <root>
  --dry-run` works the same as `mackas --dry-run setup <root>`). `--config`
  and `--set` are the exception: they are resolved before any subcommand
  runs, so they only work **before** the subcommand word — placed after,
  they die with a redirect to the correct order.
- Most destructive commands are two-phase: they scan for real (even under
  `--dry-run`), report what they would reclaim, and only act after confirmation
  or `-y`.
- When a recoverable problem is found, prefer offering to fix it over erroring
  out — that is the tool's own convention, and it applies to how you drive it
  too.
