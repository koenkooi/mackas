# Storage plan

Where each piece of the build lives, and why. The short version:

| What | Where | Why |
|---|---|---|
| **TMPDIR** | Local ext4 container volume, on local disk | **Non-negotiable.** APFS over virtiofs lacks the semantics — see [architecture.md](architecture.md#the-ext4-volumes). |
| **Writable `SSTATE_DIR` / `DL_DIR`** | Their own local ext4 volumes | Speed, and lifecycle: separate so `clean` can drop TMPDIR without losing them. Unlike TMPDIR, ext4 here is not a *semantic* requirement — see [Does `SSTATE_DIR` actually need ext4?](#does-sstate_dir-actually-need-ext4-desk-check-not-yet-measured) |
| **Read-only sstate + downloads mirrors** | Network, over **HTTP** | **Optional.** bitbake's own mechanism, recommended if you use one. |

`MACKAS_ROOT` is wherever you point it — a directory on a case-sensitive
volume, e.g. `/Volumes/<your-case-sensitive-volume>/oe`. Everything else
hangs off it or lives in the container volumes.

**Mirrors are entirely optional.** With none configured
(`MACKAS_USE_HTTP_MIRRORS=0`, `MACKAS_USE_NFS_MIRRORS=0` — both the default),
mackas fetches from upstream and populates `SSTATE_DIR`/`DL_DIR` locally,
exactly like a stock `kas-container` checkout. A mirror only matters for
reusing *someone else's* cache; nothing about `setup`, `smoketest`, or a real
build requires one.

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
   the path. The container-to-Mac HTTP leg is
   [verified](#serving-local-files-instead-of-bind-mounting-them); the
   server has not yet been run against a real NFS root — see
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
SSTATE_MIRRORS ?= "file://.* http://linux-computer:8100/sstate/PATH;downloadfilename=PATH"
SOURCE_MIRROR_URL ?= "http://linux-computer:8100/downloads"
INHERIT += "own-mirrors"
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
machine linux-computer
  login builder
  password ...
EOF
chmod 600 ~/.netrc
export NETRC_FILE=~/.netrc
```

Caveat: a `DL_DIR` populated without `BB_GENERATE_MIRROR_TARBALLS = "1"`
lacks tarballs for scm checkouts, which makes the downloads mirror much less
useful than it looks. Check how the mirror's cache was built.

## Serving local files instead of bind-mounting them

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

**Verified end-to-end**: `mackas-mirrord` run on the Mac, serving a local
directory, reached from inside a real `container run`, including Basic auth.
Findings:

- **Bind to `0.0.0.0` (or the vmnet-facing interface), not `127.0.0.1`.** The
  Mac's loopback is a different loopback than the container's; a `127.0.0.1`
  bind is unreachable from the container under any address.
- **Both the default gateway and the Mac's LAN IP work**, identically:
  ```sh
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

### Bind-mount visibility — verified

```sh
sudo mount_nfs -o ro,nfsvers=3,resvport linux-computer:/export /Volumes/mirror
container run --rm -v /Volumes/mirror:/mnt:ro alpine ls /mnt
```

**Verified end-to-end** against a real Linux NFS server (`nfsvers=3`,
`crossmnt` enabled on the export): from inside Apple's `container` runtime,
`/mnt` listed every file at its correct size — no truncation, and no **empty
`/mnt` despite host-side files**. That empty-directory outcome was the risk
worth checking: virtiofs re-exporting an NFS mount is exactly the kind of
nested-filesystem case that could have silently yielded nothing. It didn't.

### NFSv4 on macOS — unsafe; pin `vers=3`

**Pin `vers=3` explicitly and treat NFSv4 on macOS as unusable here.** Mounting
the same export with `-o vers=4` instead **panicked the machine** — kernel
panic and reboot, reproduced 2026-07-20 on macOS 26.5.1 against a Linux
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
bind-mounted cleanly with no panic (the verification above) — though
`crossmnt`'s own cross-filesystem visibility did not behave as expected there,
a separate non-fatal quirk consistent with `crossmnt`'s general reputation.
This is not yet *proof* that v4 alone is the culprit — v4-without-crossmnt has
not been tried in isolation — so `vers=3` stays the safe rule regardless.

`MACKAS_USE_NFS_MIRRORS=1` implements the host-side mount, but it is off by
default and unproven end-to-end. `check` verifies the server is reachable, that
`showmount -e` lists the export, and that this host's IP is inside the export
ACL — reporting the IP either way. To sidestep the NFSv4 risk entirely, bridge
an NFS cache over HTTP instead: mount on the Mac and serve it with
`mackas-mirrord`, topology 2
[above](#http-mirrors--optional-and-not-just-an-nfs-bridge).

## Disk images on network shares

The ext4 `volume.img` the container mounts can in principle live on a network
share, but the container format and the share protocol both decide whether the
build survives:

- **A bare `volume.img` fully materializes over the network.** A 1G image ate
  the full 1G over NFS, versus 1.2 MB locally. Don't.
- **A sparsebundle stays sparse over the network** (band-based, like Time
  Machine) and works as the container: `hdiutil create -type SPARSEBUNDLE -fs
  "Case-sensitive APFS"` → attach → nest the ext4 `volume.img` inside → the
  container mounts it fine. This is the recipe both findings below use.

**Do not put TMPDIR on a network-backed image.** It is slower — 215 MB/s versus
368 MB/s local on 10GbE — but the real problem is that writes lazily flush to
network band files, so a link drop mid-build can corrupt an ext4 the guest
believes is committed. Sparsebundle-on-a-share is for overflow and archival
only. How badly this bites depends on the protocol.

### SMB: unreliable for a real build, not merely slower

**An SMB-backed TMPDIR corrupts real builds — this supersedes the earlier
"just slower" reading.** A from-scratch `core-image-base` with its TMPDIR
`volume.img` on SMB first measured **+14.8 %** slower than local, concentrated
in `do_rootfs` (+72 %) and other `fsync`-heavy tasks (full numbers and method
in
[performance.md](performance.md#local-ssd-vs-a-network-share-for-the-working-volume)).
Re-verified 2026-07-20 on the same host and same share, nothing misconfigured
differently, it did not merely run slow — it corrupted the filesystem. Take
+14.8 % as the floor for the runs SMB happens to survive, and the "link drop
mid-build" corruption above as real and not rare.

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
(`smbfs_vnop_ioctl` in the unified log every 30-90s) looked suspicious but the
share was already `tmutil`-excluded, so it is a red herring. Left unexplored
for lack of tooling in that investigation (no `dtrace`/`fs_usage`, no
server-side SMB logs from the NAS, no second SMB server to isolate something
server-side): whether a different SMB server, or a smaller sparsebundle band
size, changes the outcome. Until one of those is tried, treat SMB-backed
TMPDIR as **unreliable for a real build**, not merely slower.

### NFS: substantially more reliable, one like-for-like test short

**NFS via the same sparsebundle-nested ext4 recipe looks substantially more
reliable than SMB for this use case** — two increasingly realistic builds, both
NFSv3, both with zero I/O errors and a clean post-build remount and `fstrim`,
the exact check that fails on SMB with `mount failed with errno 5`. Only NFSv3
was exercised (NFSv4 is off the table regardless — see
[NFSv4 on macOS](#nfsv4-on-macos--unsafe-pin-vers3) above), and the export's
`crossmnt` setting was incidental, not a deliberate variable.

The stronger of the two is a genuine full compile. `qualcomm-linux/meta-ai`
(`main` branch, `kas/base.yml:kas/qemuarm64.yml`, its own default target —
`llama-cpp` + `tensorflow-lite` for `qemuarm64`) built with empty
`SSTATE_DIR`/`DL_DIR` volumes and TMPDIR on the NFS sparsebundle: **4851 tasks,
0 % sstate reuse on every task type — a real compile, not a cache replay — 41
minutes wall, zero I/O errors.** The volume grew to a real 10.1G on disk and
**remounted and `fstrim`'d cleanly afterward with nothing left to reclaim** — a
well-formed filesystem, not one papering over freed-but-dangling blocks. That
is far closer to the scale that broke SMB, which failed within 5 minutes on its
worst run and immediately on two others.

An earlier, weaker check pointed the same way and is subsumed by the above: a
short, sstate-warm `meta-qcom`/`rb1-core-kit` `bash` smoketest (4603/4603
tasks, all from cache, a bit over 2 minutes wall — most of it in the post-build
`fstrim`'s extra NFS-plus-sparsebundle discard hop, not in bitbake) grew the
volume to 4.5-4.6 GiB and also **remounted and `fstrim`'d cleanly** (113.6 GiB
trimmed inside the guest, host 4.6G → 4.5G).

**The gap that remains:** neither test is fully like-for-like with the SMB
reproduction, which used `core-image-base` over several times more tasks and
hours of sustained image-build I/O. 41 minutes of mixed compiler/linker load is
substantial and sustained but not that duration class. NFS is the safer choice
on the evidence; an hours-long `core-image-base`-scale run on NFS is the one
comparison left to close the question outright.

## Volume caps and the disk monitor

The fixed-size volumes are the outer bound: a runaway build cannot grow past
its own cap, so it cannot eat the rest of the disk. Inside each volume, the
generated kas fragment also sets `BB_DISKMON_DIRS` to **HALT** the build at
2 GiB / 100k inodes free on `${TMPDIR}`, `${DL_DIR}` and `${SSTATE_DIR}` — a
backstop for the build, not for the disk, since a full volume cannot reach
past its own cap.

> **Generating `BB_DISKMON_DIRS` — a multi-line, backslash-continued value —
> is genuinely fiddly.** An earlier `setup_kas_fragment()` built it inline in
> an unquoted heredoc, which mangled it on disk into one line: bash treats a
> literal `\` immediately before a real newline in an unquoted heredoc as a
> line continuation and **splices it away**, even when that `\` came from
> unescaping a typed `\\`. It is now built as its own single-quoted variable
> (no escape processing) and interpolated as a plain parameter expansion,
> which cannot re-trigger the splice. `tests/volumes.bats` asserts the
> *exact* multi-line form on disk — the mangled form would have passed a
> substring-only check, which is exactly how it shipped.

The fragment also sets `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"`: without it,
the hash-equivalence database defaults into the per-build `/build` volume,
which `mackas clean` throws away — discarding sstate reuse on every `clean`,
not just TMPDIR — instead of living alongside the sstate it indexes. This is
set in the fragment's `local_conf_header`, **not** via kas-container's own
`BB_HASHSERVE_DB_DIR` forward, which bind-mounts a *host* directory and would
put the database straight back on APFS over virtiofs.

`container` v1.1.0 has no config knob for the volume storage root, so
`MACKAS_RELOCATE_VOLUMES=1` symlinks the whole volumes directory onto the
build disk to keep `volume.img` off the internal disk.

### Reclaiming disk from a grown volume (`mackas volume fstrim`)

A sparse ext4 `volume.img` is a **ceiling that only ratchets up**. It costs
~1.2 MB empty and grows as the guest writes, but deleting files inside the
guest never shrinks it back: the freed blocks stay allocated on the host image.
A TMPDIR volume that peaked mid-build stays at that peak on disk even after
`clean` empties it logically. Whenever disk headroom is tight — a smaller SSD,
a disk shared with other work — that reclaim matters.

The fix is `mackas volume fstrim <name>` (or `mackas volume fstrim all` for
the three mackas volumes -- `all` is a plain positional argument, not a
`--all` flag). It runs `fstrim` **inside the guest**, which issues ext4 DISCARDs;
Apple's own tooling never triggers a discard, but the hypervisor's virtio-blk
backend implements DISCARD as a host **hole-punch** (the guest's
`discard_max_bytes` is non-zero), so the punched blocks become sparse again on
the host `volume.img`. Measured: an 800M image with 600M deleted inside fell to
202M in 0.01s.

Two details matter here — get either one wrong and the reclaim silently does
nothing:

- The `fstrim` container needs **both** `-u 0:0` **and** `--cap-add
  CAP_SYS_ADMIN`. Neither alone works — a non-root user and a capless root both
  get `EPERM` on the `FITRIM` ioctl. (`util-linux fstrim` already ships in the
  kas image.)
- The reclaimed figure mackas prints is a **re-measurement of `du` on
  `volume.img`, before minus after** — not `fstrim`'s own "N bytes trimmed",
  which reports guest *free* space (it printed 882 MiB for that 600 MB reclaim)
  and which APFS block-sharing would make a lie anyway.

`hdiutil compact` does **not** work on these raw ext4 images — it returns
`Function not implemented` — so `fstrim` from inside the guest is the only path.
The **one-VM rule** applies: `fstrim` refuses a volume a running build holds
rather than attach an ext4 image to a second VM.

**Discard support depends on what filesystem `MACKAS_ROOT` sits on, not on
mackas or `container` itself.** `container volume`'s storage root
(`~/Library/Application Support/com.apple.container/volumes`) is a symlink
mackas plants into `MACKAS_ROOT/container-volumes` (there is no config knob
for this in `container` 1.1.0, so relocation is the only way to get these
off the boot APFS volume) — so every `volume.img` physically lives on
whatever disk/partition `MACKAS_ROOT` is on, and that host filesystem is
what actually has to support DISCARD for `fstrim` to hole-punch anything.

Measured live: `MACKAS_ROOT` on a case-sensitive **APFS** volume reclaims
space exactly as described above. `MACKAS_ROOT` on an **ExFAT** volume fails
every `fstrim` with `the discard operation is not supported` /
`discard_max_bytes=0` — on a completely fresh, just-created volume, not just
old ones, which rules out a stale-volume or mackas-side cause. ExFAT does not
support sparse-file hole-punching, so Apple's Virtualization.framework
correctly reports no DISCARD support for a `volume.img` backed by it; this is
an accurate reflection of the host filesystem, not a bug to work around.

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
(a copy-on-write clone where possible, else a plain sparse copy) and removes the
source only after the copy succeeds. A plain `mv` across filesystems would
instead balloon the sparse image to its full logical size, so `mackas` never
uses one here.

Destroying a moved volume also cleans up that per-volume symlink. The runtime's
own `volume delete` removes the volume but leaves the symlink `move` planted
dangling at a now-nonexistent target (confirmed live) — harmless, nothing reads
it, but confusing to find by hand — so `mackas volume destroy`/`clean` removes
it after a successful delete.

If you move an image by hand and the symlink goes stale, `mackas volume
recover [<name>]` finds it again: it asks **Spotlight** (`mdfind`) for a
`volume.img` under a directory named for the volume with an `entity.json`
sibling, and — after you confirm — re-points the symlink. One match is offered;
several are listed for you to pick; none, and it checks whether the disk is even
indexed (`mdutil -s`) before telling you to re-point by hand. Nothing changes
without confirmation.

An external volume's top level is typically `root:wheel`, so creating
`$MACKAS_ROOT` needs a one-off `sudo mkdir` + `sudo chown`. `setup` prompts
for exactly that and nothing more.

### Growing a volume (`mackas volume resize`)

A volume's size is fixed at creation — `setup` never resizes an existing one,
and Apple `container` v1.1.0 has no grow command — so a cap chosen months ago
used to be permanent short of destroy-and-recreate, which costs the whole
cache. `mackas volume resize <name> <size>` grows one in place instead.

What the daemon actually keeps on disk is what makes this possible:

```
$CONTAINER_VOLUMES_DIR/<name>/
  entity.json   {…,"sizeInBytes":53687091200,…,"options":{"size":"50G"}}
  volume.img    a SPARSE file whose apparent size equals sizeInBytes
```

so growing is three facts that must move together:

1. **Extend the sparse image.** Free — no blocks are allocated until written.
2. **Record the new size** in `entity.json` (both `sizeInBytes`, which is what
   gets attached, and `options.size`, which is what `container volume ls` and
   therefore `mackas status` report), then **restart the daemon**. Its volume
   index is built once, at its own startup, so a file edited underneath it is
   invisible until then — the restart is part of the recipe, not a nicety.
3. **Grow the ext4 filesystem** with `resize2fs`, online, against the mounted
   volume.

Doing only some of these is a silent no-op: truncating alone leaves the daemon
attaching the old size, and a bigger block device with the same-sized
filesystem on it gains exactly nothing. mackas does all three or refuses.

**Free space is reported against the drive the image really lives on**
(`volume_real_dir`, so a moved volume is measured on *its* disk, not
`MACKAS_ROOT`'s), and a growth that drive cannot back is warned about rather
than blocked — because sparse images make that failure arrive late. The
truncate succeeds today; the build discovers the missing space weeks later,
mid-task, which is the expensive moment to find out.

**Shrinking is refused**, and not just unimplemented: `resize2fs` cannot shrink
a *mounted* filesystem, and a container volume can only be attached mounted —
the loop-device route needs `--privileged`, which Apple `container` does not
have. A smaller volume means copying into a new one (`volume duplicate` then
`volume destroy`).

> **Not yet verified against the real runtime.** The mechanism above is derived
> from the on-disk format observed on a live install and is covered by
> hermetic tests, but no real volume has been grown yet. Two things are
> genuinely unknown until someone does: whether the daemon re-reads a
> hand-edited `entity.json` on restart exactly as `refuse_if_stale_entity`
> already assumes it does, and whether the kas image ships `resize2fs`
> (`e2fsprogs`) at all — mackas checks for it inside the container and says so
> rather than failing obscurely. If step 3 fails, the volume is left intact and
> usable at its old capacity, with steps 1–2 already done and idempotent, so a
> retry costs nothing.

### Three drives, one build: TMPDIR, sstate and downloads apart

The three volumes look alike — three sparse ext4 images — but they are used in
completely different ways, so on a Mac with more than one disk they do not all
want the *same* disk:

| Volume | Mounted as | Access pattern | What losing it costs |
|---|---|---|---|
| `<name>-tmp` | `/build` (`TMPDIR`) | The hot one. Every task's work directory, sysroots, packaging and compile output, written and re-written throughout a build; the image that grows fastest and peaks highest. | Nothing you can't rebuild — `mackas clean` deliberately throws this volume away and recreates it. |
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
`setup` re-runs and `container system restart` without any state file to drift
out of sync.

If the drive it points at is **not mounted**, the symlink dangles and the
volume is simply unavailable — builds using it fail until the drive is back.
`mackas status` still prints the `moved to: <path>` line for it (the symlink is
read directly, so the target does not have to resolve), which is usually enough
to see immediately *which* disk is missing, though it will report the volume
itself as `[ no]` because the runtime can no longer see it. `mackas volume
list` prints the same `-> moved to:` note. `mackas volume recover` names it
outright: *"does not resolve to a volume.img"*.

Two honest gaps here, both verified in the source rather than assumed:

- **`mackas check` does not mention per-volume placement at all.** It asks the
  container daemon whether each volume exists, so once that daemon has restarted
  with the drive absent it reports the volume as *"not created yet"* — true from
  the runtime's point of view, misleading from yours. Its free-space and
  `fstrim`-support checks likewise reason only about `MACKAS_ROOT`'s filesystem
  — correct when every image lives there, wrong once they are split across
  drives. Read those two check lines as being about the volumes you have *not*
  moved.
- **Neither `setup` nor `adopt` refuses to run with a drive missing.** The
  guard that protects an *existing* moved volume from being re-created over
  (`refuse_if_stale_entity`, which spots the volume's `entity.json` through the
  symlink) cannot see through a *dangling* symlink, so `setup` goes on to issue
  a plain `container volume create` for that name. What the real runtime does
  with that create has not been verified — do not find out; plug the drive in
  first. `tests/adopt.bats` pins this behaviour as it currently stands.

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
- **`fstrim` reclaim is judged per drive now.** The ExFAT finding above is a
  property of the *filesystem holding that one `volume.img`*, so a downloads
  volume parked on an ExFAT external will never hole-punch even though the
  other two, on APFS, reclaim fine. Format each drive APFS if you care about
  reclaim on it.
- **Full Disk Access applies to every external drive you use**, not just
  `MACKAS_ROOT`'s — see the section at the end of this document. The move
  itself is done by `mackas` under your own account, so it is the *daemon*
  reaching the relocated image afterwards that hits the TCC denial; a drive
  that was never used for a volume before is exactly where that bites.
- **Time Machine**: `check` only inspects `MACKAS_ROOT`'s volume for an active
  destination, so a build volume parked on a disk that *is* a Time Machine
  destination will not be flagged.

## Does `SSTATE_DIR` actually need ext4? (desk check, not yet measured)

The table at the top of this document says TMPDIR on ext4 is
*non-negotiable*, and lists sstate and downloads on their own ext4 volumes
for "correctness and speed". That is honest about TMPDIR and vague about
sstate — so the source was read to find out which of it is a real
requirement. Summary: **nothing in sstate's own read/write path requires
ext4. The hash-equivalence database mackas parks inside `SSTATE_DIR` is a
different matter, and is the actual blocker.**

What the source says (openembedded-core at `4b73d7a5c5`, bitbake alongside
it):

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
hash-equivalence database outlives `clean` (see the section above). That
database is SQLite opened in **WAL mode with `synchronous = OFF`**
(`hashserv/sqlite.py:145`, `cooker.py:363`), with one connection per client
plus a backfill worker (`hashserv/server.py:303,895`).

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

**Safe with caveats, on paper. Not yet tried.** Nothing was measured: this is
a source reading, and the two things that would decide it are both empirical
— whether `link(2)`, `utimes` and `rename` really behave on the virtiofs
mount (and fail loudly rather than silently if not), and what streaming
hundreds of MB of zstd tarballs over virtiofs on every reuse costs against
the ext4 volume. If the throughput cost is real it is paid on *every* build,
against a usability win (browsable, `rsync`-able, Time-Machine-able sstate)
that only matters occasionally. That trade, not correctness, is what should
decide it — and it stays an open question until someone runs it.

## Buildstats and a constant BUILDNAME

`meta/classes-global/buildstats.bbclass` writes every build's per-task timing
under `tmp/buildstats/${BUILDNAME}/`. Two things about it matter here, both
confirmed straight from its source: `bb.utils.mkdirhier(bsdir)` only creates
that directory if missing — it never clears one that already exists — and
`build_stats` (the per-build summary at the root of it) is opened in
**append** mode at both `BuildStarted` and `BuildCompleted`, never truncated.

For a project whose `BUILDNAME` genuinely varies per build (bitbake's own
default is timestamp-based), that is harmless: each build gets a fresh,
uniquely-named directory. It stops being harmless the moment a distro
hardcodes `BUILDNAME` to something constant — confirmed live in this
project's own `meta-angstrom/conf/distro/angstrom.conf`:

```
BUILDNAME = "Angstrom ${DISTRO_VERSION}"
```

Every build ever run under that distro config writes into the exact same
`tmp/buildstats/Angstrom ${DISTRO_VERSION}/` directory, forever. Its
`build_stats` file accumulates one "Build Started"/"Elapsed time"/"CPU usage"
trio per build (append, never truncate), and every recipe's task files from
every past build just sit there too, since nothing ever removes them. A naive
read of that directory sums CPU/wall time across **every build that ever ran
there**, not just the latest one — the parallelism figures `mackas buildstats
analyze` reported after a real second build looked nonsensical for exactly
this reason (the correct, tiny elapsed time for that build alongside a task-CPU
total that was really the sum of a much larger earlier build's tasks too).

mackas handles this in three places:

- **`clear_buildstats_before_build`** (`MACKAS_BUILDSTATS_ACCUMULATE`, default
  `0` i.e. clearing is ON) runs before every `smoketest`/`shell` invocation
  and deletes `tmp/buildstats` in the TMPDIR volume first, so accumulation
  never has a chance to happen in normal use. Best-effort, like `fstrim`
  auto-run — a failure here can never fail the build.
- **`mackas retrieve buildstats`** now copies each retrieval into its own
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

## Time Machine

If the volume holding `MACKAS_ROOT` is an active Time Machine destination,
the build and the backups compete for the same free space — and a build that
fills the disk stops backups working (Time Machine starts thinning old
snapshots to make room, losing backup history). `check` detects an active
destination and warns loudly. The volume caps above are the mitigation; if
the margin is still uncomfortable, shrink `MACKAS_VOLUME_SIZE_*` or point
Time Machine at a different disk (`tmutil removedestination`).

## Full Disk Access

Creating a container volume on an **external** disk can fail with `Operation
not permitted` when the Apple `container` daemon has not been granted Full
Disk Access under System Settings → Privacy & Security. The symptom looks
nothing like a permissions problem — it is not an `EACCES` on the path you
named, but a TCC denial on the daemon reaching the external volume — so it is
easy to chase in the wrong direction for an afternoon.

The fix is to grant Full Disk Access to the daemon binary. Its location is
**not** fixed: a Homebrew install and Apple's signed `.pkg` install put
`container-apiserver` in different places (a versioned Cellar path vs
`/usr/local/libexec/container-apiserver`), so any tooling or instruction here
must **derive** the path rather than hardcode it. This is not yet automated;
see [TODO.md](../TODO.md).
