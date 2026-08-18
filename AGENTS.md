# AGENTS.md

Guidance for AI coding agents (and new humans) working in **mackas** — a bash
tool that runs [kas-container](https://github.com/siemens/kas) OpenEmbedded
builds on macOS via Apple's native `container` runtime. Read this before making
changes; the invariants below are things a real build depends on, and easy to
break by accident.

## What this repo is

- `mackas` — the whole tool, one ~10,500-line **bash 3.2** script. Subcommands:
  `check`, `setup`, `adopt`, `smoketest`, `status`, `shell`, `exec`,
  `retrieve`, `buildstats`, `buildhistory`, `sstate`, `monitor`, `clean`,
  `destroy`, `volume`, `set`, `get`, `unset`, `runtime-args`, `lock`, `dump`.
- `bin/docker` — a shim that translates the `docker` CLI calls kas-container v5.4
  makes into Apple `container` calls. Nothing more.
- `mirror-server/mackas-mirrord` — optional HTTP mirror server. **Python 3.7+,
  stdlib only.**
- `tools/` — Python, stdlib only: `mackas-buildstats-analyze`,
  `mackas-buildhistory-analyze` and `mackas-overhead` (build profiling),
  `mackas-monitor` (renders the live progress bridge in a terminal),
  `mackas-ext4-dirty-bit` (reads a volume image's ext4 dirty/error state
  without mounting it).
- `mackas-uibridge/` — the live build-progress bridge behind `MACKAS_MONITOR=1`.
  `mackasjson.py` is a bitbake UI module (`bb.ui.mackasjson`) that serves
  progress as JSON over HTTP; `bitbake` is a wrapper bind-mounted directly over
  the checkout's own `bin/bitbake` for the lifetime of one container run (a
  PATH shadow does not work — see the file's own header for why).
- `tests/` — 39 `*.bats` files + 7 `test_*.py` files.
- `docs/` — architecture, storage, homebrew, testing, mirror-server,
  performance, security, monitor-app.
- `skills/mackas/SKILL.md` — an operational playbook for *using* mackas to
  build an OpenEmbedded project (not for developing mackas itself — that's
  what the rest of this file is for). Copy or symlink it into a project's own
  `.claude/skills/mackas/` to make Claude Code load it there; see the file
  itself for what it covers (`mackas exec`, the `--skip` footguns, retrieve/
  clean/monitor, one-VM troubleshooting).
- `TODO.md` — the roadmap. **Local-only and gitignored**, as is `TODO-archive.md`
  (the write-up of every LANDED item), so a fresh clone will not have either:
  completed work lives in git history and in `docs/`. Numbered items are
  referenced across the codebase, so existing items keep their numbers (a
  finished item is annotated in place, never renumbered away). New items go at
  the end. Never cite a TODO item number in anything public — commits, `--help`
  text, GitHub issues.
- `kas-upstream/` — a reference clone of kas, for reading. **Gitignored**:
  deliberately neither vendored nor a submodule, so clone it yourself
  (`git clone https://github.com/siemens/kas.git kas-upstream`). **The design
  goal is zero patches to kas** — never vendor a modified kas. What mackas
  actually runs is a pinned, sha256-verified kas-container release, named by
  `KAS_CONTAINER_VERSION` in `mackas` — not this checkout.

## Build, run, test

There is nothing to compile. To test:

```sh
make test          # == ./run-tests.sh : shellcheck, bash 3.2 syntax, bats, python
make syntax        # bash -n only
make pytest        # the Python unittest suite only
./run-tests.sh tests/volumes.bats   # a single bats file
```

The suite is **hermetic** — no `container` runtime, no network, no sudo, no real
build — so it runs anywhere. The four exceptions — `tests/real_runtime.bats`
(real Apple `container`), `tests/volume_resize_real.bats` (real volume grow),
`tests/diskmon_real.bats` (real bitbake driving a volume near-full) and
`tests/workspace_image_real.bats` (real `hdiutil`) — self-skip unless
`MACKAS_REAL_RUNTIME=1`; they are dev-Mac-only and never CI-gated, and each
also needs a quiet machine (they refuse while any container holds a mackas
volume). Always run the full suite yourself before claiming green; do not trust
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
  constraints, not *what*. **Be terse.** A short comment that carries the
  one non-obvious fact beats a paragraph that also restates what the code
  already shows.

## Hard invariants — do not break these

1. **Zero patches to kas.** Everything is done through configuration, the shim,
   and a generated `kas/macos-local.yml` fragment. If something seems to need a
   kas change, it is almost certainly a config/shim change instead.
2. **ext4 named volumes for TMPDIR / DL_DIR / SSTATE_DIR — never bind-mount APFS.**
   virtiofs over APFS lacks hardlinks and ownership, which OE needs.
   `KAS_BUILD_DIR` / `DL_DIR` / `SSTATE_DIR` must reach kas-container **empty**
   (`forward_dir()` bind-mounts whatever non-empty host path they name, right
   over the volume). mackas blanks them explicitly —
   `KAS_BUILD_DIR= DL_DIR= SSTATE_DIR=` — rather than relying on them being
   unset, because an old `env.sh` still exported in the caller's shell would
   otherwise leak an APFS path through. The container-side paths are then set
   with `-e` *inside* `--runtime-args`, next to the `-v` that backs each with a
   real ext4 volume — never in the invocation environment.
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

- **CI runs on every push to `main` or `multi-project`, and every pull
  request.** `.github/workflows/ci.yml` triggers on `push`/`pull_request`/
  `workflow_dispatch`. `pull_request` is deliberately unfiltered, so a PR is
  gated whatever its base — which is what lets the multi-project epic take
  PRs against its own integration branch. `push` is filtered, so an
  integration branch must be listed there too or it gets no post-merge run;
  note that for `push` events GitHub reads the workflow from the pushed ref,
  so that listing has to exist **on** the branch. This is free: public-repo
  standard GitHub-hosted runners, including macOS, are unmetered — confirmed
  against GitHub's own billing docs, still true after the 2026-01-01 Actions
  repricing. Keep it that way: re-confirm `koenkooi/mackas` is still public
  (`gh repo view --json visibility`) before ever touching the `on:` block,
  since a private repo bills macOS runners at a 10x multiplier against the
  account's included-minutes quota. `./run-tests.sh` runs the identical
  hermetic suite locally for free either way.
- **Keep docs current in the same commit that makes them stale.** `docs/` and
  `README.md` are part of the change, not a follow-up.
- **Versioning:** SemVer-ish, but pre-1.0 (`0.y.z`), so nothing is promised
  stable yet. `SCRIPT_VERSION` near the top of `mackas` is the single source of
  truth — it is printed and stamped in several places (grep `SCRIPT_VERSION`);
  releasing a version means cutting a matching `vX.Y.Z` git tag. Unrelated to
  `KAS_CONTAINER_VERSION` and the `CONTAINER_*_VERSION` pins, which name
  upstream dependencies.
- **Commit style:** `area: lowercase imperative summary` (`docs:`, `ci:`,
  `tests:`, `readme:`, or a subcommand/file name), with the body wrapped at 72
  columns. **Keep the body short** — a few sentences of why, not a
  walkthrough of the investigation. Sign off with `-s` (`Signed-off-by:`);
  AI-assisted commits add an `Assisted-by:` trailer too. Never add a
  `Co-Authored-By:` or `Claude-Session:` line. Use `Fixes #N` / `Closes #N`
  when a commit finishes a tracked GitHub issue.
- Security policy and how to report issues: see [SECURITY.md](SECURITY.md).

## Where to look first

- How volumes get mounted and why the dir vars stay unset —
  [docs/architecture.md](docs/architecture.md).
- Storage, network shares, volume caps, fstrim — [docs/storage.md](docs/storage.md).
- What a build costs (measured) — [docs/performance.md](docs/performance.md).
- The roadmap and known gaps/non-goals — `TODO.md` (local-only, gitignored; not
  present in a fresh clone).
- **Actually driving a build with mackas** (as opposed to developing mackas
  itself) — [skills/mackas/SKILL.md](skills/mackas/SKILL.md).
