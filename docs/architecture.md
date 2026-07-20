# Architecture

How mackas bridges kas-container to Apple `container` without patching kas.
See the [README](../README.md) for what mackas is and how to run it.

## The `docker` shim

kas-container v5.4 picks its engine with, essentially:

```sh
command -v docker && docker -v 2>/dev/null | grep -q '^Docker'
```

There is no hook for a custom binary and no environment variable to point it
elsewhere. So `bin/docker` masquerades as the Docker CLI and translates the
handful of calls kas actually makes:

| Call | What the shim does |
|---|---|
| `docker -v` | Prints `Docker version 29.3.1, build shim`. Must start with `Docker` or kas will not recognise the engine. |
| `docker context show` | Prints `default`. kas greps this for `rootless` to decide whether to mount the repo read-only and take a privileged-container path Apple `container` cannot support. |
| `--log-driver`, `--security-opt`, `--userns`, `--group-add`, `--privileged` | Dropped. Apple `container` rejects them with exit 64 "Unknown option". Safe for plain OpenEmbedded, which does not depend on their semantics. |
| `--device`, `--network host` | **Hard failure.** No equivalent exists, and dropping them silently would change semantics. The shim refuses rather than guessing. |
| `docker images`/`ps`/`pull`/`rmi` | Renamed to `container image ls` / `container list` / `container image pull` / `container image rm`. |
| Anything after the IMAGE positional | Forwarded verbatim, so a `--privileged` inside the container's own command line is never touched. |

Arguments are held in bash arrays throughout and never round-tripped through a
string, so paths with spaces survive — a build volume named e.g. `My Disk`
works, and the suite tests exactly that.

> **The shim must come before `/usr/local/bin` on `PATH`**, where the real
> Docker CLI lives and will happily answer instead. `env.sh` handles this;
> `check` reports the actual resolution order. This is the single most likely
> thing to bite you.

kas's `USER_ID`/`GROUP_ID` privilege drop works under Apple `container`: files
land on the host owned by you, not root. Verified with a real
`kas-container checkout` end-to-end.

## git "dubious ownership" — the blocker

The single bug standing between `bitbake -p` failing and passing, with a
failure mode that points in entirely the wrong direction. The symptom, inside
the container:

```
fatal: detected dubious ownership in repository at '/repo'
```

**The cause is a virtiofs ownership artifact** — not a kas bug, not a mackas
bug. Apple `container`'s virtiofs bind mount shows the mount **root** as
`0:0` while everything **inside** it shows as the host user, on every path
virtiofs crosses. git's dubious-ownership check (the CVE-2022-24765 fix)
refuses a repository whose top-level directory it does not own, and `/repo`
trips exactly that.

**Why it was hard to find**: kas's `Repo.get_root_path()` (`kas/repos.py`,
~line 354, called at ~line 322) runs `git rev-parse --show-toplevel` to
resolve a url-less repository — meta-ai's own local `kas:` entry is one — and
**silently falls back to the input path** when git exits non-zero. The
refusal therefore quietly mis-resolved `BBLAYERS` to `.../kas` (the config
file's own directory) instead of the repository root, and bitbake died far
from the cause:

```
file /build/../repo/kas/conf/layer.conf not found
```

**The fix — forward `GITCONFIG_FILE`, not a kas patch.** kas-container already
has the hook: if the host variable `GITCONFIG_FILE` names an existing file, it
mounts that file read-only at `/var/kas/userdata/.gitconfig` and exports
`GITCONFIG_FILE` inside the container too (v5.4, line 728). `mackas setup`
generates `$MACKAS_BASE/gitconfig`:

```gitconfig
[safe]
	directory = *
```

`env.sh` exports `GITCONFIG_FILE` to point at it — unless your shell already
sets one, which is never clobbered. `mackas smoketest`/`shell` do the equivalent
directly. Verified: with this in place `git rev-parse --show-toplevel`
returns `/repo` and the full parse succeeds.

`directory = *` trusts every path git is pointed at — do **not** put it in
your own `~/.gitconfig`. It is acceptable here only because the file is
forwarded exclusively into a throwaway, single-user container, never onto the
host. `check` reports whether the file exists and has the entry; if you
export your own `GITCONFIG_FILE`, `setup`/`check` warn (without touching it)
when `safe.directory = *` is missing.

## The ext4 volumes

`container volume create -s 120G oe-build-tmp` produces a sparse ext4 image
(`"format":"ext4"`) that the guest sees as `/dev/vdc`. TMPDIR needs it because
**an APFS bind mount reaching the guest over virtiofs does not provide the
semantics TMPDIR requires** — hardlinks, permissions, xattrs, case
sensitivity, correct `rename()`. The ext4 volume does; hardlinks verified
working inside it.

**TMPDIR on the local ext4 volume is non-negotiable.** See
[storage.md](storage.md) for what may live elsewhere.

### Three volumes, not one

| Volume | Guest path | Backs | Default cap |
|---|---|---|---|
| `${MACKAS_VOLUME_NAME}-tmp` | `/build` | `TMPDIR` | `MACKAS_VOLUME_SIZE_TMP=120G` |
| `${MACKAS_VOLUME_NAME}-dl` | `/downloads` | `DL_DIR` | `MACKAS_VOLUME_SIZE_DL=40G` |
| `${MACKAS_VOLUME_NAME}-sstate` | `/sstate` | `SSTATE_DIR` | `MACKAS_VOLUME_SIZE_SSTATE=40G` |

200G total, the budget this SSD can spare. All three are sparse — ~1.2 MB each
until used — and independently capped, so a runaway build cannot eat the free
space Time Machine needs.

They are separate so that **`mackas clean` can throw TMPDIR away and keep the
caches**: TMPDIR is big, churny and rebuildable; downloads and sstate are
expensive to refill. `mackas destroy` removes all three.

### How they get mounted, and why `KAS_BUILD_DIR` must stay unset

mackas shipped this wrong for a while: it set `KAS_BUILD_DIR` to an APFS path
and created the volume without ever mounting it.

kas-container's `forward_dir()` **bind-mounts the host directory** that
`KAS_BUILD_DIR` / `DL_DIR` / `SSTATE_DIR` name:

```sh
# kas-container v5.4, line 632 (forward_dir() at line 287)
forward_dir KAS_BUILD_DIR "/build" "rw"     # -v $KAS_BUILD_DIR:/build:rw -e KAS_BUILD_DIR=/build
```

So pointing those at a Mac directory puts TMPDIR straight back on APFS over
virtiofs. `forward_dir()` returns early on an **empty** value, so mackas
leaves all three blank and mounts the volumes itself:

```sh
kas-container --runtime-args "-c 18 -m 42g \
  -v oe-build-tmp:/build -e KAS_BUILD_DIR=/build \
  -v oe-build-dl:/downloads -e DL_DIR=/downloads \
  -v oe-build-sstate:/sstate -e SSTATE_DIR=/sstate" build ...
```

The `-v` supplies a real ext4 at the guest path; the `-e` tells kas to use it
without kas ever seeing a host path to bind-mount. `--runtime-args` (alias
`--docker-args`) is a supported kas-container flag, so no kas patch.

> **`KAS_EXTRA_RUNTIME_ARGS` is not an environment variable.** kas-container
> sets it to `""` unconditionally *before* parsing arguments (v5.4, line
> 332). Exporting it does nothing — the value is discarded and every
> container silently runs at Apple's defaults of **cpus=4, memory=1gb**,
> which bitbake will thrash or OOM on. The `--runtime-args` flag is the only
> way in. mackas exported it for a while; that is how this shipped once.

`mackas` word-splits nothing itself, but kas-container expands
`${KAS_EXTRA_RUNTIME_ARGS}` unquoted, so no value inside that string may
contain a space. That is why `MACKAS_VOLUME_NAME` must be space-free, and why
`setup` refuses a name that isn't.

### The chown — a fresh volume is `root:root`

A named volume is a real Linux filesystem, so its root is really `root:root`
— invisible with a bind mount, where virtiofs forces host-user ownership onto
everything, which is exactly why this bug hid behind the dubious-ownership
one. kas drops to `USER_ID`/`GROUP_ID` and dies:

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

This chown is also the reason `setup`'s volumes step can sit there for a few
seconds with no output: `container volume create` itself is near-instant
(measured: 0.21s for a 120 GiB sparse image), but the chown boots a
throwaway VM per volume, and that boot is the real, opaque wait. Rather than
look hung, `setup` wraps it in a live elapsed-time spinner (`spin()` in
`mackas`) — honestly just ticking seconds, not a fake percentage, since the
VM boot streams no real progress to show. It degrades to plain output when
not attached to a terminal (piped, `nohup`, CI), so test output is
unaffected. The one place `setup` *can* show a genuine bar with an ETA is the
relocate step's `rsync` (a real byte-for-byte copy with a known total) —
`--info=progress2` on a terminal, when the host's `rsync` supports it.

### The consequence: the caches are not host-visible

Being ext4 images rather than directories, `DL_DIR` and `SSTATE_DIR` cannot be
browsed, backed up, rsynced or grepped from macOS. A deliberate trade:
correctness beats convenience for a cache bitbake owns. To look inside, go
through the guest — `mackas shell`, then `ls /downloads`.

If another machine should *consume* those caches, don't reach for a bind
mount: `mackas-mirrord` serves them read-only over HTTP, bitbake's own
supported mechanism. See
[storage.md](storage.md#serving-local-files-instead-of-bind-mounting-them).

### Running `kas-container` by hand

`env.sh` defines `kas-container` as a **shell function** that supplies
`--runtime-args "$MACKAS_RUNTIME_ARGS"` and blanks
`KAS_BUILD_DIR`/`DL_DIR`/`SSTATE_DIR`. Typing `kas-container build ...` in a
sourced shell therefore does the right thing; `command kas-container`, an
absolute path, or an unsourced shell bypasses the wrapper and builds with no
volumes and no limits. `mackas status` prints the exact `--runtime-args` in
effect.

## The short symlink

`MACKAS_SHORT_LINK` (default `$HOME/oe`) points at `MACKAS_ROOT`, and
everything runs through it. Two reasons:

- **Spaces.** A long tail of recipes and third-party build scripts mishandle
  spaces in paths.
- **Path length.** macOS caps AF_UNIX socket paths at ~104 chars, and bitbake
  puts `${TOPDIR}/bitbake.sock` there (kas issue #38). Under Apple
  `container` the bind actually lands inside the guest at
  `/build/bitbake.sock`, so the limit rarely bites, but short host paths cost
  nothing. `check` computes the real number.

`$HOME/oe` over `/opt/oe`: `/opt` is `root:wheel` and needs sudo. Set
`MACKAS_SHORT_LINK=/opt/oe` for the extra six characters.

## Resources

Apple `container` defaults to **cpus=4, memory=1gb per container** — nowhere
near enough for bitbake — and v1.1.0 has no `container system property set` to
change the default. So `-c`/`-m` are passed on every run via `--runtime-args`.
Defaults: physical cores − 2, and two thirds of RAM.

Quirk: `nproc` inside the container reports one more than the `-c` value.

## Case sensitivity

OpenEmbedded breaks in baffling ways on case-insensitive filesystems. `check`
probes this empirically — it creates files and looks — rather than trusting
`diskutil`. If nothing is writable yet it falls back to `diskutil` and says
so.
