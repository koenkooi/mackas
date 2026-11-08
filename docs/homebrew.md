# Homebrew — what actually depends on it

mackas no longer requires Homebrew: `check` warns when it is absent and
checks for the real dependencies instead. The two things brew used to supply
are `container` and a GNU-compatible `realpath`.

## 1. `container` itself — genuinely optional

Apple ships an Apple-signed installer on its own GitHub releases, so
`brew install container` is a convenience, not a requirement (1.2.2 is the
current release as of 2026-08-11; take today's version from the releases
page — mackas's `CONTAINER_TESTED_VERSION` is 1.1.0, the version `check`
warns *below*, not a ceiling):

```sh
curl -LO https://github.com/apple/container/releases/download/1.2.2/container-1.2.2-installer-signed.pkg
sudo installer -pkg container-1.2.2-installer-signed.pkg -target /
container system start
```

It installs under `/usr/local` (so `/usr/local/libexec/container-apiserver`
rather than a versioned Cellar path), and ships its own lifecycle scripts:
`/usr/local/bin/uninstall-container.sh -d|-k` and
`/usr/local/bin/update-container.sh [-v VERSION]`. That `-v` is a
**documented pin/downgrade path, which Homebrew does not really offer**.
Requirements are the same either way: Apple silicon, macOS 26+.

MacPorts has `devel/container` too, but it builds from source (needs
clang-18), so it is slower and no simpler. Building from Apple's source
directly needs Xcode 26 — a multi-GB download, a last resort. nixpkgs has
nothing official; only a third-party nix-darwin module that repackages the
same `.pkg`.

## 2. GNU `realpath` — solved without brew by `bin/realpath`

kas-container calls three forms: `realpath -e`, `realpath -qe`, and
`realpath -q --relative-base=DIR`; `env.sh`'s own `kas-container()` function
adds a fourth, `realpath --relative-to="$PWD"`, to resolve the
`macos-local.yml` fragment. Stock macOS ships a `realpath` binary
(`/bin/realpath`), but it is **BSD's**, and BSD's has none of those flags —
kas-container fails outright against it (`illegal option -- e`).

`setup_shim_and_env()` symlinks a working one into `$MACKAS_BIN`.
`find_gnu_realpath()` tries `grealpath` (what `brew install coreutils`
installs — **not** an unprefixed `realpath`), then coreutils'
`gnubin/realpath`, then any `realpath` on `PATH` that turns out to be GNU, and
finally mackas's own `bin/realpath`: a small Python stand-in over
`/usr/bin/python3` (present on every stock Mac, and already needed by the
mirror server and `monitor`) that implements exactly those four forms with
`os.path`. `--relative-to` is not `--relative-base`: it emits `..` segments,
while `--relative-base` leaves a path outside the base absolute. The
`--relative-to` call is guarded by `2>/dev/null || true`, so a realpath
missing it would fail silently and the fragment (parallelism,
`BB_DISKMON_DIRS`, `BB_HASHSERVE_DB_DIR`, mirrors) would stop being appended;
`realpath_forms_ok()` therefore probes all four forms by behavior, and both
`find_gnu_realpath()` and `check` use it rather than trusting a `--version`
string.

Two separate things put `$MACKAS_BIN` first on `PATH`: the generated `env.sh`
exports it ahead of everything else when it is sourced, and — the guarantee
that actually matters — the protection wrapper `write_kas_wrapper()`
generates at `$MACKAS_BIN/kas-container` (the file `PATH` resolves
`kas-container` to; the pinned upstream script sits beside it as
`kas-container.real`, never on `PATH` itself) re-execs that real script
through `env PATH="$MACKAS_BIN:/opt/homebrew/bin:$PATH"`. So kas-container
finds the right `realpath` on *every* invocation shape — `nohup`, `env`, a
bare `$PATH` lookup, a shell that never sourced `env.sh`.

## 3. `bats-core` and `shellcheck` are test-only

Never needed to run a build.

Two other formulas do show up in mackas proper, both optional and both with
a working fallback: `e2fsprogs` gives `volume fsck` a host-side `e2fsck`
fast path (`host_e2fsck_bin()` takes `command -v e2fsck` first and only then
asks `brew --prefix e2fsprogs`, never a hardcoded prefix), and without it
the same repair runs `e2fsck` inside a throwaway container;
`terminal-notifier` gives `monitor --notify` its own bundle identity, and
without it notifications fall back to `osascript`.

## The achievable target

**Homebrew-optional.** `container` comes from Apple's `.pkg` and `realpath`
from `bin/realpath`, so `check` only warns when Homebrew is absent.

One thing to get right: the Full Disk Access guidance
[storage.md](storage.md#full-disk-access) already carries — and any tooling
that ever automates it — must **derive** the daemon's location rather than
hardcode it, because it differs between a brew install and a `.pkg` install —
and the failure it causes (`Operation not permitted` creating a volume on an
external disk) looks nothing like a permissions problem, so a misdirected
instruction there costs hours. Tracked in #137.
