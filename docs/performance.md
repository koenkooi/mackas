# Performance and virtualization overhead

Every number here is measured on the reference host — **Mac Studio (M1 Ultra),
20 cores, 64 GiB RAM, macOS 26.5.1** — with an **18 vCPU / 42 GiB** VM. The primary
workload is meta-qcom `rb1-core-kit`, target **`core-image-base`**, a full
distro rootfs (kernel + initramfs + userspace + image assembly), 6253 tasks /
350 recipes. The local-SSD runs (C and E below) have been reproduced in full;
everything else is a single run. Trust the large, directional signals
(io-bound task count, per-task parallelism, `do_rootfs`) and treat single-digit
wall deltas as indicative, not significant — see
[Run-to-run variance](#run-to-run-variance) for what a repeat actually showed.

## How the host side is measured

`mackas smoketest` samples the host process set around each rung
(`MACKAS_OVERHEAD`, via `tools/mackas-overhead`), while `mackas buildstats
analyze` reports the guest's own per-task CPU. The host set is the
Virtualization.framework VM — a child XPC service
(`com.apple.Virtualization.VirtualMachine.xpc`) of the per-run
`container-runtime-linux` launchd job, which carries the guest's CPU and the
bulk of the RSS — plus the persistent `container` daemons
(`container-apiserver`, `container-core-images`, `container-network-vmnet`,
`machine-apiserver`).

Honest limits of that method:

- macOS `ps %cpu` is a **lifetime average**, not an instantaneous reading, and
  is never used. Host CPU is a **delta of cumulative CPU time** (`ps -o time`)
  over the measurement window — the only honest CPU signal without
  sudo/powermetrics.
- Host CPU time for the VM process **includes the guest's own work**, so
  "overhead" is a difference (host CPU-seconds minus guest task CPU-seconds)
  with real error bars, not a direct reading.
- Sampling at N seconds cannot see spikes shorter than N.
- `powermetrics` (per-process energy, true utilisation) needs sudo, which is
  not available non-interactively, so energy numbers are omitted, not guessed.
- RSS summed across VM + daemons can double-count shared pages; treat host RSS
  as an upper bound on private footprint.

## What a from-scratch `bash` build costs

Measured from the buildstats of `bitbake bash` built from scratch on
macOS/aarch64 (18 allocated CPUs, 4491 tasks, 1938.9 s wall):

| Figure | Value |
|---|---|
| Effective parallelism | **14.45×** (28,016 s CPU / 1939 s wall) |
| Written through TMPDIR | **78.9 GB** |
| Read from TMPDIR | 4.6 GB |

Two things follow. 14.45× against 18 CPUs is the parallelism ceiling
`do_configure` imposes, analysed below. And a 17:1 write-to-read ratio is
why TMPDIR is on a local ext4 volume rather than anything reached over
virtiofs or a network — the volume absorbs the writes at block-device speed,
and none of them cross a file-sharing protocol.

## What the VM costs the Mac

For the from-scratch local build:

| | guest (buildstats) | host (mackas-overhead) |
|---|---|---|
| CPU-seconds | 33,288 | 32,548 |
| memory | peak task RSS 2.0 GiB | RSS peak 73.0 GiB / mean 58.9 GiB |

**CPU overhead is negligible.** Host CPU-seconds ≈ guest task CPU-seconds — the
guest's compute lands on the host almost 1:1, so Apple's hypervisor adds no
measurable CPU tax on a compute-bound build. What the VM costs is **memory**:
this run held ~59 GiB resident mean, ~73 GiB peak, for a 42 GiB `-m`
allocation plus daemons — roughly **1.4–1.7× the VM's `-m`**. A full repeat of
the same build peaked at only ~1.07× the allocation (see
[Run-to-run variance](#run-to-run-variance)), so the multiplier is not a tight
bound in either direction: budget host RAM headroom well above the `-m`
allocation rather than to an exact figure. That same RAM holds the page cache
for the ext4 `volume.img` files, which is why storage placement (below) hinges
on how much is left over.

A fully-cached rung does almost no VM work, so its host figure is near zero —
correct, not a bug. See the warm-cache run (E) below: 909 host CPU-seconds for
the same target.

## Local SSD vs a network share for the working volume

Three runs of the same target, identical config. The only variables: where the
**TMPDIR** `volume.img` lives (local SSD vs an SMB share — the image nested in a
sparsebundle as [storage.md](storage.md#disk-images-on-network-shares)
describes, put there with `mackas volume move`, which leaves the runtime a
[per-volume symlink](storage.md#relocating-a-volume-and-recovering-a-hand-moved-one)),
and whether the
downloads + sstate caches are warm. `DL_DIR`/`SSTATE_DIR` were on local volumes
in every run.

- **C** — TMPDIR local, from scratch (0 % sstate reuse).
- **D** — TMPDIR on SMB, from scratch (0 % sstate reuse). Isolates the network.
- **E** — TMPDIR local **fresh**, reusing C's warm downloads + sstate. Isolates
  what a clean build dir costs when the cache survives.

C and D both reported `Sstate summary: … Local 0 Mirrors 0 … 0 % match`; E hit
`Local 3244 / Wanted 3257 … 99 % match`.

| buildstats (build rung) | C — local scratch | D — SMB scratch | E — local warm |
|---|---|---|---|
| wall | 2131 s (35.5 min) | 2447 s (40.8 min) | **107 s (1.8 min)** |
| vs C | — | **+14.8 %** | **−95 % (20× faster)** |
| parallelism | 15.62× | 14.26× | 6.37× |
| bitbake reported CPU | 70.4 % | 62.0 % | 29.3 % |
| io-bound tasks | 171 | **359** | 0 |
| bytes written | 136.9 GB | 137.0 GB | **9.0 GB** |
| tasks actually run | 6224 | 6224 | ~388 of 6253 |
| host CPU-seconds | 32,548 | 34,468 | **909** |
| host RSS peak / mean | 73.0 / 58.9 GiB | 64.1 / 34.1 GiB | 32.4 / 19.2 GiB |

### C vs D — the network penalty, by task type (wall seconds)

| task type | C local | D SMB | Δ |
|---|---|---|---|
| do_compile | 4865 | 5637 | +16 % |
| do_configure | 5843 | 7576 | **+30 %** (0.59×→0.37× parallelism) |
| do_install | 1103 | 1511 | **+37 %** |
| do_package | 2360 | 2590 | +10 % |
| **do_rootfs** (1 task) | **39.5 s** | **68.0 s** | **+72 %** |
| do_image_qcomflash | 7.3 s | 9.5 s | +30 % |

**The penalty is I/O wait, not compute.** Host and guest CPU-seconds barely
move; the VM just spends more wall-clock idle — parallelism 15.6→14.3, bitbake
CPU 70→62 % — because tasks block on SMB round-trips, and io-bound tasks **more
than double** (171→359). It concentrates exactly where the filesystem is
metadata- and `fsync`-heavy: **`do_rootfs` +72 %** (installing thousands of
files into the rootfs), `do_install` +37 %, `do_configure` +30 %. Bulk
`do_compile` is only +16 %, because most object writes are absorbed by the host
page cache and flushed to the network asynchronously.

**This scales with image size.** The same test on the *minimal*
`initramfs-rootfs-image` (whose `do_rootfs` installs almost nothing) came in at
only **+7.1 %** overall, with `do_rootfs` **unchanged** (15.2 s → 14.8 s) — the
working set fit in cache and never touched the network under load. Swap in a
real rootfs and the penalty doubles to +14.8 %, landing squarely on `do_rootfs`.
On a Mac with less RAM than this 64 GiB M1 Ultra it would be worse again: the
page cache could not hold the working set, so writes would block and reads miss.

### SMB durability

D's +14.8 % is the cost of a run SMB happens to survive — the good case.
Repeat attempts did not survive at all: twice, on a completely fresh volume
and a completely fresh sparsebundle each time, the same build died within
seconds of real write activity with `OSError: [Errno 117] Structure needs cleaning:
'/build/tmp/hosttools'` — an ext4 filesystem consistency error, not a
slowdown. Both failures hit the exact same code path (`base_eventhandler` →
`setup_hosttools_dir` → `mkdirhier`), the first real burst of
small-file/symlink writes in a build, which is exactly the write pattern most
likely to expose lazily-flushed, out-of-order network writes: the host page
cache absorbs the guest's writes and flushes them to the network
asynchronously, so state the guest believes committed can be inconsistent on
the share. The SMB mount itself was unremarkable (SMB 3.1.1, signing on,
cleanly negotiated) — nothing misconfigured, and destroying and recreating the
volume/sparsebundle did not change the outcome.

Whether a given run's write pattern lands badly on the network path may simply
be luck of the draw. Treat an SMB-backed TMPDIR as **unreliable for a real
build, not merely slower** — a RAM-headroom caveat does not rescue it. A
follow-up investigation (isolated write-burst tests that could *not* reproduce
the failure, a third real attempt that failed differently, and a unified-log
check during a live failure) narrowed the failure character without finding a
fix or a definitive root cause; the full record, and the NFS comparison that
fared substantially better, is in
[storage.md](storage.md#smb-unreliable-for-a-real-build-not-merely-slower).

**Recommendation.** Keep TMPDIR (and sstate) on a local SSD.

### C vs E — sstate is the whole game

A **fresh, empty TMPDIR** with a warm downloads + sstate cache rebuilt the same
image in **107 s versus 2131 s — 20× faster** — for **909 host CPU-seconds
versus 32,548 (36× less)** and **9 GB written versus 137 GB (15× less)**. 5865 of
6253 tasks were covered by sstate (99 % match); only `do_rootfs`/`do_image` and
a handful of misses actually ran. The takeaway for storage design: **the TMPDIR
is disposable, sstate is not.** `mackas clean` throwing away TMPDIR while keeping
the sstate volume is nearly free to recover from; losing the sstate volume costs
a 35-minute from-scratch rebuild. Put sstate on the fastest, most durable
storage you have; TMPDIR can be recreated on demand (see item 14 in
[../TODO.md](../TODO.md) for the per-project volume model that formalizes this).

## Run-to-run variance

A full repeat of C and E on the reference host reproduced the headline figures:
wall 2380.8 s vs 2131 s for C, 106.3 s vs 107 s for E; bytes written,
parallelism and sstate match % all within noise. (D, the SMB run, did not
reproduce at all — see [SMB durability](#smb-durability).) Note the size of C's
own spread, though: 2380.8 s vs 2131 s is **+11.7 %**, the same order as the
+14.8 % wall penalty D showed. The C-vs-D headline percentage is therefore not
tightly bounded by one run each; what carries the network finding is the
per-task-type structure — io-bound tasks 171→359, `do_rootfs` +72 % — which
varies far less than wall time does.

One figure did not reproduce closely: C's host RSS came in at peak 45.0 GiB /
mean 26.3 GiB against the original 73.0 / 58.9 GiB — only ~1.07× the 42 GiB
`-m` allocation at peak, not the 1.4–1.7× of the first run. E's host RSS
matched closely (30.6 / 18.1 GiB vs 32.4 / 19.2 GiB), so the swing is specific
to the long, heavy-write run, most likely reflecting host memory pressure and
page-cache eviction state at measurement time rather than a change in what
mackas or the VM itself does. The practical reading: host RSS for a heavy
build ranges from just above the `-m` allocation to ~1.7× it depending on
ambient memory pressure — budget headroom above that range, and do not treat
either endpoint as exact.
