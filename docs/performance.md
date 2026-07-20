# Performance and virtualization overhead

Every number here is measured on the reference host — **Mac Studio (M1 Ultra),
20 cores, 64 GiB RAM, macOS 26.5.1** — with an **18 vCPU / 42 GiB** VM. The primary
workload is meta-qcom `rb1-core-kit`, target **`core-image-base`**, a full
distro rootfs (kernel + initramfs + userspace + image assembly), 6253 tasks /
350 recipes. These are single runs, so trust the large, directional signals
(io-bound task count, per-task parallelism, `do_rootfs`) and treat single-digit
wall deltas as indicative, not significant.

## What the VM costs the Mac

`mackas smoketest` samples the host process set — the Virtualization.framework VM
plus the container daemons — around each rung (`MACKAS_OVERHEAD`), while `mackas
buildstats` reports the guest's own task CPU. For the from-scratch local build:

| | guest (buildstats) | host (mackas-overhead) |
|---|---|---|
| CPU-seconds | 33,288 | 32,548 |
| memory | peak task RSS 2.0 GiB | RSS peak 73.0 GiB / mean 58.9 GiB |

**CPU overhead is negligible.** Host CPU-seconds ≈ guest task CPU-seconds — the
guest's compute lands on the host almost 1:1, so Apple's hypervisor adds no
measurable CPU tax on a compute-bound build. What the VM costs is **memory**:
~59 GiB resident mean, ~73 GiB peak, for a 42 GiB `-m` allocation plus daemons.
Budget roughly **1.4–1.7× the VM's `-m`** of host RAM for the whole stack. That
same RAM holds the page cache for the ext4 `volume.img` files, which is why
storage placement (below) hinges on how much is left over.

A fully-cached rung does almost no VM work, so its host figure is near zero —
correct, not a bug. See the warm-cache run (E) below: 909 host CPU-seconds for
the same target.

## Local SSD vs a network share for the working volume

Three runs of the same target, identical config. The only variables: where the
**TMPDIR** `volume.img` lives (local SSD vs an SMB share, relocated with the
per-volume symlink trick in
[storage.md](storage.md#disk-images-on-network-shares)), and whether the
downloads + sstate caches are warm. `DL_DIR`/`SSTATE_DIR` were on local volumes
in every run.

- **C** — TMPDIR local, from scratch (0 % sstate reuse).
- **D** — TMPDIR on SMB, from scratch (0 % sstate reuse). Isolates the network.
- **E** — TMPDIR local **fresh**, reusing C's warm downloads + sstate. Isolates
  what a clean build dir costs when the cache survives.

C and D both verified `Sstate summary: … Local 0 Mirrors 0 … 0 % match`; E hit
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

**Recommendation.** Keep TMPDIR (and sstate) on a local SSD for routine builds.
An SMB-backed working volume is usable for occasional or overflow builds **if**
you have RAM headroom, but heed the durability caveat in
[storage.md](storage.md#disk-images-on-network-shares): writes flush to the
network lazily, so a link drop mid-build can leave an ext4 the guest believes is
committed in an inconsistent state.

**Re-verified 2026-07-20, and the caveat above is no longer hypothetical.**
Re-ran C and E in full on the reference host: both reproduced closely (wall
2380.8 s vs 2131 s for C, 106.3 s vs 107 s for E; bytes written, parallelism,
sstate match % all within noise). One figure did NOT reproduce closely: C's
host RSS came in at peak 45.0 GiB / mean 26.3 GiB versus the original 73.0 /
58.9 GiB — only ~1.07× the 42 GiB `-m` allocation at peak, not the 1.4–1.7×
this doc recommends budgeting for. E's host RSS matched closely (30.6 / 18.1
GiB vs 32.4 / 19.2 GiB), so this is specific to the long, heavy-write C run,
most likely reflecting host memory pressure/cache eviction state at
measurement time rather than a change in what mackas or the VM itself does —
but it means the 1.4–1.7× figure is a single historical data point, not a
tight bound; budget headroom above it, don't budget to it exactly. D did not
reproduce at all: TWICE, on a completely fresh volume and a completely fresh
sparsebundle each time, the build died within seconds of real write activity
with `OSError: [Errno 117] Structure needs cleaning: '/build/tmp/hosttools'`
— an ext4 filesystem consistency error, not a slowdown. Both failures hit the
exact same code path (`base_eventhandler` → `setup_hosttools_dir` →
`mkdirhier`), the first real burst of small-file/symlink writes in a build,
which is exactly the write pattern most likely to expose lazily-flushed,
out-of-order network writes. The SMB mount itself was unremarkable (SMB
3.1.1, signing on, cleanly negotiated) — nothing misconfigured, and destroying
and recreating the volume/sparsebundle did not change the outcome.
**Read this as the durability caveat being real and current, not as "D's old
+14.8% number was wrong."** It may simply be luck-of-the-draw whether a given
run's write pattern lands badly on the network path; today's runs landed badly
twice in a row. Treat SMB-backed TMPDIR as **unreliable for a real build until
this is understood further**, not merely slower — the RAM-headroom caveat
above was too optimistic. A follow-up investigation (isolated write-burst
tests, a third real attempt with a different target, and a unified-log check
during a live failure) narrowed the failure character without finding a fix
or a definitive root cause — see the "Investigated, not solved" note in
[storage.md](storage.md#disk-images-on-network-shares).

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
