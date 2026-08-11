# Homebrew — what actually depends on it

mackas currently assumes Homebrew, and `check` **hard-fails** without it
(in `check_container_runtime()`). That is stricter than the real dependency:
the two things mackas genuinely needs from brew are not equally
replaceable.

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

## 2. GNU `realpath` — the hard one, and the reason brew is still here

kas-container calls exactly three forms: `realpath -e`, `realpath -qe`, and
`realpath -q --relative-base=DIR`. Stock macOS ships a `realpath` binary
(`/bin/realpath`), but it is **BSD's**, and BSD's has neither `-e` nor
`--relative-base` — kas-container fails outright against it
(`illegal option -- e`). A working one comes from `brew install coreutils`,
which is the actual reason brew stays a dependency.

The wiring is deliberately not left to the ambient `PATH`, because that is
fragile: `brew install coreutils` installs **`grealpath`, not an unprefixed
`realpath`**, so an unlucky PATH order — or a hand-made symlink left over
from an earlier session with no coreutils behind it — silently falls through
to the BSD binary. Instead, `setup_shim_and_env()` finds a real GNU
`realpath` (`find_gnu_realpath()` tries `grealpath`, then coreutils'
`gnubin/realpath`, then any `realpath` on `PATH` that turns out to be GNU)
and symlinks it into `$MACKAS_BIN`. Two separate things then put that
directory first on `PATH`: the generated `env.sh` exports it ahead of
everything else when it is sourced, and — the guarantee that actually
matters — the protection wrapper `write_kas_wrapper()` generates at
`$MACKAS_BIN/kas-container` (the file `PATH` resolves `kas-container` to;
the pinned upstream script sits beside it as `kas-container.real`, never on
`PATH` itself) re-execs that real script through
`env PATH="$MACKAS_BIN:/opt/homebrew/bin:$PATH"`. So kas-container finds the
GNU one on *every* invocation shape — `nohup`, `env`, a bare `$PATH` lookup,
a shell that never sourced `env.sh` — not only inside `env.sh`'s own
`kas-container()` shell function. `check` verifies that shim exists
and is genuinely GNU coreutils, not merely that *some* `realpath` answers. If
no GNU realpath can be found at all, `setup` errors with
`brew install coreutils`.

That makes the wiring robust, but it does not remove the Homebrew (or
MacPorts) dependency itself — `setup` still needs a GNU coreutils installed
*somewhere* to symlink from. Actually dropping that dependency is a
different, not-yet-done idea, tracked as
[TODO item 9](../TODO.md): a small shim mackas ships itself, over
`/usr/bin/python3` (present on every stock Mac) — `os.path.realpath` + an
`os.path.exists` check + `os.path.relpath` covers those three call forms in
~30 lines — but make it four: `env.sh`'s own `kas-container()` function
resolves the `macos-local.yml` fragment with `realpath --relative-to="$PWD"`
through that same shim directory, and `--relative-to` is not
`--relative-base` (it emits `..` segments; `--relative-base` never does).
That call is guarded by `2>/dev/null || true`, so a shim missing the flag
would fail silently — the fragment (parallelism, `BB_DISKMON_DIRS`,
`BB_HASHSERVE_DB_DIR`, mirrors) would simply stop being appended. mackas
already depends on python3 for the mirror server, so this costs nothing new.
It is not written yet.

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

**Homebrew-optional for `container` today, and Homebrew-free only once
`realpath` is solved.** Until then `check` should degrade from "Homebrew not
found → FAIL" to a warning that names precisely what is missing (`container`,
GNU `realpath`) rather than the package manager that usually supplies them —
a tool should check for its dependencies, not for one particular way of
installing them.

One thing to get right when this is done: the Full Disk Access guidance
[storage.md](storage.md#full-disk-access) already carries — and any tooling
that ever automates it — must **derive** the daemon's location rather than
hardcode it, because it differs between a brew
install and a `.pkg` install — and the failure it causes (`Operation not
permitted` creating a volume on an external disk) looks nothing like a
permissions problem, so a misdirected instruction there costs hours. Tracked
in [TODO.md](../TODO.md).
