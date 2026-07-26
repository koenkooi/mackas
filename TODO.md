# TODO

What is left, ordered by how much it would hurt if left undone. Completed
work lives in git history and the docs, not here.

---

## P0 — The untested feature surface

### 1. The HTTP mirror path — now verified with a real build, some unknowns remain

`mirror-server/mackas-mirrord` is written, tested and locally verified: it
runs, serves, authenticates, refuses traversal and symlink escapes, speaks
TLS 1.2+, shuts down cleanly, and a real `container run` can reach it on the
Mac with Basic auth working end to end (see
[docs/storage.md](docs/storage.md#serving-local-files-instead-of-bind-mounting-them)).

**Run for real, end to end, this session** — the test sequence this item used
to prescribe, followed exactly: `mackas-mirrord --check` (passed), `curl` one
known sstate object by hand (200, real bytes), a `bitbake -p`, then a real
build counting sstate hits. The setup: a genuine ~9.8 GB / 4776-object sstate
cache and ~16 GB downloads cache (extracted from an earlier real build this
session, not synthetic) served over **SMB** (not NFS — no NFS server was
available; SMB exercises the same class of "networked filesystem behind the
mirror" unknowns), reached by a container over the real **vmnet gateway**
(`192.168.64.1`) — the actual topology a locally-run mirror uses. Result: a
completely fresh, empty local sstate volume, `MACKAS_USE_HTTP_MIRRORS=1`,
building meta-qcom's `bash` on `rb1-core-kit` —
`Sstate summary: Wanted 2347 Local 0 Mirrors 2346 Missed 1 (99% match)`,
1581 real GET/HEAD requests in the mirror's own log (all HTTP 200), and
`Tasks Summary: Attempted 4603 tasks of which 4344 didn't need to be rerun
and all succeeded` — a genuinely complete, successful build. A miss also
confirmed clean (`404` in ~6ms, not a hang) and a hit resolved in ~6.5ms from
inside the container.

**One real gotcha found in the process**, worth keeping in mind: bitbake
itself warns `"You are using a local hash equivalence server but have
configured an sstate mirror. This will likely mean no sstate will match from
the mirror"` — mackas's own generated fragment always sets
`BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` (see
[docs/storage.md](docs/storage.md#volume-caps-and-the-disk-monitor)), so this
warning fires on every HTTP-mirror build. In this test it
did **not** actually block matching (99% is proof), but the warning is real
and the interaction is not well understood — worth a closer look if
mirror hit rates ever look wrong for someone.

What is still genuinely unconfirmed, now narrower:

- **A real NFS root specifically** (SMB was substituted this session).
  NFS-specific unknowns remain: `root_squash`, dentry-cache cold-latency on a
  much larger tree, and whether an NFS hiccup turns a 404 into a hang.
- **The remote topology's network leg.** Only container → same-Mac-host HTTP
  is verified; container → vmnet-NAT-egress → a *separate* LAN host has not
  been.
- **The systemd unit has never been started.** Its hardening directives are
  believed correct from the systemd.exec docs, not from a run.
- **Whether `BB_GENERATE_MIRROR_TARBALLS = "1"`** actually needs setting for
  the downloads side — `SOURCE_MIRROR_URL` was exercised this session, but
  that specific setting was not isolated.

### 2. NFS bind-mounts don't work — HTTP mirrors are the path

Confirmed: bind-mounting a host NFS mount into the container
(`MACKAS_USE_NFS_MIRRORS=1`) does not work. HTTP mirrors are the recommended
— and only proven — path (see
[docs/storage.md](docs/storage.md#http-mirrors--optional-and-not-just-an-nfs-bridge)).
The same NFS export can still be bridged locally: mount it on the Mac and
serve it with `mackas-mirrord`, same as any other local files. The
NFS-bind-mount code stays for now (`MACKAS_USE_NFS_MIRRORS`, off by default),
but is not worth investing further in; removing it outright is worth
considering.

---

## P1 — Known risks

### 3. `BB_DISKMON_DIRS`'s HALT has never been observed firing

The generated value's syntax is confirmed accepted by a real bitbake — a
previously-mangled value was exactly what a successful `bitbake -p` required
fixing (see
[docs/storage.md](docs/storage.md#volume-caps-and-the-disk-monitor)). What
is still **unverified**: that `HALT` actually fires at the 2 GiB / 100k
inode thresholds. That needs a volume driven near full, which no run has
done. `HALT` (not the older `ABORT`) is correct for bitbake 2.18; that is
from the docs, not observed.

### 4. Volume sizes are a budget, not a measurement

A volume cannot be grown after creation — no grow command exists in Apple
`container` v1.1.0. If 120 GiB of TMPDIR turns out to be too small
mid-build, the only path is to delete that volume and recreate it larger —
`mackas clean` already does exactly that, and since the split into three
volumes it no longer costs sstate or downloads.

Whether 120/40/40 are the right numbers is **unmeasured**. `bash` and
`tensorflow-lite` built without hitting a cap, which is a data point, but
neither TMPDIR's high-water mark nor the eventual size of a full meta-ai
sstate was recorded — `bitbake bash` alone wrote 78.9 GB through TMPDIR, so
the headroom is worth measuring rather than assuming.

Worth re-checking on each `container` release. If a grow command appears,
wire it into a `mackas grow`.

---

## P2 — Tooling and hygiene

### 5. In-container HTTP server serving `deploy`, to make grabbing builds easier

Putting `TMPDIR`, `DL_DIR` and `SSTATE_DIR` inside ext4 volumes bought
correct Linux filesystem semantics, and cost host visibility: `deploy/` —
the images and ipks a build exists to produce — is now reachable only from
inside a container. Worse, it cannot simply be mounted a second time to
fetch them: an ext4 image is not a cluster filesystem, and mounting it
read-write in two VMs at once corrupts it. Today the only honest way out is
to stop the build first.

Serving `deploy/` over HTTP from *inside* the container that already holds
the mount sidesteps that entirely — one mount, no second VM, and artifacts
become fetchable **while the build is still running**. The container and the
Mac can reach each other (verified: bind `0.0.0.0`, reach it on the vmnet
gateway `192.168.64.1` or the Mac's LAN IP; `127.0.0.1` is the container's
own loopback, not the host's).

`mirror-server/mackas-mirrord` is already exactly this program — read-only,
stdlib-only, single file, hardened — so this is mostly plumbing rather than
new code: get the script into the container (it is one file; `-v` it in),
run it against `/build/tmp/deploy`, publish a port, and teach `mackas` a
subcommand to start it and print the URL.

**Hard constraint: only one VM may access a disk image at a time.** The
server therefore has to live in the *same* container as the build, sharing
its single mount — never a second container attaching the volume alongside
it. A read-only second mount is explicitly **not** an escape hatch: `ro` at
the Apple-container level says nothing about what the guest kernel does,
ext4 journal recovery writes, and "probably fine" is not a basis for risking
a multi-hour build. This is settled, not an experiment to run.

That makes the real design question a different one: how to run a second
process alongside kas in a container where **kas owns PID 1**. Rough order
of preference: launch the server in the background from the same `kas shell
-c` compound command that runs bitbake, so it shares the mount and dies with
the shell; or accept that serving only happens *after* the build exits —
simpler, and still removes the extract dance. Either way the server is
read-only and the build owns the mount.

### 6. `mackas doctor`

`check` answers "can this Mac do it?" before setup. There is no equivalent
for "it worked yesterday and is broken today". A `doctor` would diagnose a
*live* install: is the shim still first on `PATH` (the single most common
failure), is the volume still attached, is the symlink intact, does the kas
fragment still match what `setup` would generate now.

### 7. CI — WRITTEN, but disabled (manual dispatch only)

`.github/workflows/ci.yml` exists: a macOS job running the full `./run-tests.sh`,
a Linux job (shellcheck + the Python suite on a 3.9/3.12 matrix), and a
`systemd-analyze verify` of the mirrord unit. It is deliberately
**`workflow_dispatch`-only** — GitHub Actions minutes cost money and macOS
runners are billed at a premium, so it never runs on push/PR; start it by hand
from the Actions tab. Re-enabling automatic runs is a one-line change to the
`on:` block (documented in the workflow).

The honest caveat still stands: CI can only ever cover the shim and the config
layer. The parts most likely to break (a real build) need real hardware and
hours — which is what the opt-in `MACKAS_REAL_RUNTIME=1` suite and a dev Mac are
for, not CI.

### 8. Test gaps that need hardware or sudo

Written down rather than faked. None of these can be unit-tested honestly:

- **Volume creation and ext4 semantics.** Needs the real `container` runtime.
  Hardlink behaviour inside the volume was verified by hand, not by a test.
- **kas-container's half of the `--runtime-args` contract.** The suite asserts
  what mackas *sends* (the flag, its contents, and that `KAS_BUILD_DIR` et al
  are empty in kas' environment) against a fake `kas-container`. That the real
  kas-container then forwards it to the engine intact, and that `forward_dir()`
  really does skip an empty variable, was verified by hand by running the real
  v5.4 script with a mock engine and reading the argv — and by the `mount`
  output inside a real container showing `/dev/vdc on /build type ext4`. The
  suite cannot do this without either vendoring kas (a non-goal) or depending
  on the gitignored `kas-upstream/` checkout. Re-check it by hand on each kas
  version bump; `forward_dir()` and the `KAS_EXTRA_RUNTIME_ARGS=""` line are
  the two things to re-read.
- **The sudo mkdir/chown path in `setup`.** Needs interactive sudo.
- **Time Machine destination detection.** Needs a real TM destination.
- **Free-space and case-sensitivity probes.** They deliberately measure the
  real filesystem; a mock would only test the mock.
- **`nproc` reporting one more than `-c`.** Needs a booted container.
- **`env.sh` actually putting the shim ahead of `/usr/local/bin`.** Needs a
  real Docker CLI installed to shadow.
- **The mirror server's privilege drop.** `drop_privileges()` is a no-op
  unless started as root, and a test cannot become root. The suite asserts the
  `setgroups`→`setgid`→`setuid` *ordering* textually, which guards the classic
  bug (setuid first silently loses the ability to setgid) but does not prove
  the calls work. The runtime code verifies the drop took effect and that it
  is irreversible, which is the real defence.
- **The mirror server against a real NFS root.** See item 1. A local temp dir
  is not an NFS mount, and every interesting failure is NFS-specific.
- **TLS against a client that verifies the chain properly.** Verified by hand
  with `curl --cacert` and a self-signed cert; not in the suite, because
  generating a cert needs the `openssl` CLI and the suite must not shell out.

If any of these becomes testable via a lightweight fake, it should be — but a
test that only asserts a mock's behaviour is worse than no test, because it
reads as coverage.

### 9. Stop requiring Homebrew, or stop pretending it is required

`check` **hard-fails** when Homebrew is absent, which is stricter than the
actual dependency: a tool should check for what it needs, not for one
particular way of installing it. See [docs/homebrew.md](docs/homebrew.md)
for the full analysis. The work:

1. **Demote the Homebrew check** from FAIL to a warning, and check for the
   real dependencies by name — `container` and GNU `realpath` — reporting
   each separately with its own remediation (Apple's signed `.pkg` installer
   is a full alternative for `container`).
2. **Solve GNU `realpath` without brew** — the actual blocker. Ship a
   ~30-line shim in `bin/` over `/usr/bin/python3` (present on every stock
   Mac) covering the exact three forms kas-container calls: `realpath -e`,
   `realpath -qe`, and `realpath -q --relative-base=DIR`. It goes on `PATH`
   ahead of any real `realpath`, so it must be correct for every form kas
   passes — verify against kas-upstream, do not guess.
3. **Derive the Full Disk Access path, if such guidance is ever added** —
   the daemon's location differs between a brew install and a `.pkg`
   install, and the failure a wrong path causes (`Operation not permitted`)
   looks nothing like a TCC problem. See
   [docs/homebrew.md](docs/homebrew.md#the-achievable-target).
4. `env.sh` hardcodes `/opt/homebrew/bin` on `PATH`; that should follow from
   wherever `realpath` was actually found.

`bats-core` staying a brew dependency is fine — it is test-only and never
needed to run a build.

### 10. Consider dropping `MACKAS_RELOCATE_VOLUMES`

It works by symlinking Apple `container`'s entire volumes directory, which is
a global side effect on the user's machine to serve one project. If Apple adds
a real config knob for the volume storage root, switch to it immediately.

### 11. A launchd unit for `mackas-mirrord`, if the local-serving use case sees real use

Running `mackas-mirrord` on the Mac itself — serving local
`DL_DIR`/`SSTATE_DIR`, or bridging an NFS export — is documented and (for
the local-files case) verified, but today it means starting the server by
hand each time. `mirror-server/` ships a systemd unit for the Linux case and
no macOS equivalent.

Deliberately not done yet — it is a new deliverable (a launchd plist with
its own hardening equivalent to the systemd unit, `WorkingDirectory`,
`StandardOutPath` etc.) rather than documentation, and it cannot be tested
hermetically (loading a launchd job needs `launchctl` against the real
session). Worth doing properly, with the same care as the systemd unit, if
this use case gets picked up for real. It should also pre-empt the macOS
Application Firewall prompt somehow (see
[docs/storage.md](docs/storage.md#serving-local-files-instead-of-bind-mounting-them))
since an unattended agent has nobody to click "Allow".

### 12. A pybootchartgui SVG chart of a build

`tools/mackas-buildstats-analyze` already parses a buildstats dir (per-task
wall/CPU with child rusage, per-recipe, a concurrency grid), and emits JSON.
What it does not produce is the standard **bootchart-style SVG timeline** that
OE developers expect from a build. `qualcomm-linux/meta-qcom`'s CI runs
`scripts/pybootchartgui/pybootchartgui.py --minutes --full-time --format=svg`
over the buildstats after every leg and ships the chart as an artifact; it is
the one buildstats thing that project does which mackas does not.

pybootchartgui ships in openembedded-core (`scripts/pybootchartgui/`), so
`mackas buildstats` could invoke it against the buildstats it just extracted
and drop an SVG next to the JSON. The catch is dependencies: pybootchartgui's
renderer needs **pycairo** for every output format including SVG (there is no
pure-Python SVG path), which is a C-extension needing libcairo — a Homebrew
dependency mackas is otherwise trying to shed (see item 9). Options: run it
*inside* the kas container (which has the deps) as part of the extraction, or
teach `mackas-buildstats-analyze` to emit SVG itself from the data it already
has (no pycairo, stdlib-only, but reinvents the wheel). Decide before building.

Not a build-time **regression gate** — meta-qcom does not diff buildstats
across runs either, so there is no proven pattern to copy there; this is just
the chart.

### 13. kas lock / kas dump for reproducibility

Related idea from the same meta-qcom comparison, worth its own line so it is not
lost: `mackas` runs kas but never captures a **lockfile**. meta-qcom's CI runs
`kas lock` (pinning every layer to an exact commit in `ci/*.lock.yml`) and
`kas dump --resolve-env --resolve-local --resolve-refs` (a fully-resolved YAML),
and keeps both as artifacts, so a build is reproducible to the commit and a
nightly can be skipped when nothing changed. `mackas smoketest`/`shell` could emit
the same — a `mackas lock`/`mackas dump` that writes the resolved config next to
the logs. Low-risk, independent of buildstats.

### 14. First-class projects: build any layer's kas config, share downloads by convention

**Partially landed**: `set_defaults` no longer hardcodes meta-ai --
`MACKAS_PROJECT_URL/_BRANCH/_DIR`/`MACKAS_KAS_CONFIG` all default to empty,
`setup` completes its whole job and just skips the project checkout step
with none of them set, and `smoketest` offers the meta-ai example for one
ephemeral run (never persisted) when nothing is configured at all. That was
this item's own first phasing bullet ("meta-ai demoted to example"), pulled
forward on its own. The rest below --- multiple projects side by side,
per-project volume naming, a shared downloads convention --- is still
undone.

mackas is one-project-at-a-time today. There is exactly one volume set, named by
`MACKAS_VOLUME_NAME` → `oe-build-{tmp,dl,sstate}`. Building a second repo
means hand-overriding `MACKAS_PROJECT_*` **and** inventing a distinct
`MACKAS_VOLUME_NAME` yourself — which is exactly how the meta-qcom and
oe-vov builds were actually driven. Two things are wrong with that: nothing
ties a project to its volumes by convention, and every volume stem brings its
**own `-dl` volume, so downloads are not shared across projects** — backwards.
meta-qcom's CI composes ~260 distinct configs (16 machines × 5 distros × 3
kernels, as `ci/ci.yml:ci/${MACHINE}.yml…` colon-chains) and meta-qcom-distro
~132 more layered on top of it, and both share one `DL_DIR` and one monthly
`SSTATE_DIR` while never reusing a TMPDIR. That is the shape to copy: a dev
flips machine/distro/kernel constantly, sstate reuse is the whole point of the
cache, and TMPDIR is the per-project throwaway.

The target UX is regular kas: `pipx install kas`, clone a layer, point kas at
the layer's own shipped config. mackas' `setup` should be exactly as generic —
prepare the Mac (shim, volumes, fragment machinery), bake in no repo — and a
*project* (a name + a checkout under `work/` + a kas file chain) is what a
build is invoked against:

```sh
mackas build meta-qcom ci/ci.yml:ci/rb1-core-kit.yml
mackas build meta-ai kas/base.yml:kas/qemuarm64.yml --target llama-cpp
mackas --project meta-qcom shell    # chain from the project config
```

Both builds share one downloads volume; neither can see the other's TMPDIR or
sstate. Volume naming becomes a convention instead of a knob:
`mackas-<project>-tmp` and `mackas-<project>-sstate` always per-project;
`mackas-shared-dl` shared **by default**, with a per-project opt-out to
`mackas-<project>-dl`. sstate sharing is opt-*in* via a named group —
`MACKAS_SSTATE_GROUP=qcom` maps meta-qcom and meta-qcom-distro onto one
`mackas-sstate-qcom`, mirroring what their CIs already do to each other, while
meta-ai and meta-angstrom keep their own. The ext4-named-volume and one-VM
rules are untouched, which has one honest consequence: **two projects sharing
any volume cannot build concurrently**. mackas must detect the held volume and
refuse the second build with a message naming the holder — never mount ext4
twice (see item 5; `ro` is not an escape hatch). For one dev on one Mac that
is the right trade; if cross-project concurrency ever matters, `mackas-mirrord`
serving one project's caches over HTTP to the other is the safe route.
`BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` in the generated fragment already
means the hash-equivalence DB travels with the sstate volume — correct in both
modes: a shared group shares the DB its members need for hits to land, a
private sstate keeps a private DB, and the one-VM rule serializes all access
so there is no concurrent-SQLite hazard.

Config model: the defaults→config→env→`--set` precedence stays; a per-project
file (`~/.config/mackas/projects/<name>.conf`, same ownership checks as
`load_config`) slots in between the global config and the environment. meta-ai
stops being the shipped default and becomes the worked example in
`mackas.conf.example`. The generated `kas/macos-local.yml` already physically
lives inside each checkout, so it is per-project today by accident; the
canonical copy under `$MACKAS_KAS/` must become per-project too, so
per-project mirrors or sizes do not cross-write.

Migration is non-breaking by construction: with no project named, today's
`MACKAS_PROJECT_*` + `oe-build-*` path is frozen and keeps working; the new
naming applies only to project-aware invocations. Adopting the shared
downloads volume is `mackas volume duplicate oe-build-dl mackas-shared-dl`
(APFS clone, near-free) then destroying the old — `check`/`status` should
nudge, the way they already report the pre-split legacy volume.

Phasing, smallest first, each shippable alone:

1. **A downloads-volume name knob + held-volume refusal.** Add
   `MACKAS_VOLUME_DL_NAME` (default `${MACKAS_VOLUME_NAME}-dl`, unchanged), so
   sharing is one config line today; teach the build path to refuse a volume a
   running container holds. Kills the worst duplication with no new concepts.
2. **First-class projects.** `--project NAME` loading the per-project config,
   derived `mackas-<project>-*` names with `mackas-shared-dl` as the dl
   default, per-project canonical fragment and logs, `clean`/`destroy`/
   `buildstats` scoped to the project. meta-ai demoted to example.
3. **The kas-like direct invocation.** `mackas build <name|path> <chain>
   [--target X]` — project inferred from the checkout name, fragment generated
   on demand, no project file needed for a one-off. Path-based checkouts must
   still pass the case-sensitivity probe (`work/` under `MACKAS_ROOT` already
   does).
4. **sstate groups + a migration helper** (`duplicate`+`destroy` dance wrapped
   in one command).

Open questions, honestly: **disk**. Four projects at today's 120G+40G caps
plus a 40G shared dl is ~680G of worst-case budget on an SSD that is also a
Time Machine destination. Sparse images and auto-fstrim mean caps are not
cost, but `bitbake bash` alone wrote 78.9 GB through TMPDIR (item 4), so
per-project caps likely need to shrink and `setup` should sum every project's
caps against free space — unmeasured, same status as item 4. Whether shared
sstate should rotate monthly like the qcom CI (`sstate-cache-$(date +%Y-%m)`)
is really a garbage-collection question; per-project destroy may suffice on a
dev Mac, undecided. `KAS_WORK_DIR` is currently one shared `work/`: kas
re-checks-out pinned refs there per build, which is correct when serialized
but churny when two projects pin different revs of the same layer (the qcom
pair pins meta-qcom itself), and `work/` is host APFS — the one-VM rule does
not guard it. Per-project `work/<name>/` is safer and duplicates poky-sized
clones; not decided. And item 13's lock/dump artifacts need a per-project,
per-chain home — grow the project concept first, or item 13 bakes in the
single-project assumption this item exists to remove.

### 15. An animated terminal demo in the README

The README explains mackas but never *shows* it. A short animated terminal
recording at the top — `check` → `setup` → `smoketest` → `buildstats` scrolling by
in colour — would communicate "it is just kas, on a Mac" faster than three
paragraphs. Follow the asciinema → SVG route
([itamde.com](https://itamde.com/en/animated-ascii-art-terminal-github-readme/)):
record a cast, render it to an **animated SVG**, and embed the SVG. SVG (not
GIF) because it stays sharp at any width, the file is small, and GitHub autoplays
it as an `<img>`.

```sh
# record, then render (svg-term-cli; agg is the GIF alternative)
asciinema rec demo.cast
svg-term --in demo.cast --out docs/demo.svg --window --width 92 --height 28
```
```markdown
<!-- top of README.md -->
![mackas in action](docs/demo.svg)
```

The catch is the **script**, not the tooling: a real `mackas setup` + from-scratch
`smoketest` is ~35 minutes (see [performance.md](docs/performance.md)) and nobody
watches a 35-minute SVG. The recording has to be a *curated* session, and the
honest way to keep it curated-but-true is to record against a **warm sstate
cache** — the same run E measured at **1.8 minutes** — so `smoketest` really does
complete on camera, then trim the idle gaps with `asciinema rec --idle-time-limit
2` (or edit the `.cast`, which is plain JSON). Do **not** hand-fake the output:
a doctored transcript that shows numbers the tool never printed is exactly the
kind of thing this repo does not ship. A believable ~60–90 s cut:

```
$ mackas check                     # green ladder: container, realpath, shim, disk
$ mackas --set MACKAS_PROJECT_URL=…/meta-qcom \
         --set MACKAS_KAS_CONFIG=ci/rb1-core-kit.yml setup
$ mackas smoketest                 # parse rung, then build (warm cache → ~2 min)
$ mackas buildstats analyze        # wall / parallelism / io-bound summary
$ mackas status                    # volumes, history rollup
```

GitHub-rendering gotchas the article omits: GitHub serves README images through
its **CAMO** image proxy and caches them hard, so a re-render needs a new
filename (or a `?v=2` bust) to actually update; **inline** `<svg>` in Markdown is
sanitized away, but an SVG referenced via `![](…)` renders and animates fine
because it is fetched as an image; there is no light/dark variant for an `<img>`,
so pick terminal colours legible on **both** README themes (a neutral-background
window frame, `--window`, rather than transparent). Keep the `.cast` in the repo
so the SVG can be re-rendered when the CLI output changes — same discipline as
"update docs in the commit that makes them stale."

**Landed** as a real asciinema → svg-term recording rather than a
hand-authored SVG; the recorded/regenerable `.cast` was intentionally not kept
in the repo. This item stays open only for re-cutting the recording when CLI
output drifts (e.g. once item 16 lands).

### 16. A build-completion summary line

Raw `kas-container build` ends on bitbake's own `NOTE: Tasks Summary: Attempted
6253 tasks … all succeeded` and nothing friendlier — no wall time, no image name
called out, no clear "done". mackas should print a one-line summary after a
successful build, in the shape the README demo already shows:

```
✓ core-image-base · rb1-core-kit built  (35.5 min, 6253 tasks)
```

A green `✓`, the image and machine, and the two numbers a developer actually
wants (how long it took, how many tasks ran). The data is already to hand:
mackas times each `run_kas` invocation for its own overhead sampling, and the
task count is in bitbake's Tasks Summary (or the extracted buildstats). This
belongs in the build wrapper — `smoketest` today, the `mackas build <layer>
<config>` of item 14 tomorrow — not in kas, so it stays zero-patch. Keep it
truthful: only print it on a genuine success (rc 0), show the real elapsed time,
and fall back gracefully (omit the task count rather than guess) when the number
cannot be read. Until it lands the README demo ends on bitbake's real Tasks
Summary; once it lands, the demo can close on this friendlier line instead.

### 17. Check for newer kas-container / kas on start (auto, disable-able)

mackas pins one `kas-container` version (5.4) and sha256-verifies it, which is
the right default for reproducibility — but it means a user silently sits on an
old kas while upstream moves. Add an automatic, **disable-able** check on start
(`smoketest`/`shell`/`setup`) that notices when a newer kas-container release, or a
newer kas *version inside the container image*, is available, and prints a
one-line nudge (never auto-upgrades — the pin is deliberate). Model it on the
qcom CI, which fetches the newest kas tag every run (see item 13 / the meta-qcom
comparison): query the newest tag (GitHub releases API for siemens/kas) and
compare to `KAS_CONTAINER_VERSION`. Honest constraints: it must be **off by a
single knob** (`MACKAS_CHECK_UPDATES=0`, and implicitly off with no network),
cache the result so it does not hit the network every invocation (a daily stamp
under `$MACKAS_BASE`), never block or slow a build, and never phone home beyond
the one well-known endpoint — consistent with [docs/security.md](docs/security.md)'s
"no telemetry" stance. It should also surface when the pinned version has a
newer point release with a known fix, so bumping the pin is an informed choice.

### 18. A workspace image, for a case-insensitive-only drive

`setup` now REFUSES a case-insensitive `MACKAS_ROOT` outright (the
case-sensitivity gate, landed alongside the GNU-realpath fix) rather than
silently finishing "Done" on a root that corrupts the very first build —
real bug, found live: an external
SSD's stock case-insensitive APFS produced a clean 11/11 `setup`, then
`kas-container build` failed with `git clone` errors ("fatal: unknown error
occurred while reading the configuration files") because `KAS_WORK_DIR` (the
layer checkouts — oe-core, bitbake, meta-*) is a host bind-mount, not one of the
ext4 volumes, and oe-core has files that differ only by case. The refusal is
correct, but it leaves a real class of user stuck: someone whose only large
drive is a stock case-insensitive external SSD (no spare partition to
reformat, no `diskutil apfs addVolume` room) now cannot use mackas at all.

Not the whole root: `logs/`, `bin/`, `kas/` don't care about case; only `work/`
(`KAS_WORK_DIR`, the layer checkouts) does.

**Decided: a case-sensitive APFS sparse image, virtiofs-mounted — not a 4th
ext4 volume.** `hdiutil create -type SPARSE -fs "Case-sensitive APFS"`,
attached and mounted at `$MACKAS_ROOT/work`. This reuses the EXACT bind-mount
mackas already does for `/repo` today (kas-container's own virtiofs mount of
the project checkout) — no `container volume` / ext4 / mkfs machinery needed at
all, and it stays host-native, so `git`/`bitbake -e` on `work/` from macOS keep
working exactly as they do now. **Spiked and confirmed working**: created a
case-sensitive APFS sparse image, bind-mounted it into a plain `container run`,
and both a raw case-colliding file pair and a real `git commit` of
case-colliding filenames (`File.txt` / `file.txt` — the actual oe-core failure
mode) round-tripped correctly through the guest. ext4 was rejected because it
is guest-only: the host-side `work/` access that works today would break, and
that is a regression this item must not introduce.

The one real cost is the attach lifecycle: `hdiutil attach` is not persistent
across reboots, so `setup` needs to attach it idempotently (skip if already
mounted, same shape as `ensure_volume`'s idempotency), and something needs to
notice and remount it before any command that touches `work/` — a `check`-style
probe added alongside the existing `MACKAS_ROOT` case-sensitivity check, since
the check is already doing the work of noticing case-insensitivity.

`setup` should OFFER this automatically the moment its own case-sensitivity
probe fails, right there in the error from the fix above, rather than just
pointing at `diskutil apfs addVolume` and leaving the user to find their own
workaround. Honest caveat: this is squarely for the resource-constrained case
("poor people... lack large enough drives" — direct quote, keep the framing
sympathetic) — anyone who CAN reformat a spare partition as case-sensitive APFS
should still do that; a workspace image is one more moving part (the attach
lifecycle, its own size cap) for when there is no better option, not the new
default.

**The offer/create/mount/migrate part is LANDED**: `setup_oe_root()` probes
`work/` specifically (not the whole root — the invariant this item states
above), and on a case-insensitive result calls `offer_workspace_image()`,
which interactively offers to create-and-mount (or reattach an existing
image), moving any pre-existing `work/` content aside first and copying it
back onto the fresh mount afterward — real git remotes, branches and
uncommitted changes preserved exactly as-is, verified end to end with a real
`hdiutil` in `tests/workspace_image_real.bats` (opt-in,
`MACKAS_REAL_RUNTIME=1`), plus hermetic coverage of the offer/decline/
reattach/migrate logic in `tests/case_sensitivity.bats`. `MACKAS_WORKSPACE_SIZE`
(default `40G`, sparse) controls the image size. The attach lifecycle
(surviving a reboot, `check`/`status` visibility) landed as item 19 phase 1;
recovery when the image file goes missing is still open — see item 19.

### 19a. `volume destroy`/`volume move` leave dangling per-volume symlinks behind

Found live: after `volume move`, `$CONTAINER_VOLUMES_DIR/<name>` is a
per-volume symlink to the volume's new location (see the "a per-volume
symlink a prior `volume move` planted here is preserved verbatim" comment in
`setup_relocate_volumes()`). `delete_volume()` (`mackas:1225`) only calls
`container volume delete`/`rm` — the daemon-level removal — and never
touches that symlink itself. Confirmed on a real Mac: three volumes,
previously `volume move`d onto separate disks, were destroyed via `mackas
volume destroy` (daemon confirms they're gone — `container volume ls` shows
nothing), yet `$CONTAINER_VOLUMES_DIR/<name>` still had three dangling
symlinks pointing at now-nonexistent paths. Harmless clutter today (nothing
reads them — `volume_exists()` asks the daemon, not the filesystem), but
confusing to find by hand and worth cleaning up at the source: after a
successful `container volume delete`, `delete_volume()` should also remove
`$CONTAINER_VOLUMES_DIR/$name` if it is a symlink (dangling or not — the
volume it pointed at is gone either way).

### 19. Workspace "sync": git remotes already are the sync — the image needs a lifecycle

Follow-on to item 18, answering "what keeps the workspace image in sync?"
The honest answer, reasoned from what is actually in `work/`: **nothing
should, because there is no second copy to sync with.** Every checkout under
`work/` is a git repository, and essentially all of them (oe-core, bitbake,
meta-*, the project layer) have a real `origin` — git's remote *is* the sync
mechanism, battle-tested, and any file-level mirror mackas invented beside it
would be a worse, lying copy of `git push`/`git clone`. Once the image is
mounted at `$MACKAS_ROOT/work`, that mount is the sole canonical home of the
checkouts. Only three moments even look like sync, and none of them is one:

1. **Creation-time migration** — moving a pre-existing `work/` onto the fresh
   image (move aside, mount, copy back). A one-time copy, **done** as part of
   item 18's `offer_workspace_image()`; not ongoing.
2. **The attach lifecycle** — `hdiutil attach` does not survive a reboot, so
   every macOS restart leaves `work/` looking like an ordinary **empty
   directory** on the case-insensitive drive. This is the real work, and it
   is failure-mode-critical: if a command falls through to that bare
   directory, kas happily re-clones oe-core onto case-insensitive APFS —
   exactly the corruption item 18 exists to prevent, now silent because the
   `setup`-time gate already passed. The guard must **fail closed**: image
   configured but not attachable ⇒ refuse to touch `work/`, never proceed.
3. **Disaster recovery** — for any layer that is clean and pushed, losing the
   image costs nothing (`git clone` restores it byte-for-byte). The only
   thing genuinely at risk is **uncommitted or unpushed work**, which is a
   reporting problem, not a syncing problem.

**Attach guard.** An `ensure_workspace_attached()` with `ensure_volume()`'s
idempotency shape: skip when already mounted, attach when not, die with a
remediation when it can't. Detection is cheap and host-native — compare
`stat -f %d` of `work/` against `$MACKAS_ROOT` (different device ⇒ something
is mounted), plus a sentinel file written at the image's filesystem root at
creation (`.mackas-workspace`) so "mounted" also means "mounted *our* image",
not a coincidental mount. Attach plain with `-nobrowse` and symlink `work/`
to the reported mount point — NOT `-mountpoint "$MACKAS_ROOT/work"`, which
was found live to fail ("insufficient privileges") when `work/` sits on a
non-APFS host volume; item 18's `attach_workspace_image()` already landed
exactly this symlink shape, so the guard reuses it. Call sites:
`run_kas()` (covers `smoketest`/`shell`), `setup` (already landed by item
18), and read-only reporting in `check` (a rung next to the existing
case-sensitivity probe in `check_target_volume`, which is already the code
that notices case-insensitivity) and `status`/future `doctor` (item 6 — "it
worked yesterday" is literally this failure after a reboot). Whether the
image is *configured* is recorded by a knob, `MACKAS_WORKSPACE_IMAGE`
(default: unset ⇒ no image, plain `work/`; `setup`'s offer sets it), with the
default creation path derived — `$MACKAS_ROOT/workspace.sparseimage`, which
is exactly what `offer_workspace_image()` already uses — it must live on the
same (case-insensitive) drive anyway, that being the whole premise.

**When the image is genuinely missing** (file moved by hand, deleted,
external drive gone): mirror `volume recover`'s UX — detect, locate with
Spotlight, confirm before changing anything — but the mechanism differs,
deliberately. An ext4 volume's location record is the symlink at
`$CONTAINER_VOLUMES_DIR/<name>` ("the symlink IS the record"); a sparse image
has no runtime directory to symlink — its record is `MACKAS_WORKSPACE_IMAGE`
itself, because `hdiutil attach` takes an explicit path every time. So
recovery is: check the recorded path; if absent, `mdfind` by filename with
structural filtering (reuse `volume_spotlight_find`'s shape, including the
`mdutil -s` indexing-off diagnosis and the refuse-to-guess-on-multiple-hits
rule), then offer to **move the found image back to the recorded path**
(`cp -c`/`mv`, same holes-preserving care as `volume_transfer`) rather than
chase it — one canonical location beats teaching mackas to edit the user's
config file. Printing the `MACKAS_WORKSPACE_IMAGE=<found>` line for the user
to adopt instead is the fallback when moving is refused. Open question
whether this lands as `mackas workspace recover` beside `volume recover` or
folds into a no-arg `recover`; naming only, the mechanism is the same either
way.

**The unpushed-work warning.** `status` should tell the truth about the blast
radius: iterate the git repos one level under `work/`, count dirty
(`git status --porcelain`) and ahead-of-upstream (`git log @{u}..`,
tolerating no-upstream), and print one line — "N layers have uncommitted or
unpushed work inside the workspace image" — only when N > 0 and only when an
image is configured (a plain `work/` on a real case-sensitive volume has
whatever backup story that volume has; the image is a single file with none).
Time Machine cuts the **opposite way** from the build volumes here:
`check_target_volume` warns when `$MACKAS_ROOT`'s mount is a TM
*destination* because 200 GiB of build volumes competes with backups for
space — but the workspace image is small (source checkouts, single-digit
GiB) and holds the only copy of exactly the work git can't restore, so
sitting on a TM-*backed* source volume is a feature, not a hazard. Honest
caveats: TM copies a mounted image whole-file (a few GiB re-copied per
backup — acceptable at this size), and a snapshot taken mid-write can need
`fsck_apfs` on restore; neither has been observed, same status as item 3's
unverified HALT. Do not over-engineer past the one status line — `git push`
remains the real backup, and the line should say so.

**Item 14 interplay.** Per-project `work/<name>/` composes with a *single*
image untouched: the mount point is `work/` itself, and project subdirs
simply live inside it. The pressures that push item 14's *volumes*
per-project (the one-VM rule, per-project caps and destroy) mostly don't
apply — the image is host-native APFS, no VM ever attaches it, and `destroy`
of one project is `rm -rf work/<name>` inside it. The two real couplings to
flag, not solve: a shared image is one cap and one blast radius across all
projects (an argument for per-project images if either ever hurts), and item
14's rule that path-based checkouts "must still pass the case-sensitivity
probe" is satisfied *through* the attach guard — so the guard has to run
before that probe, or the probe reports the underlying drive.

Phasing, smallest first, each shippable alone:

1. **The fail-closed attach guard. LANDED.** `MACKAS_WORKSPACE_IMAGE` is
   written into the config file by the create/reattach paths (the record is
   part of saying yes to the image — an unrecorded image is exactly the
   silent hole), a `.mackas-workspace` sentinel is written at the mount root,
   and `ensure_workspace_attached()` guards `run_kas` plus `smoketest`/
   `shell` ahead of their "is the project checked out?" tests (a detached
   image otherwise reports a checked-out project as missing). Detection is
   `stat -L -f %d` of `work/` vs `MACKAS_ROOT` plus the sentinel; the three
   refusals are a foreign mount, a missing/unattachable image, and a
   NON-EMPTY plain `work/` (contents written to the case-insensitive drive
   while detached — refuse and leave them alone rather than `rm -rf` them for
   the mount). Hermetic coverage in `tests/workspace_attach.bats`, real
   `hdiutil detach`-then-recover in `tests/workspace_image_real.bats`.
2. **`check`/`status` visibility.** The attached/not-attached rung in
   `check_target_volume` and the `status` image line LANDED with phase 1
   (both read-only, neither ever mounts). Still open: size on disk via
   `du -h` like `status_volume`.
3. **Recovery.** Spotlight-located, confirm-gated, move-home-first — the
   `volume recover` UX transplanted to a config-path record.
4. **The unpushed-work status line.** Pure reporting, no new state.
5. **(with item 14, later)** revisit single-vs-per-project image sizing; no
   code now.

---

## Non-goals

Recorded so they don't get re-litigated:

- **Patching kas.** The central design goal is zero patches. If a patch looks
  necessary, the shim is wrong. See
  [README](README.md#zero-patches-to-kas--the-central-design-goal).
- **Supporting kas' Isar mode or rootless-Docker paths.** They need
  `--privileged` / `--device` / `--userns`, which Apple `container` does not
  have. Plain OpenEmbedded only.
- **Putting TMPDIR anywhere but the local ext4 volume.** Network-backed TMPDIR
  is slower *and* corruptible on a link drop. Settled; see
  [docs/storage.md](docs/storage.md#disk-images-on-network-shares).
- **Being a general docker-CLI reimplementation.** The shim covers what
  kas-container v5.4 issues, plus obvious analogues, and nothing more.
