# AGENTS.md

Guidance for AI coding agents (and new humans) working in **mackas** — a bash
tool that runs [kas-container](https://github.com/siemens/kas) OpenEmbedded
builds on macOS via Apple's native `container` runtime. Read this before making
changes; the invariants below are things a real build depends on, and easy to
break by accident.

## What this repo is

- `mackas` — the whole tool, one ~8000-line **bash 3.2** script. Subcommands:
  `check`, `setup`, `adopt`, `smoketest`, `status`, `shell`, `exec`,
  `retrieve`, `buildstats`, `sstate`, `monitor`, `clean`, `destroy`, `volume`,
  `set`, `get`, `unset`.
- `bin/docker` — a shim that translates the `docker` CLI calls kas-container v5.4
  makes into Apple `container` calls. Nothing more.
- `mirror-server/mackas-mirrord` — optional HTTP mirror server. **Python 3.7+,
  stdlib only.**
- `tools/mackas-buildstats-analyze`, `tools/mackas-overhead` — Python, stdlib
  only, build profiling.
- `tests/` — 31 `*.bats` files + 4 `test_*.py` files.
- `docs/` — architecture, storage, homebrew, testing, mirror-server,
  performance, security.
- `TODO.md` — the roadmap. Numbered items are referenced across the codebase,
  so existing items keep their numbers (a finished item is annotated in place,
  never renumbered away). New items go at the end.
- `kas-upstream/` — a reference clone of kas (pinned), for reading. **The design
  goal is zero patches to kas** — never vendor a modified kas.

## Build, run, test

There is nothing to compile. To test:

```sh
make test          # == ./run-tests.sh : shellcheck, bash 3.2 syntax, bats, python
make syntax        # bash -n only
make pytest        # the Python unittest suite only
./run-tests.sh tests/volumes.bats   # a single bats file
```

The suite is **hermetic** — no `container` runtime, no network, no sudo, no real
build — so it runs anywhere. The two exceptions, `tests/real_runtime.bats` (real
Apple `container`) and `tests/workspace_image_real.bats` (real `hdiutil`),
self-skip unless `MACKAS_REAL_RUNTIME=1`; they are dev-Mac-only and never
CI-gated. Always run the full suite yourself before claiming green; do not trust
a partial run.

## Language and style

- **bash 3.2.** macOS ships bash 3.2 as `/bin/bash` and that is the target. No
  `declare -A`, no `${var^^}`, no `mapfile`, no `&>>`. `make syntax` checks it.
- **shellcheck** must pass at `--severity=warning` (info-level notes are ignored
  so the result is stable across shellcheck versions — do not "fix" SC2015 etc.
  by contorting code).
- **Python: stdlib only, 3.7+.** No third-party imports, no `requirements.txt`.
  `mackas-mirrord` must keep running on whatever `python3` a mirror host has.
- Every source file carries `SPDX-License-Identifier: GPL-3.0-or-later` and a
  copyright line. Keep them.
- Match the surrounding comment density and idiom. Comments explain *why* /
  constraints, not *what*.

## Hard invariants — do not break these

1. **Zero patches to kas.** Everything is done through configuration, the shim,
   and a generated `kas/macos-local.yml` fragment. If something seems to need a
   kas change, it is almost certainly a config/shim change instead.
2. **ext4 named volumes for TMPDIR / DL_DIR / SSTATE_DIR — never bind-mount APFS.**
   virtiofs over APFS lacks hardlinks and ownership, which OE needs.
   `KAS_BUILD_DIR` / `DL_DIR` / `SSTATE_DIR` must stay **unset** in the build
   environment (`forward_dir()` would bind-mount whatever they point at over the
   volume). Volumes are attached via `--runtime-args`, not env vars.
3. **One VM per disk image, always.** ext4 is not a cluster filesystem; a volume
   may be mounted by exactly one running container at a time — **not even a
   read-only second mount**. Code that starts a build must refuse a held volume.
4. **Config precedence is defaults → config file → environment → `--set`.**
   `snapshot_env`/`restore_env` make the environment win over the config file.
   Preserve that order.
5. **Never source or write files unsafely.** A config file is sourced only if it
   passes `config_file_is_safe` (owned by us or root, not group/world-writable —
   file *and* directory). Interpolated settings are checked by `validate_settings`
   (reject `"`, backtick, control chars) before being written into the generated
   `env.sh` / gitconfig / kas fragment.
6. **The shim's scope is fixed:** it covers what kas-container v5.4 issues plus
   obvious analogues. It is not a general docker reimplementation. It drops flags
   Apple `container` lacks (`--log-driver`, `--security-opt`, `--userns`,
   `--group-add`, `--privileged`) and hard-fails on `--device` / `--network host`.

## Testing discipline

- **Mutation-test every assertion** you add: make it fail on purpose once, so you
  know it can. Several tests here were once vacuous.
- **Never `grep -qv PATTERN` to assert absence** — it passes on any multi-line
  input. Use `! ... | grep -q PATTERN`.
- Logic guarded by `set -e` that bats cannot trigger should be covered by a
  **source-grep** test instead of pretending a runtime test exercises it.
- The shim ↔ kas contract is pinned by a recorded argv fixture keyed to
  `KAS_CONTAINER_VERSION`; if you bump the pinned version, re-record it or the
  guard fails loudly.

## Workflow conventions

- **CI is intentionally disabled.** `.github/workflows/ci.yml` is
  `workflow_dispatch`-only because GitHub Actions minutes cost money (macOS
  runners at a premium). **Do not add `push`/`pull_request` triggers or run the
  workflow.** `./run-tests.sh` covers the same hermetic suite for free.
- **Keep docs current in the same commit that makes them stale.** `docs/` and
  `README.md` are part of the change, not a follow-up.
- **Commit style:** `area: lowercase imperative summary` (`docs:`, `ci:`,
  `tests:`, `readme:`, `TODO:`, or a subcommand/file name). Sign off with `-s`
  (`Signed-off-by:`). AI-assisted commits add an `Assisted-by:` trailer.
- Security policy and how to report issues: see [SECURITY.md](SECURITY.md).

## Where to look first

- How volumes get mounted and why the dir vars stay unset —
  [docs/architecture.md](docs/architecture.md).
- Storage, network shares, volume caps, fstrim — [docs/storage.md](docs/storage.md).
- What a build costs (measured) — [docs/performance.md](docs/performance.md).
- The roadmap and known gaps/non-goals — [TODO.md](TODO.md).
