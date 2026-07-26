# Architecture

How mackas bridges kas-container to Apple `container` without patching kas.
See the [README](../README.md) for what mackas is and how to run it.

Two macOS facts shape almost everything below. Apple `container` — the
native container runtime built on Virtualization.framework — runs each
container in its own lightweight Linux VM. Host directories reach that VM
over **virtiofs**, a file-sharing protocol rather than a block device, so a
bind-mounted directory keeps APFS semantics and picks up virtiofs's
ownership quirks. Named volumes are different: they are sparse **ext4 disk
images** attached to the VM as virtual block devices, with real Linux
filesystem semantics. The mount design below is the result of choosing
correctly between those two transports.

## The `docker` shim

kas-container v5.4 cannot run against Apple `container` unmodified, for two
reasons. First, engine detection: it picks its engine with, essentially,

```sh
command -v docker && docker -v 2>/dev/null | grep -q '^Docker'
```

and offers no hook for a custom binary and no environment variable to point
it elsewhere. Second, it passes Docker/Podman options — `--privileged`,
`--security-opt`, `--userns`, `--group-add` — that Apple `container` does
not have.

So `bin/docker` masquerades as the Docker CLI and translates the handful of
calls kas actually makes:

| Call | What the shim does |
|---|---|
| `docker -v` | Prints `Docker version 29.3.1, build shim`. Must start with `Docker` or kas will not recognise the engine. |
| `docker context show` | Prints `default`. kas greps this for `rootless` to decide whether to mount the repo read-only and take a privileged-container path Apple `container` cannot support. |
| `--log-driver`, `--security-opt`, `--userns`, `--group-add`, `--privileged` | Dropped. Apple `container` rejects them with exit 64 "Unknown option". Safe for plain OpenEmbedded, which does not depend on their semantics. |
| `--device`, `--network host` | **Hard failure.** No equivalent exists, and dropping them silently would change semantics. The shim refuses rather than guessing. |
| `docker images`/`ps`/`pull`/`rmi` | Renamed to `container image ls` / `container list` / `container image pull` / `container image rm`. |
| Anything after the IMAGE positional | Forwarded verbatim, so a `--privileged` inside the container's own command line is never touched. |

Arguments are held in bash arrays throughout and never round-tripped through
a string, so paths with spaces survive — a build volume named e.g. `My Disk`
works, and the suite tests exactly that.

> **The shim must come before `/usr/local/bin` on `PATH`**, where the real
> Docker CLI lives and will happily answer instead. `env.sh` handles this;
> `check` reports the actual resolution order. This is the single most likely
> thing to bite you.

kas's `USER_ID`/`GROUP_ID` privilege drop works under Apple `container`:
files land on the host owned by you, not root, all the way through a full
`kas-container checkout`.

## git "dubious ownership" — the blocker

Without the gitconfig forwarding described here, `bitbake -p` fails inside
the container — and the failure mode points in entirely the wrong direction.
The underlying symptom, inside the container:

```
fatal: detected dubious ownership in repository at '/repo'
```

**The cause is a virtiofs ownership artifact** — not a kas bug, not a mackas
bug. On every path virtiofs crosses, Apple `container`'s bind mount shows
the mount **root** as `0:0` while everything **inside** it shows as the host
user. git's dubious-ownership check (the CVE-2022-24765 fix) refuses a
repository whose top-level directory it does not own, and `/repo` trips
exactly that.

**Why the failure mode misleads**: kas's `Repo.get_root_path()`
(`kas/repos.py`, ~line 354, called at ~line 322) runs
`git rev-parse --show-toplevel` to resolve a url-less repository — meta-ai's
own local `kas:` entry is one — and **silently falls back to the input
path** when git exits non-zero. The refusal therefore quietly mis-resolves
`BBLAYERS` to `.../kas` (the config file's own directory) instead of the
repository root, and bitbake dies far from the cause:

```
file /build/../repo/kas/conf/layer.conf not found
```

**The fix — forward `GITCONFIG_FILE`, not a kas patch.** kas-container
already has the hook: if the host variable `GITCONFIG_FILE` names an
existing file, it mounts that file read-only at
`/var/kas/userdata/.gitconfig` and exports `GITCONFIG_FILE` inside the
container too (v5.4, line 728). `mackas setup` generates
`$MACKAS_BASE/gitconfig`:

```gitconfig
[safe]
	directory = *
```

`env.sh` exports `GITCONFIG_FILE` to point at it — unless your shell already
sets one, which is never clobbered. `mackas smoketest`/`shell` do the
equivalent directly. With this in place, `git rev-parse --show-toplevel`
returns `/repo` and the full parse succeeds.

`directory = *` trusts every path git is pointed at — do **not** put it in
your own `~/.gitconfig`. It is acceptable here only because the file is
forwarded exclusively into a throwaway, single-user container, never onto
the host. `check` reports whether the file exists and has the entry; if you
export your own `GITCONFIG_FILE`, `setup`/`check` warn (without touching it)
when `safe.directory = *` is missing.

## The ext4 volumes

`container volume create -s 120G oe-build-tmp` produces a sparse ext4 image
(`"format":"ext4"`) that the guest sees as a virtual block device
(`/dev/vdc`). TMPDIR needs one because **an APFS bind mount reaching the
guest over virtiofs does not provide the semantics TMPDIR requires** —
hardlinks, permissions, xattrs, case sensitivity, correct `rename()`. The
ext4 volume does; hardlinks work inside it.

**TMPDIR on the local ext4 volume is non-negotiable.** See
[storage.md](storage.md) for what may live elsewhere.

### Three volumes, not one

| Volume | Guest path | Backs | Default cap |
|---|---|---|---|
| `${MACKAS_VOLUME_NAME}-tmp` | `/build` | `TMPDIR` | `MACKAS_VOLUME_SIZE_TMP=120G` |
| `${MACKAS_VOLUME_NAME}-dl` | `/downloads` | `DL_DIR` | `MACKAS_VOLUME_SIZE_DL=40G` |
| `${MACKAS_VOLUME_NAME}-sstate` | `/sstate` | `SSTATE_DIR` | `MACKAS_VOLUME_SIZE_SSTATE=40G` |

200G total, the budget this SSD can spare. All three are sparse — ~1.2 MB
each until used — and independently capped, so a runaway build cannot eat
the free space Time Machine needs.

They are separate so that **`mackas clean` can throw TMPDIR away and keep
the caches**: TMPDIR is big, churny and rebuildable; downloads and sstate
are expensive to refill. `mackas destroy` removes all three.

### How they get mounted, and why `KAS_BUILD_DIR` must stay unset

kas-container's `forward_dir()` **bind-mounts the host directory** that
`KAS_BUILD_DIR` / `DL_DIR` / `SSTATE_DIR` name:

```sh
# kas-container v5.4, line 632 (forward_dir() at line 287)
forward_dir KAS_BUILD_DIR "/build" "rw"     # -v $KAS_BUILD_DIR:/build:rw -e KAS_BUILD_DIR=/build
```

Setting any of them to a Mac path therefore puts TMPDIR straight back on
APFS over virtiofs — the exact thing the volumes exist to avoid. So all
three **must stay unset**. `forward_dir()` returns early on an **empty**
value, and that is the hook mackas uses: it leaves all three blank and
mounts the volumes itself:

```sh
kas-container --runtime-args "-c 18 -m 42g \
  -v oe-build-tmp:/build -e KAS_BUILD_DIR=/build \
  -v oe-build-dl:/downloads -e DL_DIR=/downloads \
  -v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate" build ...
```

The `-v` supplies a real ext4 at the guest path; the `-e` tells kas to use
it without kas ever seeing a host path to bind-mount. `--runtime-args`
(alias `--docker-args`) is a supported kas-container flag, so no kas patch.

> **`KAS_EXTRA_RUNTIME_ARGS` is not an environment variable.** kas-container
> sets it to `""` unconditionally *before* parsing arguments (v5.4, line
> 332). Exporting it does nothing — the value is discarded and every
> container silently runs at Apple's defaults of **cpus=4, memory=1gb**,
> which bitbake will thrash or OOM on. The `--runtime-args` flag is the only
> way in.

`mackas` word-splits nothing itself, but kas-container expands
`${KAS_EXTRA_RUNTIME_ARGS}` unquoted, so no value inside that string may
contain a space. That is why `MACKAS_VOLUME_NAME` must be space-free, and
why `setup` refuses a name that isn't.

### The chown — a fresh volume is `root:root`

A named volume is a real Linux filesystem, so its root really is
`root:root`. A bind mount can never show this — virtiofs forces host-user
ownership onto everything it crosses — which makes the failure specific to
named volumes and easy to misattribute to the dubious-ownership quirk above.
kas drops to `USER_ID`/`GROUP_ID` and dies:

```
PermissionError: [Errno 13] Permission denied: '/build/CACHEDIR.TAG'
```

`setup` therefore chowns each volume, every run (a crash between create and
chown would otherwise leave a `root:root` volume forever), as `-u 0:0`
because the kas image's default user is uid 30000 and cannot chown:

```sh
container run --rm -u 0:0 -v oe-build-tmp:/mnt ghcr.io/siemens/kas/kas:5.4 \
    chown "$(id -u):$(id -g)" /mnt
```

`check` reports each volume's actual ownership and the command to fix it.

The chown is also why `setup`'s volumes step can sit there for a few seconds
with no output: `container volume create` itself is near-instant (~0.2 s for
a 120 GiB sparse image), but the chown boots a throwaway VM per volume, and
that boot is the real, opaque wait. Rather than look hung, `setup` wraps it
in a live elapsed-time spinner (`spin()` in `mackas`) — honestly just
ticking seconds, not a fake percentage, since the VM boot streams no real
progress to show. It degrades to plain output when not attached to a
terminal (piped, `nohup`, CI), so test output is unaffected. The one place
`setup` *can* show a genuine bar with an ETA is the relocate step's `rsync`
(a real byte-for-byte copy with a known total) — `--info=progress2` on a
terminal, when the host's `rsync` supports it.

### The consequence: the caches are not host-visible

Being ext4 images rather than directories, `DL_DIR` and `SSTATE_DIR` cannot
be browsed, backed up, rsynced or grepped from macOS. A deliberate trade:
correctness beats convenience for a cache bitbake owns. To look inside, go
through the guest — `mackas shell`, then `ls /downloads`.

If another machine should *consume* those caches, don't reach for a bind
mount: `mackas-mirrord` serves them read-only over HTTP, bitbake's own
supported mechanism. See
[storage.md](storage.md#serving-local-files-instead-of-bind-mounting-them).

## Running `kas-container` by hand

`env.sh` defines `kas-container` as a **shell function**, so a hand-typed
kas command in a sourced shell builds against the same volumes, limits and
config fragment as mackas's own commands. The wrapper:

- supplies `--runtime-args "$MACKAS_RUNTIME_ARGS"` (the volume mounts and
  the `-c`/`-m` limits);
- blanks `KAS_BUILD_DIR`/`DL_DIR`/`SSTATE_DIR`;
- unless `MACKAS_KAS_AUTO_FRAGMENT=0`, appends the generated
  `macos-local.yml` fragment onto the file-list argument of
  `build`/`shell`/`checkout`, resolved fresh from `$PWD` on every call
  rather than baked in at generation time (the supported flow `cd`s to
  `work/`, the parent of every layer checkout, not into the project itself —
  see the main README).

The file-list argument is not always immediately after the subcommand —
kas's own config argument accepts options first (e.g. `shell -k <files>`,
exactly what `bitbake_getvar()` itself passes, or `--skip STEP` repeated,
the repo-state-preserving alternative to `-k` this project's own docs
recommend). So the wrapper scans past known boolean flags
(`-k`/`--keep-config-unchanged`, `--force-checkout`, `--update`,
`-E`/`--preserve-env`) and known value flags (`--skip`/`--target`/`-c`/
`--cmd`/`--task`/`--provenance`, consuming their separate argument too, the
single-token `--x=y` form included) to find it, and backs off untouched if
it meets any other option it does not recognize, rather than guess wrong.
`dump`/`menu` are deliberately not covered: their positional argument is not
a plain kas file list the same way.

Typing `kas-container build ...` in a sourced shell therefore does the right
thing. `command kas-container`, an absolute path, or an unsourced shell
bypasses the wrapper and builds with no volumes, no limits, and no
auto-appended fragment. `mackas status` prints the exact `--runtime-args` in
effect.

### Deriving `MACKAS_PROJECT_DIR` and `MACKAS_KAS_CONFIG`

The same argument scan feeds a second job: unless
`MACKAS_KAS_AUTO_PROJECT=0`, `_mackas_derive_project()` turns the file list
into `MACKAS_PROJECT_DIR` and `MACKAS_KAS_CONFIG` and **exports them into
the calling shell**. Driving kas by hand sets neither, and
`bitbake_getvar()` refuses without `MACKAS_PROJECT_DIR` (it is what
`MACKAS_PROJECT` — the directory kas is run from — derives from), which in
turn makes `retrieve`, `buildstats analyze` and `clean tmp+deploy` fail or
fall back to OE-core default paths a distro has redefined. The file list
already contains the answer, so the wrapper derives it.

**Piping the invocation drops the export, silently.** `kas-container ... |
tail -3` (or any pipe) runs the function on the left-hand side in a
subshell — a property of pipelines, not something the wrapper can opt out
of — so its `export`s die with that subshell and never reach the calling
shell. The "derived MACKAS_PROJECT_DIR=..." info line still prints, because
it runs before the pipe closes, so the invocation *looks* like it worked
right up until the next command falls back to a wrong default. Run it
unpiped when the derived vars need to survive into later commands in the
same shell.

The rules are deliberately narrow, because a *wrong* derivation is worse
than none — it produces a config that parses and then resolves against the
wrong tree:

- **From `work/`** (the documented cwd), the first colon-entry's leading path
  component names the checkout; it is stripped from every entry to give the
  checkout-relative form `compose_kas_files()` expects.
- **From inside a checkout** (`$PWD`'s parent is `work/`), the entries are
  already relative and the directory name is the project.
- **A chain spanning sibling layers** (`meta-angstrom/…:meta-ti/…`) derives
  **nothing at all**. mackas commands `cd` into one checkout, so a sibling
  falls outside kas's `/repo` mount — there is no checkout-relative form to
  derive, and deriving `MACKAS_PROJECT_DIR` alone would leave
  `KAS_FILES_ARG` as the bare fragment, which parses but describes a
  different build.
- **Any other cwd** derives nothing.

Derivation runs *before* the fragment is appended, so `macos-local.yml`
never lands in the derived `MACKAS_KAS_CONFIG` (`compose_kas_files()` adds
it back itself, and a doubled entry is a kas parse error). Values already
set in the environment always win, and nothing is ever written to a config
file — the same ephemeral philosophy as `setup`'s own size flags. Since env
beats the config file in mackas's precedence order, the next `mackas`
command in that shell picks the derived values up with no further plumbing.

### `-k` bundles five steps, and dropping it resets repos

`-k`/`--keep-config-unchanged` is not the narrow flag its name suggests. It
skips five steps at once (`kas/libkas.py`,
`setup_parser_keep_config_unchanged_arg`): `setup_dir`,
`finish_setup_repos`, `repos_checkout`, `repos_apply_patches` **and**
`write_bbconfig`. Two consequences follow, and they pull in opposite
directions.

Because `write_bbconfig` is skipped, a checkout configured *without* the
`macos-local.yml` fragment does not pick it up by adding it to the file list
and re-running with `-k`: kas reuses the `conf/local.conf` already on disk.

Because the repo steps are also skipped, simply dropping `-k` to force that
rewrite re-runs `repos_checkout` and `repos_apply_patches`, which reset every
declared repo to its pinned revision and re-apply patches. On a checkout with
local commits that is destructive, not merely slow.

**`mackas exec CMD` is the tool form of this** — `mackas exec du -sh
openembedded-core` runs exactly the invocation below, with the four flags
baked in and no way to omit them, so there is no hand-typed command left to
get wrong:

```sh
kas-container shell --skip setup_dir --skip finish_setup_repos \
  --skip repos_checkout --skip repos_apply_patches meta-angstrom/kas/base.yml
```

Reach for the recipe above by hand only when `exec` cannot help: driving a
sibling-layer chain (`exec` uses the single configured `KAS_FILES_ARG`, the
same scope `retrieve`/`buildstats analyze` have), or a shell that hasn't
sourced `env.sh`. That regenerates `local.conf`/`bblayers.conf` with the
fragment composed in without touching any repo. `-k` is safe afterwards,
since the fragment's settings are then baked into the file it keeps
unchanged.

This is the same rule mackas follows internally, and now in one place
structurally rather than by convention: `bitbake_getvar()` and `mackas exec`
both call a shared `kas_shell_ro()` helper that passes exactly those four
`--skip` flags unconditionally, so no variable lookup or manual `exec` — and
therefore no `mackas retrieve`, `buildstats analyze`, `clean tmp+deploy`, or
ad-hoc check — can ever reset a checkout. Before `kas_shell_ro()` existed,
this string lived in `bitbake_getvar()` alone; a second, independent copy is
exactly the kind of drift the old conditional-`-k` data-loss bug came from.

## Live build progress: the monitor bridge

A build inside the container reports nothing to macOS in real time beyond
mackas's own rung/log lines. `MACKAS_MONITOR=1` (off by default) adds a live
progress feed; `mackas monitor` polls it. Like `mackas-mirrord`, it is an
HTTP server that only makes sense next to the build — but it runs **inside**
the build's own container, published to the host over Apple `container`'s
`-p`, rather than being a separate process on the Mac.

**The bridge is a UI client, not an observer, because bitbake refuses to be
observed.** Bootstrapping a bitbake server and attaching a second
`--observe-only` XMLRPC client is a structural dead end, twice over:
registration races the busy cooker ("Cooker is busy"), and bb's server-side
readonly-command allowlist refuses an observer from ever calling
`updateConfig`, so the resulting crash has no client-side workaround.

So the bridge is the **first and only UI client** — bitbake believes it is
running its normal `knotty` terminal UI. Two pieces make that happen, both
under `mackas-uibridge/`:

- **`mackasjson.py`** is a bitbake UI module (`bb.ui.mackasjson`). Its `main()`
  does not reimplement the terminal UI: it wraps `eventHandler` in a thin tee
  proxy — each event updates a background `ThreadingHTTPServer`'s JSON state,
  then passes through **unchanged** to the real `bb.ui.knotty.main()`. So it is
  a pure side-channel tap: `kas-container shell`/`mackas smoketest` look and
  behave exactly as they do with the monitor off. The HTTP side is bare
  `BaseHTTPRequestHandler` (same reasoning as `mackas-mirrord`: every response
  is auditable code here, not inherited `http.server` behaviour), serving one
  generated JSON document, no auth/TLS — a read-only, single-build status feed
  published only for one container's lifetime. It binds `0.0.0.0`, not
  `127.0.0.1`, because that loopback is the container's, not the Mac's.
- **`bitbake`** is a wrapper mounted **over** the checked-out project's own
  `bin/bitbake` for one container's lifetime, then it calls the real
  `bitbake_main()` with `bb.ui.mackasjson` made importable and selected via
  `BITBAKE_UI`. It has to be a *file overlay*, not a `PATH` prepend: OE-core's
  `oe-buildenv-internal` re-prepends the real bitbake's own `bin/` onto `PATH`
  last, so a `PATH`-shadow would always lose. This is the same per-container
  mount-substitution technique kas-container itself uses for its `.git` overlay
  — the real checkout on disk is never modified.

`monitor_runtime_args()` (in `mackas`) assembles the mounts and the `-p`
publish when `MACKAS_MONITOR=1`, appending them to `--runtime-args`. It is
best-effort and never fatal — an opt-in extra, not something a build should
fail over — so it silently skips when there is no checkout yet or a path
involved contains a space (which would corrupt the whitespace-split
`--runtime-args` string). Both files are mounted as **individual single-file
`-v`s**, never a directory mount plus a mount of a file inside it: Apple
`container` silently drops the first mount whenever a second `-v`'s host
source is nested inside the first's host directory, even with unrelated
container-side targets.

`tools/mackas-monitor` is the host-side poller `mackas monitor` runs —
stdlib Python, polling `http://127.0.0.1:<port>/` every 2 s
(`POLL_INTERVAL`) and printing `[status] done/total  recipe:task` until the
build reports `success`/`failed`, or once with `--once`. It only reads an
already-published port; it never starts a build.

## The short symlink

`MACKAS_SHORT_LINK` (default `$HOME/oe`) points at `MACKAS_ROOT`, and
everything runs through it. Two reasons:

- **Spaces.** A long tail of recipes and third-party build scripts mishandle
  spaces in paths.
- **Path length.** macOS caps AF_UNIX socket paths at ~104 characters (the
  size of `sockaddr_un.sun_path` in its BSD userland), and bitbake puts
  `${TOPDIR}/bitbake.sock` there (kas issue #38). Under Apple `container`
  the bind actually lands inside the guest at `/build/bitbake.sock`, so the
  limit rarely bites, but short host paths cost nothing. `check` computes
  the real number.

`$HOME/oe` over `/opt/oe`: `/opt` is `root:wheel` and needs sudo. Set
`MACKAS_SHORT_LINK=/opt/oe` for the extra six characters.

## Resources

Apple `container` defaults to **cpus=4, memory=1gb per container** — nowhere
near enough for bitbake — and v1.1.0 has no `container system property set`
to change the default. So `-c`/`-m` are passed on every run via
`--runtime-args`. Defaults: physical cores − 2, and two thirds of RAM.

Quirk: `nproc` inside the container reports one more than the `-c` value.

## Case sensitivity

macOS formats APFS case-insensitive (case-preserving) by default, and
OpenEmbedded breaks in baffling ways on case-insensitive filesystems.
`check` probes this empirically — it creates files and looks — rather than
trusting `diskutil`. If nothing is writable yet it falls back to `diskutil`
and says so.

The requirement is narrower than it looks: it covers `work/`
(`KAS_WORK_DIR`, the layer checkouts) and nothing else. `bin/`, `kas/` and
`logs/` are indifferent, and TMPDIR, downloads and sstate are ext4 volumes
whose case rules are the guest's. `setup` therefore probes `work/` itself
rather than `MACKAS_ROOT`, which matters once a
[workspace image](storage.md#the-workspace-image) is mounted there: `work/`
is then case-sensitive while `MACKAS_ROOT`'s own filesystem is not.

An image mounted at `work/` is state mackas re-establishes rather than
assumes, because `hdiutil attach` does not survive a reboot.
`MACKAS_WORKSPACE_IMAGE` records the image; every command that touches
`work/` reattaches it, or refuses to run. The guard is fail-closed by
design — a detached image leaves `work/` looking like a perfectly ordinary
empty directory, so the failure it prevents is silent.
