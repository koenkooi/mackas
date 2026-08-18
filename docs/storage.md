# Storage plan

Where each piece of the build lives, and why. The short version:

| What | Where | Why |
|---|---|---|
| **TMPDIR** | Local ext4 container volume, on local disk | **Non-negotiable.** An APFS directory reaching the guest over virtiofs does not provide the semantics TMPDIR requires — hardlinks, permissions, xattrs, case sensitivity, correct `rename()`. See [architecture.md](architecture.md#the-ext4-volumes). |
| **Writable `SSTATE_DIR` / `DL_DIR`** | Their own local ext4 volumes | Speed, and lifecycle: separate so `clean` can drop TMPDIR without losing them. Unlike TMPDIR, ext4 here is not a *semantic* requirement — see [Does `SSTATE_DIR` actually need ext4?](#does-sstate_dir-actually-need-ext4) |
| **Read-only sstate + downloads mirrors** | Network, over **HTTP** | **Optional.** bitbake's own mechanism, recommended if you use one. |
| **Layer checkouts (`work/`)** | Host directory, bind-mounted as `KAS_WORK_DIR` | Must be **case-sensitive**, and stays host-native so `git` and `bitbake -e` keep working from macOS. On a case-insensitive drive, [a workspace image](#the-workspace-image) supplies it. |

`MACKAS_ROOT` is wherever you point it — a directory on a case-sensitive
volume, e.g. `/Volumes/<your-case-sensitive-volume>/oe`. (APFS is
case-insensitive by default; a case-sensitive APFS volume is a format-time
choice.) Everything else hangs off `MACKAS_ROOT` or lives in the container
volumes.

**Mirrors are entirely optional.** With none configured
(`MACKAS_USE_HTTP_MIRRORS=0`, `MACKAS_USE_NFS_MIRRORS=0` — both the default),
mackas fetches from upstream and populates `SSTATE_DIR`/`DL_DIR` locally,
exactly like a stock `kas-container` checkout. A mirror only matters for
reusing *someone else's* cache; nothing about `setup`, `smoketest`, or a real
build requires one.

The document is in four parts: the local volumes and their caps; managing
those volumes (reclaiming, relocating, growing, splitting across drives);
network storage (mirrors, NFS, disk images on shares); and macOS operational
concerns (buildstats, buildhistory, the workspace image, Time Machine, Full
Disk Access).

## Volume caps and the disk monitor

The fixed-size volumes are the outer bound: a runaway build cannot grow past
its own cap, so it cannot eat the rest of the disk. Inside each volume, the
generated kas fragment also sets `BB_DISKMON_DIRS` to **HALT** the build at
2 GiB / 100k inodes free on `${TMPDIR}`, `${DL_DIR}` and `${SSTATE_DIR}` — a
backstop for the build, not for the disk, since a full volume cannot reach
past its own cap.

> **Generating `BB_DISKMON_DIRS` — a multi-line, backslash-continued value —
> is genuinely fiddly.** In an unquoted bash heredoc, a literal `\`
> immediately before a real newline is a line continuation and gets **spliced
> away**, even when that `\` came from unescaping a typed `\\` — which
> flattens the value to one line on disk. `setup_kas_fragment()` therefore
> builds the value as its own single-quoted variable (no escape processing)
> and interpolates it as a plain parameter expansion, which cannot re-trigger
> the splice. `tests/volumes.bats` asserts the *exact* multi-line form on
> disk; a substring-only check would pass the mangled single-line form too.

The fragment also sets `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"`: without it,
the hash-equivalence database defaults into the per-build `/build` volume,
which `mackas clean` throws away — discarding sstate reuse on every `clean`,
not just TMPDIR — instead of living alongside the sstate it indexes. This is
set in the fragment's `local_conf_header`, **not** via kas-container's own
`BB_HASHSERVE_DB_DIR` forward, which bind-mounts a *host* directory and would
put the database straight back on APFS over virtiofs.

Where the volume images physically live, and how to place them per drive, is
the next section.

## Managing the volumes

`container volume` keeps each volume as a directory under its storage root
(`~/Library/Application Support/com.apple.container/volumes`) holding an
`entity.json` and a sparse `volume.img`. `container` v1.1.0 has no config
knob for that storage root, so `MACKAS_RELOCATE_VOLUMES=1` (the default)
symlinks the whole directory onto the build disk at
`$MACKAS_ROOT/container-volumes`, keeping every `volume.img` off the internal
disk. The daemon builds its volume index once, at its own startup — a fact
several operations below depend on. (There is no `container system restart`
subcommand in v1.1.0, which offers `start`/`stop`/`status`/…; a daemon
restart is a `stop` + `start` pair, which is what mackas runs.)

Quick index:

- Get disk space back from a volume that grew:
  [`mackas volume fstrim`](#reclaiming-disk-from-a-grown-volume-mackas-volume-fstrim).
- Move one volume to another drive:
  [`mackas volume move`](#relocating-a-volume-and-recovering-a-hand-moved-one),
  and [Three drives, one build](#three-drives-one-build-tmpdir-sstate-and-downloads-apart)
  for the full TMPDIR/sstate/downloads split.
- Make a volume bigger:
  [`mackas volume resize`](#growing-a-volume-mackas-volume-resize).
- Re-attach an image you moved by hand:
  [`mackas volume recover`](#relocating-a-volume-and-recovering-a-hand-moved-one).
- Name a cache volume yourself instead of deriving it from the stem:
  [`MACKAS_VOLUME_DL_NAME` / `MACKAS_VOLUME_SSTATE_NAME`](#naming-the-cache-volumes-outright).

Every one of these obeys the **one-VM rule**: a volume a running build holds
is refused rather than attached to, or moved under, a second VM.

### Naming the cache volumes outright

The downloads and sstate volumes are `${MACKAS_VOLUME_NAME}-dl` and
`${MACKAS_VOLUME_NAME}-sstate` unless `MACKAS_VOLUME_DL_NAME` /
`MACKAS_VOLUME_SSTATE_NAME` name them directly. Both default to empty, which
derives those names; a mackas that has never been told otherwise behaves
exactly as it always did.

Naming them is what makes it **possible** for two configs — two adopted
roots, say — to point at one cache volume. Both caches are safe to share:
downloads are upstream tarballs and git mirrors keyed by name and checksum,
so a bad one fails verification at fetch time no matter who wrote it, and
sstate is keyed by task-input hash. `BB_HASHSERVE_DB_DIR` lives in the sstate
volume (see above), so its hash-equivalence database travels with the cache
rather than being left behind.

Safe to share is not the same as worth sharing, and mackas neither shares by
default nor suggests you start. An ext4 image may be mounted by **one VM at a
time**, so a shared volume is a point where the builds that name it queue on
each other — a cost that does not exist on a Linux host, where concurrent
builds against one cache are ordinary. What you buy is disk and warm-cache
hit rate; what you pay is serialization. An [HTTP mirror](#http-mirrors--optional-and-not-just-an-nfs-bridge)
buys the hit rate without the queueing, and is the better answer whenever it
is available.

Two practical notes: the shared volume has to exist before anything can mount
it, and `mackas volume duplicate <existing> <newname>` is how to seed it from
a cache you already have; and the names land unquoted in the word-split
`--runtime-args` string, so like the stem they must be space-free — mackas
refuses one that isn't rather than mounting the fragments.

The three volumes must also resolve to three **distinct** names. Sharing a
cache between two *configs* is the supported thing these knobs make possible;
naming two volumes of the *same* config alike is not, because all three are
attached to one container — `-v shared:/downloads -v shared:/sstate` would
mount a single ext4 image twice into one VM, which is the one-VM rule broken
from the inside rather than between two builds. mackas refuses a collision
when it resolves the names, since nothing downstream would catch it: the
held-volume check only asks what *other* running containers hold, and `setup`
would otherwise create the name twice at two different sizes and report
success.

TMPDIR has no such knob on purpose. Two builds sharing one `/build` is not
contention, it is corruption.

### Reclaiming disk from a grown volume (`mackas volume fstrim`)

A sparse ext4 `volume.img` is a **ceiling that only ratchets up**. It costs
~1.2 MB empty and grows as the guest writes, but deleting files inside the
guest never shrinks it back: the freed blocks stay allocated on the host image.
A TMPDIR volume that peaked mid-build stays at that peak on disk however much
the guest deletes afterwards. Whenever disk headroom is tight — a smaller SSD,
a disk shared with other work — that reclaim matters.

The fix is `mackas volume fstrim <name>` (or `mackas volume fstrim all` for
the three mackas volumes; `all` is the primary, documented form of this
command's object, and `--all`/`-a` are accepted synonyms for it, matching
`volume destroy`/`volume fsck`). It runs `fstrim` **inside the guest**, which
issues ext4 DISCARDs; Apple's own tooling never triggers a discard, but the
hypervisor's virtio-blk backend implements DISCARD as a host **hole-punch**
(the guest's
`discard_max_bytes` is non-zero), so the punched blocks become sparse again on
the host `volume.img`. Measured: an 800M image with 600M deleted inside fell to
202M in 0.01s.

`mackas clean tmp+deploy` empties TMPDIR and DEPLOY_DIR **in place** rather
than swapping the whole volume, so — unlike bare `mackas clean`, which
replaces the volume with a fresh image and hands the space back by itself —
it would otherwise leave those freed blocks allocated. It runs this same
fstrim automatically afterward for exactly that reason
(`MACKAS_FSTRIM_AUTO=1`, the default the build path already uses around a
`smoketest`/`shell` run; set `0` to skip it and reclaim by hand later).

`mackas sstate prune` is the same story: its `find -delete` also runs **in
place** inside the already-attached sstate volume, so a prune that reclaims
tens of GB of stale objects leaves the freed blocks allocated on the host
image until something discards them. It fstrims the sstate volume
automatically right after a successful prune, gated by the same
`MACKAS_FSTRIM_AUTO`, non-fatally (a prune that succeeded is still reported
as a success even if the fstrim itself fails or the volume's filesystem
doesn't support discard). Prune and reclaim are not two separate manual
steps to remember — only the age threshold is.

It resolves both `TMPDIR` and `DEPLOY_DIR` through bitbake, and now refuses
outright when either cannot be resolved, because a guessed `DEPLOY_DIR`
previously let the command report a success it had not actually performed.

Two details matter here — get either one wrong and the reclaim silently does
nothing:

- The `fstrim` container needs **both** `-u 0:0` **and** `--cap-add
  CAP_SYS_ADMIN`. Neither alone works — a non-root user and a capless root both
  get `EPERM` on the `FITRIM` ioctl. (`util-linux fstrim` already ships in the
  kas image.)
- The reclaimed figure mackas prints is a **re-measurement of `du` on
  `volume.img`, before minus after** — not `fstrim`'s own "N bytes trimmed",
  which reports guest *free* space (it printed 882 MiB for that 600 MB reclaim)
  and which APFS block-sharing would make a lie anyway. (APFS `clonefile`
  copies share blocks, so apparent sizes routinely exceed blocks actually
  allocated.)

`hdiutil compact` does **not** work on these raw ext4 images — it returns
`Function not implemented` — so `fstrim` from inside the guest is the only
path. The one-VM rule applies: `fstrim` refuses a volume a running build
holds rather than attach an ext4 image to a second VM.

**Discard support depends on what filesystem the `volume.img` sits on, not on
mackas or `container` itself.** With `MACKAS_RELOCATE_VOLUMES=1` every image
lives under `MACKAS_ROOT`, so that disk's filesystem is what has to support
sparse-file hole-punching for `fstrim` to reclaim anything; a volume moved to
another drive with `volume move` is judged by *that* drive's filesystem
instead.

Concretely: `MACKAS_ROOT` on a case-sensitive **APFS** volume reclaims space
exactly as described above. `MACKAS_ROOT` on an **ExFAT** volume fails every
`fstrim` with `the discard operation is not supported` /
`discard_max_bytes=0` — including on a completely fresh, just-created volume,
which rules out a stale-volume or mackas-side cause. ExFAT does not support
sparse-file hole-punching, so Apple's Virtualization.framework correctly
reports no DISCARD support for a `volume.img` backed by it; this is an
accurate reflection of the host filesystem, not a bug to work around.

If disk headroom matters, put `MACKAS_ROOT` on an APFS volume. On an ExFAT
(or otherwise non-hole-punching) host there is no workaround: destroying and
re-creating the volume does not help (a fresh one fails identically), and the
volume genuinely just keeps growing toward its cap — the only lever left
there is a smaller `MACKAS_VOLUME_SIZE_*` cap chosen up front.

### Relocating a volume, and recovering a hand-moved one

`mackas volume move <name> <dir>` relocates a single volume's image to another
directory — e.g. a big TMPDIR onto a roomier disk while sstate stays put. The
runtime has no per-volume storage-root knob, so the move leaves a symlink at
`<container-volumes>/<name>` pointing to the new `<dir>/<name>`; the engine
follows it, and `status`/`volume list` resolve and report the real location. It
refuses a volume a running build holds. A same-filesystem move is an atomic
rename; a cross-filesystem move (the common case — the whole point is a roomier
disk) cannot rename, so it copies the tree with the image's **holes preserved**
(a copy-on-write `clonefile` where possible — APFS's native constant-time
block-sharing copy — else a plain sparse copy) and removes the source only
after the copy succeeds. A plain `mv` across filesystems would instead balloon
the sparse image to its full logical size, so `mackas` never uses one here.

**`mackas volume duplicate <source> <name>` clones a volume near-free.** It
uses APFS copy-on-write (`cp -c`, clonefile), so the clone shares physical
blocks with its source and costs almost nothing until one side is written —
which makes it the practical way to snapshot an sstate cache before a risky
change, or to migrate one volume's contents into a differently-named volume.
The one-VM guard here is on the **source**, not the destination: cloning an
image a running build is writing would capture an inconsistent filesystem.

**Destroying a relocated volume orphans its image.** The daemon's `volume
delete` removes what the daemon knows about — the per-volume symlink — and
never the image directory it points at, so a "destroyed" 300 GB TMPDIR keeps
costing 300 GB on the other drive, with nothing left referring to it to
explain where the space went. `mackas volume destroy`/`clean` therefore read
the symlink target *before* the delete, remove any symlink a runtime leaves
behind (belt and braces — v1.1.0 removes it itself), then warn that the image
is still on disk and offer — confirm-gated, never automatic — to remove the
leftover directory too.

If you move an image by hand and the symlink goes stale, `mackas volume
recover [<name>]` finds it again: it asks **Spotlight** (`mdfind`, the query
interface to macOS's filesystem metadata index) for a `volume.img` under a
directory named for the volume with an `entity.json` sibling, and — after you
confirm — re-points the symlink. One match is offered; several are listed for
you to pick; none, and it checks whether the disk is even indexed
(`mdutil -s`) before telling you to re-point by hand. Nothing changes without
confirmation.

An external volume's top level is typically `root:wheel`, so creating
`$MACKAS_ROOT` needs a one-off `sudo mkdir` + `sudo chown`. `setup` prompts
for exactly that and nothing more.

### Growing a volume (`mackas volume resize`)

A volume's size is fixed at creation — `setup` never resizes an existing one,
and Apple `container` v1.1.0 has no grow command — so a cap chosen months ago
used to be permanent short of destroy-and-recreate, which costs the whole
cache. `mackas volume resize <name> <size>` grows one by **copying it into a
new volume of the requested size**.

**There is no in-place grow, and there cannot be one.** Extending the sparse
image and rewriting `entity.json` works: the daemon re-reads an edited
`entity.json` across a restart and presents the larger block device. Growing
the ext4 filesystem inside it does not:

```
resize2fs: kernel does not support online resize with sparse_super2
```

`container volume create` formats its volumes with ext4's `sparse_super2`
feature — `dumpe2fs -h` on a fresh volume lists it — and the guest kernel has
no online-resize support for a filesystem carrying it. An *offline* resize
would not care, but that requires the filesystem unmounted, and a container
volume attached the normal way (`-v NAME:/path`) can only ever be mounted —
Apple's runtime bind-mounts it as ext4 before any command in the container
even runs. A loop device is the way around that: `losetup` against a raw
image file gives a real, unmounted block device, and needs only
`--cap-add CAP_SYS_ADMIN` — not `--privileged` — verified live (`volume
fsck`, below, uses exactly this). Whether `resize2fs` would work against
that unmounted loop device the same way `e2fsck` now does for repair is
genuinely open — untried, and a bigger change than this item's own
copy-based mechanism, so not pursued here; filed as a follow-on to this
item's own TODO entry. All three of image, daemon record and filesystem
still cannot be made to move together via the mounted-volume path, so the
copy mechanism below remains what `resize` actually does today.

The copy needs no `resize2fs`, no hand-edited `entity.json` and no daemon
restart, so it rests on none of those assumptions. Because Apple `container`
has no volume rename, keeping the original name costs two copies: the volume
is copied into a temporary one at the new size, the original is destroyed and
recreated at that size, and the contents are copied back. The original is
never destroyed until its copy has been verified, so an interrupted run
leaves the data in the temporary volume rather than nowhere. Expect it to
need roughly **twice the used space** while it runs, and to take as long as
copying that much data twice.

**A relocated volume stays on its drive.** `container volume create` always
creates in the default location, so a naive destroy-and-recreate would drag a
volume off the disk it was deliberately placed on. The replacements are moved
to the recorded drive while still empty — near-free — so the copies land
there too, and the space they need is demanded of that drive rather than
`MACKAS_ROOT`'s.

**Free space is reported against the drive the image really lives on**, not
`MACKAS_ROOT`'s, and a growth that drive cannot back is warned about rather
than blocked: sparse images make that failure arrive late, when a build
finally asks for the space.

**Shrinking is refused.** The same copy would work mechanically, but it means
deciding what to do with data that no longer fits, and silently discarding it
is not something mackas will do on your behalf. To get a smaller volume,
create one and copy in what you want.

### Repairing ext4 corruption (`mackas volume fsck`)

A host crash (power loss, a kernel panic, macOS itself dying) that kills the
Virtualization.framework VM mid-write can leave a volume's ext4 filesystem
metadata inconsistent — the real-world symptom is bitbake dying with
`OSError: [Errno 117] Structure needs cleaning` (`EUCLEAN`) on some path
under `/build`. `mackas volume fsck <name> | all | --all [--check-only]`
repairs this with `e2fsck`, the same tool a real Linux box would use — but
getting a genuinely unmounted filesystem to run it against is the same
mounted-volume problem `resize` runs into above, solved differently here.

**The host fast path, when a working `e2fsck` is available on the Mac
itself.** `e2fsck` operates on `volume.img` as a plain file — it needs
neither a mount nor a loop device nor the kernel to understand ext4 at all
(live-tested: Homebrew's `e2fsprogs`, a macOS binary, read AND repaired a
real corrupted `volume.img` this way, results byte-identical to the
container+loop-device path below). When `host_e2fsck_bin()` finds a working
`e2fsck` — `command -v e2fsck` first (any provenance: MacPorts, a manual
build, a non-default `brew --prefix`), falling back to asking `brew`
directly where a keg-only `e2fsprogs` actually lives, never a hardcoded
path — `volume fsck` runs it straight against the APFS clone: no throwaway
container, no network, no `apt-get`. Everything else about the design
(clone first, original never touched, the rehearsal before promotion) is
identical either way; only *how* `e2fsck` gets invoked differs. `volume
fsck`'s own plan report says which path will run, printed before the clone
and check start (`status` and `check` do not report it).

The two optional host tools this document mentions are **separate installs,
and only one of them is a `brew` package.** The ext4 dirty-bit check (below)
runs `/usr/bin/python3` by path — macOS's own stock python3, which a Command
Line Tools prompt (or `xcode-select --install`) supplies; a Homebrew
`python3` lands somewhere else entirely and does **not** satisfy it.
`e2fsprogs` (used here) is `brew install e2fsprogs`, and only if you ever
want the host fast path. Neither is required; both are detected, never
assumed, and `volume fsck` falls back to the container mechanism below with
no difference in outcome, just more network and boot time.

**Without a working host `e2fsck`: the container mechanism below, the
original design, unchanged.** The volume is never touched directly, and the
container never sees it. `-v NAME:/path` bind-mounts a NAMED volume, which
Apple's runtime auto-mounts
as ext4 before any command runs — the same fact that rules out an in-place
resize also rules out ever getting `e2fsck` unmounted access this way, and a
dirty journal (near-certain after a crash mid-write) would auto-replay — a
write — the moment anything, even a read-only check, tried to mount it.
Instead, none of it gated on a confirmation — the real `volume.img` is
never at risk until step 5, so there is nothing to ask permission for
before then:

1. `cp -c` (an APFS clonefile, same directory so it is a genuine
   copy-on-write clone, not a slow full copy) `volume.img` into a scratch
   subdirectory next to it, `.mackas-fsck-<timestamp>/`.
2. Bind-mount **that scratch subdirectory** — a plain host directory, not a
   named volume, so Apple's auto-mount-as-ext4 special case never fires —
   into a throwaway container. The real `volume.img` is not reachable from
   inside the guest at all; nothing the container runs, correct or buggy,
   can touch it. This is structural, not just careful ordering.
3. Inside, `losetup` the cloned `.img` file onto a loop device — a real,
   genuinely *unmounted* ext4 filesystem, which is what `e2fsck` needs for
   an actual repair, not merely a read-only check. This needs only
   `--cap-add CAP_SYS_ADMIN` (the same capability `fstrim` already uses),
   not `--privileged` (which Apple `container` does not have) — verified
   live; see resize's own similar-sounding claim above.
4. `e2fsck -f -y` repairs the clone; an independent second `e2fsck -f -n`
   pass must then come back completely clean before mackas will even offer
   to promote it — the rehearsal the whole design rests on.
5. Only after that rehearsal succeeds does a confirmation offer to promote
   the repaired clone over the real `volume.img` (`ln` then an atomic
   same-filesystem `mv -f`, interrupts blocked across the window — the
   same care `volume move` takes over its own transfer). The pre-repair
   image is kept alongside it afterwards,
   forever — mackas never deletes it, not even with `-y` — as the one undo
   a mistaken repair would need; `volume list` reports it until removed by
   hand.

The kas image does not ship `e2fsprogs` at all (no `e2fsck`, `fsck.ext4`,
`dumpe2fs` or `debugfs` — verified live; only a generic `/usr/sbin/fsck`
dispatcher with nothing to dispatch to), so mackas `apt-get`s it into the
throwaway container on demand — it is Debian 13 "trixie" with a working
`apt`, and a build already needs network. `MACKAS_FSCK_IMAGE` names an
image that already has `e2fsprogs`, to skip that install and work offline.

**A repair can relocate directory entries into `lost+found`** rather than
restoring them exactly in place — normal `e2fsck` behavior for a corrupted
directory entry after a crash, not a mackas bug. The file's *content*
usually survives even when its *name/location* doesn't. For the throwaway
TMPDIR volume specifically, `mackas clean` rebuilding it fresh is usually
cheaper than repairing it; sstate simply gets re-fetched/re-built for
whatever a lost object covered.

### Detecting corruption without running fsck: the dirty-bit check

`mackas check`/`mackas status` don't run `e2fsck` on every invocation — that
needs the daemon up, `e2fsprogs` installed via `apt-get` (unless
`MACKAS_FSCK_IMAGE` is set), and a clone+loop-mount, far too heavy for a
command people run constantly. Instead they read one bit for free: ext4's
superblock is a fixed, well-known 1024-byte structure sitting at a *fixed
byte offset* (1024) inside `volume.img` itself, readable straight off the
plain host file with no mount, no loop device, and no container at all.
`tools/mackas-ext4-dirty-bit` (stdlib-only `/usr/bin/python3`, the stock
macOS one) reads `s_state`'s `EXT2_ERROR_FS` bit — set by the *kernel* the
moment it detects a real ext4 inconsistency during actual use, which is
exactly what happened, unnoticed, before the crash that motivated `volume
fsck` in the first place. `check`/`status` surface it as a plain `[FAIL]` /
an inline annotation with the fix (`mackas volume fsck <name>`) right next
to the volume it's about.

Byte offsets were verified against e2fsprogs' own `lib/ext2fs/ext2_fs.h`
(`struct ext2_super_block`), not guessed from memory of the format, and
cross-checked live against a genuinely corrupted `volume.img` (the one this
session's crash produced) and its since-repaired copy. Two things learned
from that live test shaped the design:

- The companion `EXT2_VALID_FS` bit ("cleanly unmounted") is read but
  **never** used to call a volume dirty — Apple's `container` runtime does
  not appear to unmount ext4 gracefully between `container run` invocations,
  so that bit reads unset on volumes that are provably fine. Only
  `EXT2_ERROR_FS` is the verdict; `error_count`/`last_error_*` are reported
  as detail but never relied on for it.
- The first draft of the byte-offset table had `s_error_count` (and the two
  fields right after it) wrong by 4 bytes — matching the header's own
  `/*0xx*/` marker comments isn't enough; a marker attaches to the field
  immediately after it, not one two fields later, and it's easy to
  mis-attribute by eye. Only cross-checking against `dumpe2fs -h`'s own
  output on the real corrupted image (`error_count: 21695`, not `0`)
  caught it. `s_last_error_errcode` is not a raw POSIX errno either — it
  indexes e2fsprogs' own small table (`lib/e2p/errcode.c`; `5` means
  `EFSCORRUPTED`), so the tool's message uses that same table rather than
  printing a misleading number.

This is host-side and daemon-independent by construction — it is the one
part of `check`/`status`'s volume reporting that still answers correctly
while the container system is down, which is exactly the reboot-after-a-
crash scenario where it matters most. `/usr/bin/python3` and the tool file
are detected, never required: if either is missing, the check is silently
skipped — no warning, same as every other optional host tool this project
prefers over a hard requirement.

### Three drives, one build: TMPDIR, sstate and downloads apart

The three volumes look alike — three sparse ext4 images — but they are used in
completely different ways, so on a Mac with more than one disk they do not all
want the *same* disk:

| Volume | Mounted as | Access pattern | What losing it costs |
|---|---|---|---|
| `<name>-tmp` | `/build` (`TMPDIR`) | The hot one. Every task's work directory, sysroots, packaging and compile output, written and re-written throughout a build; the image that grows fastest and peaks highest. | Nothing you can't rebuild — bare `mackas clean` throws the whole volume away and recreates it; `mackas clean tmp+deploy` clears TMPDIR and DEPLOY_DIR in place, keeping buildhistory and conf/. |
| `<name>-sstate` | `/sstate` (`SSTATE_DIR`) | Read-mostly and random: many smallish archives looked up by hash, plus the hash-equivalence database (`BB_HASHSERVE_DB_DIR` points here, see above). Latency matters more than throughput. | Hours. This is the cache that makes the *next* build fast; it survives `clean` precisely because it is expensive to rebuild. |
| `<name>-dl` | `/downloads` (`DL_DIR`) | Write-once, read-rarely, large and mostly sequential: upstream tarballs and git mirrors, touched on a fetch and then largely idle. | Only download time — every byte in it is re-fetchable from upstream or a mirror. |

Which maps onto the obvious hardware split: **TMPDIR on the fastest disk
(NVMe), sstate on the mid-tier SSD, downloads on the big slow one.** The
downloads volume is also the one you would happily make several hundred GB,
which is another reason to put it where the space is.

`mackas volume move` is what places them, one at a time:

```sh
# 1. The volumes have to EXIST first -- `volume move` relocates an existing
#    volume, it never creates one. Sizes are fixed at create time and setup
#    never resizes an existing volume, so choose the downloads cap now, while
#    it is still about to be created on the 10 TB disk.
mackas setup --downloads-size 500G

# 2. Then place each one. <name> is $MACKAS_VOLUME_NAME (default `oe-build`);
#    the argument is the PARENT directory -- move creates <dir>/<name> itself.
mackas volume move oe-build-tmp    /Volumes/nvme-fast/mackas-volumes
mackas volume move oe-build-sstate /Volumes/sata-ssd/mackas-volumes
mackas volume move oe-build-dl     /Volumes/spinning-rust/mackas-volumes

# 3. Confirm where they actually ended up.
mackas status
```

Order matters only in that `setup` must have created a volume before you move
it; the three moves are independent of each other and can be done at any later
point (each one is a separate copy, so doing them one evening at a time is
fine). Nothing needs to be re-run afterwards: the symlink each move leaves
behind *is* the record, so a subsequent `mackas setup` — or a reboot — changes
nothing about the placement.

#### How this composes with `MACKAS_RELOCATE_VOLUMES`

These are two independent mechanisms and they stack rather than fight:

- `MACKAS_RELOCATE_VOLUMES=1` (the default) is **all-or-nothing**: `setup`
  replaces the machine-wide `~/Library/Application Support/com.apple.container/volumes`
  with a symlink to `$MACKAS_ROOT/container-volumes`, so *every* volume — this
  project's and anyone else's on this Mac — lands on `MACKAS_ROOT`'s disk.
- `mackas volume move` is **per volume**, and leaves its symlink one level
  further in.

Compose them and the on-disk shape is two hops:

```
~/Library/Application Support/com.apple.container/volumes
    -> /Volumes/build-ssd/oe/container-volumes            (MACKAS_RELOCATE_VOLUMES=1)
       ├── oe-build-tmp -> /Volumes/nvme-fast/mackas-volumes/oe-build-tmp   (volume move)
       ├── oe-build-dl  -> /Volumes/spinning-rust/mackas-volumes/oe-build-dl
       └── oe-build-sstate/                               (never moved: a real directory)
```

The per-volume symlinks survive relocation because `setup_relocate_volumes`
copies with `rsync -a`, and `-a` implies `-l` — symlinks are copied *as
symlinks*, never dereferenced — so a moved volume's image is not dragged onto
`MACKAS_ROOT` behind your back. `volume move` resolves its source through any
existing symlink too, so moving a volume that currently sits inside the
relocated directory works exactly like moving one that does not.

**You do not need `MACKAS_RELOCATE_VOLUMES=0` to do per-volume placement**, and
leaving it at `1` is the better default: it decides where the volumes you have
*not* moved live, and without it they sit on the internal boot disk. Set it to
`0` only if you intend to place every volume explicitly and would rather the
machine-wide symlink not point into this project's root at all (it is
machine-wide, one per Mac — `setup` warns, and offers, when it finds one
belonging to a *different* root).

#### What survives a reboot, and what happens when a drive is not there

A symlink is a plain filesystem object, so the placement survives reboots,
`setup` re-runs and daemon restarts without any state file to drift out of
sync.

If the drive it points at is **not mounted**, the symlink dangles and the
volume is simply unavailable — builds using it fail until the drive is back.
`mackas status` still prints the `moved to: <path>` line for it (the symlink is
read directly, so the target does not have to resolve), which is usually enough
to see immediately *which* disk is missing, though it will report the volume
itself as `[ no]` because the runtime can no longer see it. `mackas volume
list` prints the same `-> moved to:` note. `mackas volume recover` names it
outright: *"does not resolve to a volume.img"*.

One standing gap, and one hazard that is now refused rather than hit — both
established from the source rather than assumed:

- **`mackas check` does not mention per-volume placement at all.** It asks the
  container daemon whether each volume exists, so once that daemon has restarted
  with the drive absent it reports the volume as *"not created yet"* — true from
  the runtime's point of view, misleading from yours. Its free-space and
  `fstrim`-support checks likewise reason only about `MACKAS_ROOT`'s filesystem
  — correct when every image lives there, wrong once they are split across
  drives. Read those two check lines as being about the volumes you have *not*
  moved.
- **`setup` and `adopt` refuse to run with a drive missing** — they no longer
  create over it. The guard that protects an *existing* moved volume from
  being re-created over (`refuse_if_stale_entity`) spots the volume's
  `entity.json` through the symlink; that probe alone cannot see a *dangling*
  symlink, since `-e` follows symlinks and reads false through one, which used
  to let `setup` issue a plain `container volume create` for that name —
  orphaning whatever sat on the absent drive and handing back an empty volume
  (a mysteriously cold cache, for sstate or downloads). It now checks for the
  dangling link explicitly and dies instead, naming the recorded target and
  the two non-destructive fixes: plug the drive in, or `mackas volume recover
  <name>` if it really moved. Abandoning that copy and starting empty means
  removing the symlink yourself — mackas will not choose the destructive
  option for you. `tests/adopt.bats` pins the refusal, including that nothing
  is created over the link.

#### Adopting a root whose volumes are already split

`mackas adopt <path>` handles this case deliberately: it calls `volume recover`
*before* handing off to `setup`, so a per-volume symlink carried over from
another Mac is re-pointed at wherever the image really is on this one, rather
than `setup_volumes` treating "the runtime has never heard of this volume" as
licence to create a fresh, empty one over the top. In practice:

- A moved volume whose drive is mounted and whose symlink still resolves is
  adopted **in place**. `setup` then finds its `entity.json` through the
  symlink, restarts the container daemon so its index picks the volume up, and
  reports it as existing — no `volume create`, so the image is never
  reformatted.
- A symlink that points at *the other Mac's* path for the same drive (a
  different mount point, a renamed volume) dangles here. `recover` asks
  Spotlight, finds the image at its real local path, and — after you confirm —
  re-points it. This is the case worth knowing about, because it looks
  identical to "the volume is missing" until `recover` runs.
- Three volumes on three drives are handled independently; each keeps its own
  placement.

`tests/adopt.bats` covers all three, plus the whole-dir-relocation composition
above.

#### Caveats that do not go away

- **The one-VM rule still applies**, wherever an image lives. `volume move`
  refuses a volume a running build holds — moving the backing directory of a
  mounted ext4 image is exactly the double-life the rule forbids. Stop the
  build first.
- **A cross-drive move is a real copy, not a rename**, and takes as long as
  copying the image's current on-disk size. Only a same-filesystem move is the
  instant atomic `mv`. The source is removed only after the copy succeeds, so
  an interrupted move loses nothing — but budget the time, and run `mackas
  volume fstrim` first if the image has ratcheted up well past what it still
  holds.
- **`fstrim` reclaim is judged per drive.** The ExFAT behaviour above is a
  property of the *filesystem holding that one `volume.img`*, so a downloads
  volume parked on an ExFAT external will never hole-punch even though the
  other two, on APFS, reclaim fine. Format each drive APFS if you care about
  reclaim on it.
- **[Full Disk Access](#full-disk-access) applies to every external drive you
  use**, not just `MACKAS_ROOT`'s. The move itself is done by `mackas` under
  your own account, so it is the *daemon* reaching the relocated image
  afterwards that hits the TCC denial; a drive that was never used for a
  volume before is exactly where that bites.
- **Time Machine**: `check` only inspects `MACKAS_ROOT`'s volume for an active
  destination, so a build volume parked on a disk that *is* a Time Machine
  destination will not be flagged.

## Does `SSTATE_DIR` actually need ext4?

TMPDIR's ext4 requirement is semantic and non-negotiable. sstate and
downloads sit on their own ext4 volumes for lifecycle and speed — but nothing
in sstate's own read/write path *requires* ext4. The hash-equivalence
database mackas parks inside `SSTATE_DIR` is a different matter, and is the
actual blocker for moving `SSTATE_DIR` onto host APFS over virtiofs.

This is a source reading (openembedded-core at `4b73d7a5c5`, bitbake
alongside it), **not a measurement** — see the
[verdict](#verdict-and-what-is-still-unmeasured) for what remains open. What
the source establishes:

- **Writes stay inside `SSTATE_DIR`.** `sstate_create_and_sign_package`
  builds the tarball into a temp file created *in the destination directory*
  (`sstate.bbclass:875`) and publishes it with `os.link()` (`:817`). That
  hardlink is `SSTATE_DIR` → `SSTATE_DIR`, never TMPDIR → `SSTATE_DIR`, so
  there is no cross-filesystem hardlink to fail. `.siginfo` files go through
  `mkstemp` + `bb.utils.rename`, which already falls back to `shutil.move`
  on `EXDEV` (`bb/utils.py:2144`).
- **Reads are plain extractions.** `sstate_unpack_package` is
  `tar -I zstd -xvpf` (`sstate.bbclass:933`) into `WORKDIR`. The one
  `copyhardlinktree` (`:331`) runs TMPDIR → TMPDIR. Nothing hardlinks *out*
  of `SSTATE_DIR`.
- **No xattrs.** Neither the create (`:892`) nor the extract (`:933`) passes
  `--xattrs`.
- **Case collisions are theoretical.** Object names are a lowercase sha256
  plus `SSTATE_PKGSPEC` (`:14-41`); a collision needs two recipes differing
  only in the case of `PN`/`PV`/`PR`. `MACKAS_ROOT` is required to be
  case-sensitive anyway, which removes the question.
- **mtime is load-bearing, and works.** Every cache *hit* touches the object
  (`:979`, `:937-939`) — which is what makes `mackas sstate prune
  --older-than` meaningful. Note `oe.utils.touch` swallows `PermissionError`
  and `EROFS` silently (`oe/utils.py:542-550`), so a filesystem that refused
  `utimes` would make pruning over-delete rather than error.

### The blocker: `BB_HASHSERVE_DB_DIR`

The generated fragment sets `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` so the
hash-equivalence database outlives `clean` (see
[Volume caps](#volume-caps-and-the-disk-monitor)). That database is SQLite
opened in **WAL mode with `synchronous = OFF`** (`hashserv/sqlite.py:145`,
`cooker.py:363`), with one connection per client plus a backfill worker
(`hashserv/server.py:303,895`).

bitbake **hard-fatals** if that directory is on NFS (`cooker.py:330-337`,
citing SQLite's own locking FAQ) — but it detects NFS by comparing
`stat -f -c %T` against the literal string `nfs` (`bb/utils.py:2286`).
**virtiofs reports something else, so the guard would not fire while the
hazard class is the same.** Moving `SSTATE_DIR` to host APFS therefore means
giving that database its own home first — a small dedicated ext4 volume
preserves the survives-`clean` property; the TMPDIR volume does not, since
that is the one `clean` throws away.

### The failure mode to watch for

`sstate.bbclass:821` raises a loud `bb.fatal` when `os.link` fails with
`ENOSYS` — but `EPERM`/`EACCES`/`EOPNOTSUPP` are caught by the bare `except:`
on the next line, after which the write degrades to a **silent no-op**. A
build would succeed while populating nothing, and the symptom would show up
much later as a cache that never warms. Any experiment here has to check
that `SSTATE_DIR` actually grew, not merely that the build passed.

### Verdict, and what is still unmeasured

**Safe with caveats, on paper — untried in practice.** Nothing has been
measured: the two things that would decide it are both empirical — whether
`link(2)`, `utimes` and `rename` really behave on the virtiofs mount (and
fail loudly rather than silently if not), and what streaming hundreds of MB
of zstd tarballs over virtiofs on every reuse costs against the ext4 volume.
If the throughput cost is real it is paid on *every* build, against a
usability win (browsable, `rsync`-able, Time-Machine-able sstate) that only
matters occasionally. That trade, not correctness, is what should decide it —
and it stays an open question until someone runs it.

## HTTP mirrors — optional, and not just an NFS bridge

`mirror-server/mackas-mirrord` is a read-only HTTP server for
`SSTATE_MIRRORS`/`SOURCE_MIRROR_URL`. Its hardening is documented separately
in [mirror-server.md](mirror-server.md). It exists because the container
cannot mount NFS itself — the guest kernel has no NFS client (see
[below](#nfs-inside-the-container--a-dead-end)) — so something that *can*
reach the cache has to re-serve it over a protocol the container speaks.
Three topologies, one server; the threat model and the client config are
identical, only `--root` and the mirror URLs change:

1. **On a remote Linux host.** A machine that already has the cache — local
   to it, or NFS-mounted — re-serves it read-only over HTTP; the container
   reaches it over its vmnet NAT, egressing as the Mac's real IP. Nothing is
   mounted on the Mac, and nothing needs sudo.
2. **On the Mac, bridging an NFS export.** The container has no NFS client,
   but **macOS does**: mount the export on the Mac (`sudo mount_nfs -o
   ro,nfsvers=3,resvport nas:/export /Volumes/mirror` — one interactive
   sudo), point `mackas-mirrord` at the mount, and the container fetches over
   HTTP at the vmnet gateway. One machine, no second host, no virtiofs in
   the path. The container-to-Mac HTTP leg works (see
   [Serving local files](#serving-local-files-instead-of-bind-mounting-them));
   the server has not yet been run against a real NFS root — see
   [TODO.md](../TODO.md).
3. **[Serving purely local files](#serving-local-files-instead-of-bind-mounting-them)**,
   to avoid bind-mounting caches through virtiofs.

Turn it on with `MACKAS_USE_HTTP_MIRRORS=1`; `setup` writes the mirror
stanza into the generated kas fragment and `check` probes the mirror.

### Running the server

```sh
mackas-mirrord \
    --root sstate=/path/to/sstate-cache \
    --root downloads=/path/to/downloads \
    --port 8100 --allow <your-lan-cidr>
```

One file, Python 3.7+, standard library only — no pip, no venv, no install
step: run it straight from the checkout, or `scp` the one file to a remote
host. See `mirror-server/mackas-mirrord.service` for a hardened systemd unit
and `mirror-server/mackas-mirrord.conf.example` for the annotated config.

**One process, one port, two path prefixes** — not two servers on 8100/8101:
one privilege drop, one TLS context, one credential store, one unit to
harden. bitbake does not care — a path prefix distinguishes the mirrors as
well as a port does.

### The client config

Exactly what `MACKAS_USE_HTTP_MIRRORS=1` generates:

```
SSTATE_MIRRORS ?= "file://.* http://linux-computer.local:8100/sstate/PATH;downloadfilename=PATH"
SOURCE_MIRROR_URL ?= "http://linux-computer.local:8100/downloads"
INHERIT += "own-mirrors"
BB_GENERATE_MIRROR_TARBALLS ?= "0"
```

`downloadfilename=` is only meaningful for `http://` mirrors and is **not**
valid for `file://` ones, which is why the NFS stanza omits it. Override the
URLs with `MACKAS_HTTP_MIRROR_SSTATE` and `MACKAS_HTTP_MIRROR_DL` — for the
local topologies, point them at the vmnet gateway (`192.168.64.1`).

Enabling both `MACKAS_USE_HTTP_MIRRORS` and `MACKAS_USE_NFS_MIRRORS` is a hard
error: both emit `SSTATE_MIRRORS` into the same fragment, and `?=` would make
one silently win.

kas-container forwards `SSTATE_MIRRORS` and `KAS_PREMIRRORS` via `-e`, and
warns if the value contains `file:///`.

For Basic auth, **do not put credentials in the URL**. bitbake's fetchers and
wget read `~/.netrc`, and kas-container forwards `NETRC_FILE` into the
container:

```sh
cat > ~/.netrc <<'EOF'
machine linux-computer.local
  login builder
  password ...
EOF
chmod 600 ~/.netrc
export NETRC_FILE=~/.netrc
```

Caveat: a `DL_DIR` populated without `BB_GENERATE_MIRROR_TARBALLS = "1"`
lacks tarballs for scm checkouts, which makes the downloads mirror much less
useful than it looks. Check how the mirror's cache was built.

### Serving local files instead of bind-mounting them

The motivation is virtiofs, not the network. A bind-mounted
`DL_DIR`/`SSTATE_DIR` (`-v /path/on/mac:/downloads:ro`) crosses virtiofs on
every access. Running `mackas-mirrord` on the Mac itself, pointed at those
same directories, and fetching over HTTP sidesteps virtiofs for that traffic
— at the cost of HTTP's per-request overhead.

Whether the trade comes out ahead **has not been measured**. It is plausible:
sstate/downloads access is read-mostly and a mirror miss is cheap (a few
`open()`s and a 404 — see
[mirror-server.md](mirror-server.md#cost-of-a-miss)). A bind mount is simpler
and has one less moving part; treat this as an option for when virtiofs is
the specific thing you are avoiding, not a default.

The path works end-to-end — `mackas-mirrord` on the Mac, serving a local
directory, reached from inside a real `container run`, including Basic auth.
The operational details that matter:

- **Bind to `0.0.0.0` (or the vmnet-facing interface), not `127.0.0.1`.** The
  Mac's loopback is a different loopback than the container's; a `127.0.0.1`
  bind is unreachable from the container under any address.
- **Both the default gateway and the Mac's LAN IP work**, identically:
  ```sh
  # DIAGNOSTIC ONLY. These are raw `container` invocations, which normally
  # belong behind a mackas command or the sourced kas-container function --
  # a raw call attaches no volumes and bypasses the one-VM check. Reaching a
  # mirror touches no volume, so it is safe here, and there is no mackas
  # subcommand for "curl from inside a container".
  #
  # Apple container's default network is vmnet 192.168.64.0/24; the gateway
  # is the container's default route, found with `ip route` inside it.
  container run --rm alpine sh -c 'wget -qO- http://192.168.64.1:8100/sstate/somefile'
  container run --rm alpine sh -c 'wget -qO- http://<mac-lan-ip>:8100/sstate/somefile'
  ```
  The gateway is the more robust thing to hardcode: it does not change with
  the Mac's LAN IP or the active physical interface.
- **The macOS Application Firewall interferes on first run.** With the
  firewall on (the default), a not-yet-approved binary listening on a
  non-loopback address triggers an "allow incoming connections" prompt on the
  first inbound connection — visible in `log show --predicate 'process ==
  "socketfilterfw"'` as `doask: sending prompt for a filtering decision`.
  With nobody at the console to click Allow (headless SSH, a `launchd` agent
  with no GUI session), that connection and everything behind it **times out
  rather than failing fast** (`Not prompting user until existing response
  received`). One-time-per-binary: click Allow once, or pre-approve in
  *System Settings → Network → Firewall*. A real gotcha for unattended use.
- **Basic auth works over this path** exactly as documented above.

The recipe needs no new mackas code, since the URL knobs already exist:

```sh
# On the Mac, serving its own local caches:
mirror-server/mackas-mirrord \
    --root sstate="$SSTATE_DIR" --root downloads="$DL_DIR" \
    --bind 0.0.0.0 --port 8100 --allow 192.168.64.0/24

# In mackas.conf / --set:
MACKAS_USE_HTTP_MIRRORS=1
MACKAS_HTTP_MIRROR_SSTATE="http://192.168.64.1:8100/sstate"
MACKAS_HTTP_MIRROR_DL="http://192.168.64.1:8100/downloads"
```

This mirrors back into the same build what it already has locally, so there
is no benefit unless something else reads that cache too, or you are
deliberately trading a bind mount for virtiofs avoidance. For one Mac doing
one build, a plain local `SSTATE_DIR`/`DL_DIR` with no mirror is simplest.

## NFS inside the container — a dead end

**Do not try to mount NFS inside the container.** Apple `container`'s Kata
guest kernel (6.18.15) has **no NFS client compiled in**: `/proc/filesystems`
lists no `nfs`, and there is no `/lib/modules` to load one from. `mount -t
nfs` fails with `failed to prepare mount: No such device`. `--cap-add
SYS_ADMIN` does not help — it is not a permissions problem, the code is
absent. Only a custom guest kernel (`container run -k`) could change this.

## Bind-mounting a macOS NFS mount

The container has no NFS client of its own
([above](#nfs-inside-the-container--a-dead-end)), but macOS does: mount the
export on the host and bind-mount that mount into the container, where virtiofs
re-exports it. Two facts govern whether this is safe — the bind mount is
visible and correct from inside the container, and the host-side mount must be
NFSv3.

### Bind-mount visibility

```sh
sudo mount_nfs -o ro,nfsvers=3,resvport linux-computer:/export /Volumes/mirror
container run --rm -v /Volumes/mirror:/mnt:ro alpine ls /mnt
```

Against a real Linux NFS server (`nfsvers=3`, `crossmnt` enabled on the
export), `/mnt` inside the container lists every file at its correct size —
no truncation, and no empty directory despite host-side files. The
empty-directory outcome is the failure mode worth knowing about: virtiofs
re-exporting an NFS mount is exactly the kind of nested-filesystem case that
could silently yield nothing. It does not.

### NFSv4 on macOS — unsafe; pin `vers=3`

**Pin `vers=3` explicitly and treat NFSv4 on macOS as unusable here.** Mounting
the same export with `-o vers=4` instead **panics the machine** — kernel
panic and reboot, reproduced on macOS 26.5.1 against a Linux
`nfs-kernel-server` export. A userspace `mount` should never be able to crash
the kernel, this is not a client-side misconfiguration you can fix, and losing
the machine to a panic mid-build is a far worse failure than anything NFSv3's
age costs you.

This fits a long-standing macOS NFSv4-client fragility rather than
contradicting it. Reproducible kernel panics on NFSv4 mounts from Linux servers
go back to the OS X 10.10/10.11 era (the canonical report is a panic on
*editing* a file over an NFSv4 mount from a CentOS server, with NFSv3 the
standing workaround), and the same client stack has had confirmed kernel-level
memory-corruption bugs: **CVE-2018-4259** was a remotely triggerable heap
overflow in the macOS NFS client's `nfsm_chain_get_fh` file-handle path, fixed
only in macOS 10.13.6. macOS has also never shipped more than NFSv4.0 (no 4.1),
so NFSv4 has always been the less-trodden, less-hardened path on this OS.

`crossmnt` is not fully ruled out as the trigger — the reproduction export also
had `crossmnt` enabled, and the version bump was not tested independently of it
— but the evidence leans against it. macOS's own NFSv4 panic history needs no
`crossmnt` to explain it; the nearest documented "crossmnt + panic" precedent
elsewhere (an old RHEL kernel panic, patched in 2011) actually hinges on the
separate NFSv4 `refer`/referral mechanism, not `crossmnt` alone, a weak analogy
at best; and `vers=3` against that same `crossmnt` export mounted and
bind-mounted cleanly with no panic (the visibility result above) — though
`crossmnt`'s own cross-filesystem visibility did not behave as expected there,
a separate non-fatal quirk consistent with `crossmnt`'s general reputation.
This is not *proof* that v4 alone is the culprit — v4-without-crossmnt has
not been tried in isolation — so `vers=3` stays the safe rule regardless.

`MACKAS_USE_NFS_MIRRORS=1` bind-mounts an already-mounted host-side export
into the container, but it is off by default and unproven end-to-end. mackas
never performs the mount itself — `check` and the end of `setup` print the
exact `sudo mkdir` + `sudo mount -t nfs -o resvport,vers=3,ro,nolocks,locallocks`
pair and leave it to you, since it needs an interactive sudo. `check` verifies
the server is reachable, that `showmount -e` lists the export, and that this
host's IP is inside the export ACL — reporting the IP either way. To sidestep
the NFSv4 risk entirely, bridge an NFS cache over HTTP instead: mount on the
Mac and serve it with
`mackas-mirrord`, topology 2
[above](#http-mirrors--optional-and-not-just-an-nfs-bridge).

## Disk images on network shares

The ext4 `volume.img` the container mounts can in principle live on a network
share, but the container format and the share protocol both decide whether the
build survives:

- **A bare `volume.img` fully materializes over the network.** A 1G image ate
  the full 1G over NFS, versus 1.2 MB locally. Don't.
- **A sparsebundle stays sparse over the network** (macOS's band-based disk
  image format — the image is a directory of fixed-size band files, so only
  touched bands transfer; the same format Time Machine uses on network
  destinations) and works as the container: `hdiutil create -type SPARSEBUNDLE
  -fs "Case-sensitive APFS"` → attach → nest the ext4 `volume.img` inside →
  the container mounts it fine. This is the recipe both protocol assessments
  below use.

**Do not put TMPDIR on a network-backed image.** It is slower — 215 MB/s versus
368 MB/s local on 10GbE — but the real problem is that writes lazily flush to
network band files, so a link drop mid-build can corrupt an ext4 the guest
believes is committed. Sparsebundle-on-a-share is for overflow and archival
only. How badly this bites depends on the protocol.

### SMB: unreliable for a real build, not merely slower

**An SMB-backed TMPDIR corrupts real builds.** A from-scratch
`core-image-base` with its TMPDIR `volume.img` on SMB measures **+14.8 %**
slower than local, concentrated in `do_rootfs` (+72 %) and other
`fsync`-heavy tasks (full numbers and method in
[performance.md](performance.md#local-ssd-vs-a-network-share-for-the-working-volume))
— but that figure is only the floor, for the runs SMB happens to survive. On
the same host and same share, with nothing misconfigured differently, real
builds do not merely run slow: they corrupt the filesystem.

The corruption is reproducible and unrecoverable. Three independent real
`core-image-base`/`bash` attempts, each on a fresh volume and fresh
sparsebundle, all failed with I/O-integrity errors, though not identically:
`EUCLEAN` ("Structure needs cleaning") at the very first real write twice, then
a plain `EIO` ~1500 tasks / 5 minutes into a third — different code paths, same
underlying character. A post-failure `fstrim` couldn't even **mount** the ext4
fresh (`mount failed with errno 5`): real corruption, not an app-level retry
ext4 shrugged off.

Root cause is narrowed but not found. A simple write-burst is **not**
sufficient to reproduce it — writing 500-800 symlinks, or 1 GB of real file
content, directly to the same volume from the host with no bitbake involved,
repeatedly, never failed. Time Machine's periodic background probing
(`smbfs_vnop_ioctl` in the unified log every 30-90s) looks suspicious but the
share was already `tmutil`-excluded, so it is a red herring. Still unexplored,
for lack of tooling (no `dtrace`/`fs_usage`, no server-side SMB logs from the
NAS, no second SMB server to isolate something server-side): whether a
different SMB server, or a smaller sparsebundle band size, changes the
outcome. Until one of those is tried, treat SMB-backed TMPDIR as
**unreliable for a real build**, not merely slower.

### NFS: substantially more reliable, one like-for-like test short

**NFS via the same sparsebundle-nested ext4 recipe is substantially more
reliable than SMB for this use case** — two increasingly realistic builds, both
NFSv3, both with zero I/O errors and a clean post-build remount and `fstrim`,
the exact check that fails on SMB with `mount failed with errno 5`. Only NFSv3
has been exercised (NFSv4 is off the table regardless — see
[NFSv4 on macOS](#nfsv4-on-macos--unsafe-pin-vers3) above), and the export's
`crossmnt` setting was incidental, not a deliberate variable.

The stronger of the two data points is a genuine full compile.
`qualcomm-linux/meta-ai` (`main` branch, `kas/base.yml:kas/qemuarm64.yml`, its
own default target — `llama-cpp` + `tensorflow-lite` for `qemuarm64`) built
with empty `SSTATE_DIR`/`DL_DIR` volumes and TMPDIR on the NFS sparsebundle:
**4851 tasks, 0 % sstate reuse on every task type — a real compile, not a
cache replay — 41 minutes wall, zero I/O errors.** The volume grew to a real
10.1G on disk and **remounted and `fstrim`'d cleanly afterward with nothing
left to reclaim** — a well-formed filesystem, not one papering over
freed-but-dangling blocks. That is far closer to the scale that broke SMB,
which failed within 5 minutes on its worst run and immediately on two others.

The second, weaker data point points the same way: a short, sstate-warm
`meta-qcom`/`rb1-core-kit` `bash` smoketest (4603/4603 tasks, all from cache,
a bit over 2 minutes wall — most of it in the post-build `fstrim`'s extra
NFS-plus-sparsebundle discard hop, not in bitbake) grew the volume to
4.5-4.6 GiB and also **remounted and `fstrim`'d cleanly** (113.6 GiB trimmed
inside the guest, host 4.6G → 4.5G).

**The gap that remains:** neither test is fully like-for-like with the SMB
reproduction, which used `core-image-base` over several times more tasks and
hours of sustained image-build I/O. 41 minutes of mixed compiler/linker load is
substantial and sustained but not that duration class. NFS is the safer choice
on the evidence; an hours-long `core-image-base`-scale run on NFS is the one
comparison left to close the question outright.

## Buildstats and a constant BUILDNAME

`meta/classes-global/buildstats.bbclass` writes every build's per-task timing
under `tmp/buildstats/${BUILDNAME}/`. Two things about it matter here, both
straight from its source: `bb.utils.mkdirhier(bsdir)` only creates that
directory if missing — it never clears one that already exists — and
`build_stats` (the per-build summary at the root of it) is opened in
**append** mode at both `BuildStarted` and `BuildCompleted`, never truncated.

For a project whose `BUILDNAME` genuinely varies per build (bitbake's own
default is timestamp-based), that is harmless: each build gets a fresh,
uniquely-named directory. It stops being harmless the moment a distro
hardcodes `BUILDNAME` to something constant — as this project's own
`meta-angstrom/conf/distro/angstrom.conf` does:

```
BUILDNAME = "Angstrom ${DISTRO_VERSION}"
```

Every build ever run under that distro config writes into the exact same
`tmp/buildstats/Angstrom ${DISTRO_VERSION}/` directory, forever. Its
`build_stats` file accumulates one "Build Started"/"Elapsed time"/"CPU usage"
trio per build (append, never truncate), and every recipe's task files from
every past build just sit there too, since nothing ever removes them. A naive
read of that directory sums CPU/wall time across **every build that ever ran
there**, not just the latest one. The visible symptom is nonsensical
parallelism figures from `mackas buildstats analyze`: the correct, small
elapsed time for the latest build alongside a task-CPU total that is really
the sum of earlier builds' tasks too.

mackas handles this in three places:

- **`clear_buildstats_before_build`** (`MACKAS_BUILDSTATS_ACCUMULATE`, default
  `0` i.e. clearing is ON) runs before every `smoketest`/`shell` invocation
  and deletes `tmp/buildstats` in the TMPDIR volume first, so accumulation
  never has a chance to happen in normal use. Best-effort, like `fstrim`
  auto-run — a failure here can never fail the build.
- **`mackas retrieve buildstats`** copies each retrieval into its own
  timestamped subdirectory (`buildstats/<retrieve-time>/<BUILDNAME>/`), so
  even if bitbake's own directory is shared across builds, successive
  *retrievals* never merge into the same host path on top of each other.
  It also checks the just-retrieved `build_stats` for more than one "Build
  Started:" line — an ironclad sign the directory it just copied really is
  shared — and, if found, warns and offers (confirm()-gated, never automatic)
  to clear that BUILDNAME directory in the volume.
- **`tools/mackas-buildstats-analyze`** filters task files to
  `start >= build["started"]` whenever the retrieved `build_stats` itself
  shows more than one "Build Started:" line, so a summary of already-shared
  data still reflects only the latest build, and says so explicitly in its
  output. This is for data that predates `clear_buildstats_before_build`,
  or for `MACKAS_BUILDSTATS_ACCUMULATE=1`.

Set `MACKAS_BUILDSTATS_ACCUMULATE=1` if you actually want `tmp/buildstats` to
keep accumulating across builds and will manage it yourself.

## Buildhistory, and the volume it lives in

`meta/classes/buildhistory.bbclass` records what each build actually
produced — package and image contents, sizes, runtime dependencies, sysroot
listings — under `BUILDHISTORY_DIR`, which it defaults to
`${TOPDIR}/buildhistory`. Two consequences follow from that default on this
setup, and neither is obvious from the OpenEmbedded side.

**It is not under `tmp/`.** `TOPDIR` inside the container is `/build`, the
mount point of the whole `oe-build-tmp` volume, and `TMPDIR` is `/build/tmp`
within it. So buildhistory lands at `/build/buildhistory` — a *sibling* of
everything else `mackas retrieve` copies out, not a child of `tmp/`. Retrieval
resolves the path from `bitbake-getvar BUILDHISTORY_DIR` like every other
object, so a project that redefines it is followed correctly; the class
default is only the fallback used when the query cannot run.

**Bare `mackas clean` drops it.** Bare `clean` deletes and recreates the whole
TMPDIR volume, and `/build/buildhistory` is inside that volume — so the entire
history goes with it, silently, however many builds it spans. Nothing warns at
`clean` time, because from the volume's point of view this is exactly the
requested operation. Three ways to keep it:

```sh
./mackas retrieve buildhistory      # copy it to $MACKAS_BASE/artifacts first
./mackas clean tmp+deploy           # clears TMPDIR/DEPLOY_DIR in place instead
                                    # of recreating the volume -- buildhistory
                                    # (and conf/) stay put
```

or set `BUILDHISTORY_DIR` to a path that outlives the volume — e.g. under
`SSTATE_DIR` (`/sstate`, its own volume, untouched by any of the above) — in
the same place you inherit the class.

**It records nothing unless you ask for it.** buildhistory is not inherited by
default; without `INHERIT += "buildhistory"` in your kas config's
`local_conf_header` or `conf/local.conf`, the directory never exists. That is
the overwhelmingly likely reason `mackas retrieve buildhistory` finds nothing,
so it says so in those terms rather than reporting a missing directory. mackas
does **not** turn the class on for you: the generated `kas/macos-local.yml`
fragment carries macOS and Apple-container tuning only, and what a build
records is a project decision that belongs in the project's own config, where
everyone building it sees the same thing.

The retrieved copy is a plain directory on the Mac, and a git repository when
`BUILDHISTORY_COMMIT` is on — one commit per build, readable with ordinary
`git -C $MACKAS_BASE/artifacts/buildhistory log`, no container needed.

**`mackas buildhistory analyze`** turns that git history into a digest
instead of a manual `git log`/`git diff` session: recipes
added/removed/upgraded, the biggest `PKGSIZE` movers, and per-image
`IMAGESIZE`/installed-package deltas, read via host `git` plumbing (`git
diff --name-status` plus one `git cat-file --batch` — no container, no
bitbake, cost proportional to what changed rather than the size of the
tree). `PKGSIZE` and `IMAGESIZE` are both already recorded in KiB
(buildhistory.bbclass's own convention — `IMAGESIZE` comes from `du -ks`),
not bytes. A package-size change is listed only past >1% or >64 KiB;
smaller changes are still counted into the net total. `--detail`
additionally runs openembedded-core's own `scripts/buildhistory-diff`
inside a throwaway kas-image container for the per-field semantics
(`RDEPENDS` version-constraint comparisons, unified diffs of
`pkg_postinst`, ...) that the summary deliberately does not reimplement;
best-effort, since it needs a checkout under `$MACKAS_ROOT/work` with
bitbake and `scripts/buildhistory-diff` reachable under it. `retrieve
buildhistory` runs the summary layer automatically on what it just
copied — never `--detail`, and never affecting `retrieve`'s own exit
code — so a routine `mackas retrieve buildhistory` already answers "what
did this build change" without a separate step. With `BUILDHISTORY_COMMIT`
off there is no per-build history to diff, so this reports the CURRENT
state instead (recipe/package/image counts and sizes, no comparison).

## SPDX/SBOM output — `DEPLOY_DIR_SPDX`

`meta/classes/create-spdx.bbclass` (and its version-specific subclasses
`create-spdx-3.0.bbclass` / `create-spdx-2.2.bbclass`) produces SPDX SBOM
output — one `.spdx.json` file per recipe and per package — under
`DEPLOY_DIR_SPDX`, which is defined by `meta/classes/spdx-common.bbclass` as
`${DEPLOY_DIR}/spdx/${SPDX_VERSION}`. The `${SPDX_VERSION}` component varies
across releases (3.0.1 on current trunk, 2.2 on older releases, `${MACHINE}` on
kirkstone), so the trailing component is never substituted by mackas — the real
answer always comes from `bitbake-getvar DEPLOY_DIR_SPDX`.

**It lives under `DEPLOY_DIR`, which may be under `tmp/` or off the volume.** On
OE-core defaults it is `/build/tmp/deploy/spdx`, but Angstrom's distro config
points `DEPLOY_DIR` to `/build/deploy` (outside `tmp/`), so the SPDX tree lands
at `/build/deploy/spdx` there. Bare `mackas clean tmp+deploy` clears both,
silently dropping the SPDX tree if you have not retrieved it first — the same
hazard as `deploy/` itself.

**It is inherited by default on modern OE-core.** `meta/conf/distro/defaultsetup.conf`
includes `create-spdx` in `INHERIT_DISTRO`, so SBOM output appears on any build
unless a distro explicitly drops the class. Older releases did not have it (SPDX
support was added to OE-core over time), so `mackas retrieve sbom` finding
nothing usually means either no build has run yet, or this is a release predating
create-spdx. If the class is inherited but the output is missing, it may mean
the build never reached a task that produces SPDX (e.g. a kernel-only build that
skips recipes with do_create_spdx or similar).

Unlike the per-image SBOM — which create-spdx-image-3.0.bbclass deploys
alongside the images into `DEPLOY_DIR_IMAGE` — the full recipe/package tree
lands in `DEPLOY_DIR_SPDX` and is brought out with `mackas retrieve sbom`.

## The workspace image

`work/` — `KAS_WORK_DIR`, the layer checkouts: oe-core, bitbake, the `meta-*`
layers, the project layer — is the one part of `MACKAS_ROOT` that must be
case-sensitive, because oe-core contains files whose names differ only by
case. It is a plain host directory bind-mounted into the container, not an
ext4 volume, so the host filesystem's rules apply to it directly. `bin/`,
`kas/` and `logs/` are indifferent.

A stock external SSD is case-insensitive APFS and reformatting is not always
an option, so `setup` offers a case-sensitive APFS **sparse image** mounted at
`work/` instead:

```sh
hdiutil create -type SPARSE -fs "Case-sensitive APFS" -size 40g \
    -volname mackas-workspace /Volumes/<drive>/oe/workspace
hdiutil attach /Volumes/<drive>/oe/workspace.sparseimage -nobrowse
```

That is what `setup` runs (size from `MACKAS_WORKSPACE_SIZE`, sparse, so the
cap is not disk cost), after moving any existing `work/` aside and before
copying it back onto the fresh mount. The image is host-native APFS, so it
reuses the same bind-mount `/repo` already goes through — no ext4, no `mkfs` —
and `git status` in a layer still works from a macOS terminal.

`work/` becomes a **symlink** to the mount point (`/Volumes/mackas-workspace`),
never a mount point of its own. `hdiutil attach -mountpoint` onto a directory
that itself sits on a non-APFS volume fails with "insufficient privileges",
while a plain attach works regardless of what `MACKAS_ROOT` sits on — so
mackas reads the real mount point out of `hdiutil`'s output and symlinks to
it. macOS uniquifies a colliding volume name (`mackas-workspace 2`), which is
the other reason the reported path is read rather than assumed.

### The attach lifecycle, and why it fails closed

**`hdiutil attach` does not survive a reboot.** After a restart the image file
is still on disk but nothing is mounted: `work/` is a dangling symlink, or —
if anything recreated it — an ordinary empty directory on the case-insensitive
drive. That is the dangerous state, because it looks like a fresh workspace. A
command falling through to it lets kas clone oe-core onto case-insensitive
APFS, silently, since the `setup`-time case-sensitivity gate already passed
once.

`MACKAS_WORKSPACE_IMAGE` — written by `setup` when it creates or reattaches an
image — is what makes that recoverable. With it set, every command that
touches `work/` first compares the device of `work/` against `MACKAS_ROOT`'s
and looks for a `.mackas-workspace` sentinel file at the mount's root, then:

| State | What happens |
|---|---|
| Different device, sentinel present | Already attached. Nothing to do. |
| Same device, or `work/` missing or a dangling symlink | Reattach the image and re-point the symlink. |
| Different device, **no** sentinel | Refuse: something is mounted at `work/`, but not the recorded image. |
| Image file missing | Refuse. `mackas volume recover` (no name needed) locates it with Spotlight and offers to move it back. |
| `hdiutil attach` fails | Refuse. |
| `work/` is a **non-empty plain directory** | Refuse, and leave it alone: its contents were written to a case-insensitive filesystem and may already be corrupt, but they are yours to salvage. |

The sentinel is what makes "something is mounted" mean "*our* image is
mounted". Without it any coincidental mount at `work/` reads as success — and
reattaching over it would destroy that mount's contents. An image predating
the sentinel is adopted with a single `touch <mount>/.mackas-workspace`, which
is what the refusal says.

Refusing is deliberate and has no override flag: an unattached workspace is
not an empty workspace, it is the wrong filesystem. `check` and `status`
report the state without ever mounting anything, so a build that "worked
yesterday" and now refuses has its answer in one line of `mackas check`.
`status` also reports the image's real size on disk (`du -h`, sparse-aware,
the same idiom the ext4 volumes' own status line uses).

**Recovering a missing image.** Unlike an ext4 volume, the workspace image has
no runtime symlink to re-point — `MACKAS_WORKSPACE_IMAGE` itself is the
record. `mackas volume recover` (no `<name>` needed; naming one ext4 volume
explicitly skips the workspace check) locates a missing image by filename with
Spotlight, refuses to guess if more than one candidate turns up, and — after
confirmation — moves the found file back to the recorded path with the same
holes-preserving copy `volume move` uses, rather than chase it wherever it
ended up. Declining prints the found path so it can be adopted instead
(`mackas set MACKAS_WORKSPACE_IMAGE <path>`).

Losing the image costs nothing for any layer that is clean and pushed —
`git clone` restores it byte for byte. What is genuinely at risk is
uncommitted or unpushed work, and `git push` is the backup story: the image is
a single file with none of its own. `status` says so directly when it
matters: while the image is attached, it counts the git repos one level under
`work/` that are dirty or ahead of their upstream and prints one line naming
how many — silent when the count is zero, or the image is not attached (there
is nothing safe to inspect through the wrong filesystem). Time Machine cuts
the opposite way here from the build volumes: the image is small (source
checkouts, single-digit GiB) and holds the only copy of exactly what git
cannot restore, so a TM-backed source volume is a feature rather than the
hazard [below](#time-machine).

## Time Machine

If the volume holding `MACKAS_ROOT` is an active Time Machine destination,
the build and the backups compete for the same free space — and a build that
fills the disk stops backups working (Time Machine starts thinning old
snapshots to make room, losing backup history). `check` detects an active
destination and warns loudly. The volume caps above are the mitigation; if
the margin is still uncomfortable, shrink `MACKAS_VOLUME_SIZE_*` or point
Time Machine at a different disk (`tmutil removedestination`).

Note the [per-volume caveat](#caveats-that-do-not-go-away): `check` only
inspects `MACKAS_ROOT`'s volume, so a volume moved to a disk that is itself a
Time Machine destination is not flagged.

## Full Disk Access

Creating a container volume on an **external** disk can fail with `Operation
not permitted` when the Apple `container` daemon has not been granted Full
Disk Access under System Settings → Privacy & Security. The symptom looks
nothing like a permissions problem — it is not an `EACCES` on the path you
named, but a TCC denial (macOS's per-binary privacy gating, enforced outside
ordinary Unix permissions) on the daemon reaching the external volume — so it
is easy to chase in the wrong direction for an afternoon.

The fix is to grant Full Disk Access to the daemon binary. Its location is
**not** fixed: a Homebrew install and Apple's signed `.pkg` install put
`container-apiserver` in different places (a versioned Cellar path vs
`/usr/local/libexec/container-apiserver`), so any tooling or instruction here
must **derive** the path rather than hardcode it. This is not yet automated;
see [TODO.md](../TODO.md).
