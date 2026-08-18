# Plan — TODO item 14: first-class projects, per-project volumes, shared downloads

Planning document only. No code, tests, docs or git state were touched while writing it.

**Line numbers are against the working-tree copy of `/Users/koen/Projects/Angstrom/mackas/mackas`, 8687 lines**, at the time of writing. `git status` shows `mackas` as modified relative to `HEAD`, so these will not match `git show HEAD:mackas`. Every function cited was read directly. Claims are tagged **[verified]** (read in the source this session), **[assumed]** (reasoned but not checked against a running system), or **[unmeasured]** (needs a real Mac or a real build to settle).

An earlier planning pass wrote a document at this path against an 8147-line `mackas`; it has been replaced, because nearly every line number in it had drifted. Where its conclusions survived re-verification they are kept and re-cited at current line numbers.

---

## 0. Executive recommendation

Three things dominate the shape of this item, and none of them are in the TODO text:

1. **`mackas adopt` already built most of "phase 2" by accident.** `adopt_unique_volume_name()` (`mackas:4596-4605`) already derives exactly `mackas-<name>-{tmp,dl,sstate}`, and `cmd_adopt()` already writes a **complete, standalone** per-project config to `~/.config/mackas/projects/<name>.conf` (`mackas:4740`, writes at `4748-4756`) and tells the user to drive it with `mackas --config <file> ...` (`mackas:4788`; README:353-359). The item asks for a *layered* per-project config slotted between the global config and the environment. That would add a fifth precedence rung AGENTS.md invariant 4 does not have, a second `.`-source point, and a second RCE surface — for no capability the standalone model lacks. **Recommendation: `--project NAME` becomes a config *selector* — "use `~/.config/mackas/projects/NAME.conf` as *the* config file" — implemented in `load_config()` alongside `--config`/`$MACKAS_CONF`, never as a member of `SETTING_NAMES`.** That collapses most of phases 2 and 4 and leaves invariant 4 untouched by construction.

2. **The held-volume refusal is not a feature, it is an outstanding invariant violation, and it should ship first and alone.** AGENTS.md invariant 3 says "code that starts a build must refuse a held volume." `cmd_exec()` does (`mackas:5659-5666`). So do `cmd_retrieve` (`6032`), `sstate prune` (`6420`), `clean_tmpdir_volume` (`7132`) and every `volume` subcommand. **`cmd_shell()` (`mackas:5552-5559`), `cmd_smoketest()` (`5427-5468`) and `run_kas()` (`4903`) do not** — the two primary build entrypoints are the only unguarded ones. This is reachable today, single-project, with two terminals. Fixing it needs no design decisions from the rest of item 14.

3. **The riskiest thing item 14 introduces is not disk, it is the shared `work/`.** `run_kas()` sets `KAS_WORK_DIR="$MACKAS_WORK"` (`mackas:4955`), so every project's layer clones land as *siblings* in one `work/`. Two projects pinning different revisions of `openembedded-core` share one `work/openembedded-core`, and kas's ordinary `repos_checkout` step resets it on each build — the same class of loss the `-k`/`--skip` discipline exists to prevent, arriving through a path no `--skip` covers. `work/` is host APFS and the one-VM rule does not guard it. See §4.3.

The item's own phase 1-4 order is broadly right but should be split finer and reordered; see §3.

---

## 1. What is actually true today (verified against the current source)

### 1.1 The item's own "partially landed" claims

| Claim in TODO item 14 | Verified at | Status |
|---|---|---|
| `MACKAS_PROJECT_*` / `MACKAS_KAS_CONFIG` default to empty | `set_defaults()` `mackas:639-642` | correct |
| One flat volume stem, default `oe-build` | `set_defaults()` `mackas:576` | correct |
| Caps 120G/40G/40G | `set_defaults()` `mackas:583-585` | correct |
| Volume names come from one stem; no `-dl` override exists | `derive_paths()` `mackas:1279-1285` (and `1202-1205`) | correct |
| `smoketest` offers meta-ai for one ephemeral run | `offer_example_project()` `mackas:5358`, `cleanup_example_project()` `5381` | correct |
| `KAS_WORK_DIR` is one shared `work/` | `derive_paths()` `mackas:1256`, `run_kas()` `mackas:4955`, env.sh `3405` | correct |
| Worst-case disk 4×(120+40)+40 ≈ 680G | arithmetic against `set_defaults()` | correct |
| `volume duplicate` is the migration primitive | `volume_duplicate()` `mackas:7543` (held-source refusal `7561`) | correct |
| Two projects sharing a volume cannot build concurrently | AGENTS.md invariant 3; `volume_in_use()` `mackas:1808` | correct — and **not yet enforced on the build path**, see §1.2(c) |

Confirmed **absent** from the whole tree (`mackas`, `tests/*.bats`, `mackas.conf.example`, `docs/`, `README.md`, `skills/`): `MACKAS_VOLUME_DL_NAME`, `MACKAS_SSTATE_GROUP`, `mackas-shared-dl`, `cmd_build`, any `--project` global flag. The only `--project`-ish flag that exists is `adopt --project-dir`. Phases 1, 3 and 4 are genuinely unstarted. **[verified]**

### 1.2 Findings that change the shape of the work

**(a) The per-project config file already exists, and it is standalone, not layered.**
`cmd_adopt()` (`mackas:4662`) computes `config_file="${config_opt:-$HOME/.config/mackas/projects/$base_name.conf}"` (`4740`) and writes `MACKAS_ROOT`, `MACKAS_SHORT_LINK`, `MACKAS_VOLUME_NAME` and — when a checkout was introspected — `MACKAS_PROJECT_URL/_BRANCH/_DIR` (`4748-4756`) through `config_write_setting()`, the same writer `mackas set` uses (`mackas:930`). It closes with `"from now on : $SCRIPT_CMD --config <file> ..."` (`4788`). `tests/adopt.bats` (26 tests) covers the derivation; README:353-359 documents it as the shipped convention. **This is the single biggest simplification available to item 14.** **[verified]**

`adopt_unique_volume_name()` (`4596-4605`) produces literally `mackas-<base>`, disambiguated by probing `${candidate}-{tmp,dl,sstate}`. The item's proposed convention and adopt's existing one are the *same convention*.

**(b) `--config` and `$MACKAS_CONF` deliberately bypass `config_file_is_safe()`.**
In `load_config()` (`mackas:818-896`) the explicit branch (`821-857`) checks readability only and sources at `862` with no ownership/permission check. Only the default search path (`884-891`) calls `config_file_is_safe()` (`796`). The comment at `869-880` gives the rationale: a path typed out loud is a request; `./mackas.conf` was an ambush. **Consequence:** a `--project NAME` that *derives* a path the user did not type in full is closer to the search path than to `--config`, so it **must** apply `config_file_is_safe()`. Getting this backwards silently widens invariant 5. **[verified]**

**(c) The held-volume gap on the build path.**
`cmd_exec()` refuses all three volumes at `mackas:5659-5666`, with the comment at `5654-5658` explaining that a second attach otherwise fails with an opaque Virtualization.framework error. `cmd_shell()` (`5552-5559`) runs `require_mackas_root` → `ensure_workspace_attached` → `ensure_kas_container_installed` → `ensure_project_checked_out` → `run_kas`, with no volume check. `cmd_smoketest()` (`5427`) likewise. `run_kas()` (`4903`) has none either. `ensure_volume()` (`3812`) *detects* a held volume but deliberately skips rather than refuses (`3828-3832`) — right for `setup`, wrong as a model for a build. **[verified]**

**(d) Volume names are derived in TWO places, and both must change together.**
`derive_paths()` (`mackas:1176`) has an early-return branch for "no `MACKAS_ROOT`" that still sets `MACKAS_VOL_TMP/_DL/_SSTATE/_LEGACY` (`1202-1205`), and a main branch that sets the same four again (`1279-1285`). `status`, `help` and `volume list` on a machine with no root configured go through the first. Any new derivation rule added to only one produces a tool that prints one set of names and operates on another. **[verified]**

**(e) A fourth site hardcodes the three volume names.**
`restart_container_daemon()` greps `container inspect` output for `MACKAS_VOL_TMP`/`_DL`/`_SSTATE` by name to decide "a build is in progress, refuse" (`mackas:1645-1647`). Under a shared `-dl` this stays *correct* (a second project's build genuinely holds `mackas-shared-dl`, and restarting the daemon under it is genuinely unsafe) but the message names the wrong project. Message tweak, not logic change. **[verified]**

**(f) Registering a new setting is a four-place operation.**
`SETTING_NAMES` (`mackas:82-119`) drives `snapshot_env`/`restore_env` (`300-320`), `snapshot_defaults`/`mark_explicit_from_config` (`334-346`), `is_setting_name` (`356`) and therefore `--set`/`set`/`get`/`unset`. `SETTINGS_INTERPOLATED` (`397-413`) drives `validate_settings()` (`437`). `MACKAS_VOLUME_NAME` is in both (`84`, `401`) and is separately space-validated in `setup_volumes()` (`3854-3858`). A new volume-name knob missing from either list silently loses environment precedence *and* the quote/backtick/control-char check. **[verified]**

**(g) `setting_is_explicit()` is the right lever for "derive by default, respect an override" — with one trap.**
`setting_is_explicit NAME` (`mackas:348`) reports whether a value differs from the factory baseline captured by `snapshot_defaults()`, or came from the environment / `--set`. `prompt_setup_settings()` (`mackas:4351`) already relies on exactly this distinction. **The trap:** `mark_explicit_from_config()` (`341-346`) compares *values*, so a config file that literally re-states the factory value (`MACKAS_VOLUME_NAME="oe-build"`) reads as **not** explicit. A design that says "if the stem is not explicit and a project is known, derive `mackas-<project>`" would silently relocate such a user's volumes. See §5. **[verified]**

**(h) `env.sh` is per-root and bakes three things that become per-project.**
`MACKAS_ENV_SH="$MACKAS_BASE/env.sh"` (`mackas:1268`). `setup_shim_and_env()` (`3231`) generates it with a frozen `MACKAS_RUNTIME_ARGS` containing the volume names (`3389`), `MACKAS_KAS_FRAGMENT_REPO` (`3395`) and `MACKAS_WORK` (`3405`). All three differ per project under this item. The `kas-container()` function (`3474`) delegates `--runtime-args` to the generated wrapper script (`write_kas_wrapper()`, `3949`), which recomputes them live — so it resolves *whatever project that shell's environment selects*, not the one env.sh was generated for. **This is why the project selector must work as an environment variable, not only as a CLI flag**: a sourced env.sh exports it, and the live recompute then lands on the right volumes. **[verified]**

**(i) The canonical kas fragment is per-root, and the example cleanup deletes it.**
`MACKAS_KAS_FRAGMENT_SRC="$MACKAS_KAS/macos.yml"` (`mackas:1272`); the per-checkout copy `MACKAS_KAS_FRAGMENT_REPO="$MACKAS_PROJECT/kas/macos-local.yml"` (`1273`) is written by `cp` at `4289`. `cleanup_example_project()` does `rm -f "$MACKAS_KAS_FRAGMENT_SRC"` (`5385`) — it deletes the *shared canonical* copy. Harmless today (the example path only runs when nothing is configured, and `setup` rewrites it), but it is a site that must be revisited the moment the canonical copy becomes per-project. **[verified]**

**(j) `mackas volume resize` (grow) has landed.**
`volume_resize()` `mackas:8015`, dispatched at `8355`, with `tests/volume_resize_real.bats` as the opt-in real suite. TODO item 4's "a volume cannot be grown after creation" is stale, and `mackas.conf.example` repeats the same stale line under `MACKAS_VOLUME_SIZE_*`. **This materially de-risks item 14's disk question**: a per-project cap is no longer a one-way door. **[verified]**

**(k) kas has first-class support for shared git object storage.**
`KAS_REPO_REF_DIR` is validated by `kas-upstream/kas-container:242`, forwarded rw as `/repo-ref` at `kas-upstream/kas-container:634`, and read by `kas/context.py:88`; the CHANGELOG records auto-creation of refs when it is set. This is the grounded answer to "per-project `work/` duplicates poky-sized clones." **[verified in the pinned upstream source; never exercised by mackas — [unmeasured] in practice]**

**(l) Disk accounting is single-config today.**
`total_volume_gb()` (`mackas:1483`) sums *this* config's three caps; `check`'s free-space test (`2276-2283`) compares that plus `MACKAS_FREE_SPACE_MARGIN_GB` against actual free space. Nothing sums across projects, and nothing could — there is no registry of projects. **[verified]**

---

## 2. Design decisions

Each states a recommendation, the reasoning, and what would change it.

### Decision A — `--project` is a config **selector**, not a setting, and not a precedence layer

**Recommend:** a global `--project NAME` flag and a `$MACKAS_PROJECT_NAME` environment variable, both resolved inside `load_config()` in the same `else` branch that handles `$MACKAS_CONF` (`mackas:840-857`), resolving to `$HOME/.config/mackas/projects/NAME.conf`. Unlike `--config`, the derived path **is** passed through `config_file_is_safe()` before sourcing (finding (b)). `MACKAS_PROJECT_NAME` is deliberately **not** added to `SETTING_NAMES`.

**Why:** it reuses the single-source machinery verbatim — no second source point, no fifth precedence rung, invariant 4 untouched. It matches what `adopt` already writes and already tells users to type (`4740`, `4788`), so `mackas adopt <path>` then `mackas --project <name> shell` is one story rather than two competing ones. Keeping it out of `SETTING_NAMES` is what stops `mackas set MACKAS_PROJECT_NAME foo` from writing a project selector *into* a project config, which is circular.

**Precedence within the selector:** `--project` beats `$MACKAS_PROJECT_NAME`; both are refused when `--config` or `$MACKAS_CONF` is also given (an explicitly named file and a derived one are two different requests; pick a refusal with a specific message over a silent winner).

**What would change it:** a concrete need for settings that are genuinely *global across all projects* and must not be repeated per file — a machine-wide `KAS_IMAGE` pin is the plausible one. Until such a setting exists, duplication across a few small generated files is cheaper than a new precedence rung. `adopt` already duplicates `MACKAS_ROOT`/`MACKAS_SHORT_LINK` this way and it has not hurt.

### Decision B — volume naming: derive from the *selector*, never from `MACKAS_PROJECT_DIR`

**Recommend** a new `derive_volume_names()` helper, called from **both** branches of `derive_paths()` (finding (d)):

```
stem  = explicit MACKAS_VOLUME_NAME                 , if set explicitly
      | "mackas-<project>"                          , if a project SELECTOR named one
      | "oe-build"                                  , otherwise (frozen legacy default)

MACKAS_VOL_TMP    = "${stem}-tmp"
MACKAS_VOL_SSTATE = explicit MACKAS_VOLUME_SSTATE_NAME
                  | "mackas-sstate-${MACKAS_SSTATE_GROUP}"  when a group is named
                  | "${stem}-sstate"
MACKAS_VOL_DL     = explicit MACKAS_VOLUME_DL_NAME
                  | "mackas-shared-dl"   when a project selector named one
                  | "${stem}-dl"         otherwise  (frozen legacy default)
```

The load-bearing word is **selector**. Volume identity keys off `--project`/`$MACKAS_PROJECT_NAME` — the *new*, opt-in surface — and **never** off `MACKAS_PROJECT_DIR`, which every existing user already has set and which item 25's `_mackas_derive_project()` (`mackas:3415`) sets automatically from a hand-typed file list. See §5 and §4.5; the whole backward-compatibility story rests on this.

`MACKAS_SSTATE_GROUP` is a plain setting (registered in `SETTING_NAMES`, sensible in a per-project config file) rather than a flag: it is a property of the project, not of the invocation.

**What would change it:** if real use shows people want per-project volumes *without* adopting the selector, the rule could relax to "derive when `MACKAS_PROJECT_DIR` is explicit **and** `MACKAS_VOLUME_NAME` is not present as a literal line in the loaded config file" — but that requires reading the config file as *text* to distinguish "absent" from "set to the factory value" (finding (g)), a new capability and a new failure mode. Not worth it up front.

### Decision C — `work/` becomes per-project only when a project selector is used

**Recommend:** `KAS_WORK_DIR` (`run_kas:4955`) becomes `$MACKAS_WORK/$MACKAS_PROJECT_NAME` when a selector named a project, and stays `$MACKAS_WORK` otherwise. `MACKAS_PROJECT` becomes `$MACKAS_WORK/$name/$MACKAS_PROJECT_DIR` in the same case. Pair it with `KAS_REPO_REF_DIR=$MACKAS_WORK/.repo-ref` (finding (k)) so the duplicated clones cost objects once.

This composes with item 19 exactly as that item predicts: the workspace image mounts at `work/` itself and per-project subdirs live inside it — one image, one cap, one blast radius. `.repo-ref` also lands inside the image, which it must (case-sensitive git object storage).

**Requires** extending `_mackas_derive_project()` (`mackas:3415`), which distinguishes "cwd is `work/`" from "cwd is a checkout under `work/`" by comparing `$PWD` and `${PWD%/*}` against `$MACKAS_WORK` (`3423`, `3450`). A two-level layout adds a third case and makes the two existing ones ambiguous. See phase 5.

**What would change it:** if `KAS_REPO_REF_DIR` does not work well over virtiofs (plausible — it is a bind mount like `work/`, though `work/` already works), the duplication cost is real and the decision reverts to "shared `work/`, documented hazard". That measurement is a prerequisite for the phase, not for the plan. **[unmeasured]**

### Decision D — per-project `env.sh`, canonical fragment and logs

**Recommend:** under a selector, `env.sh` → `$MACKAS_BASE/env-<name>.sh`, canonical fragment → `$MACKAS_KAS/macos-<name>.yml`, logs → `$MACKAS_LOGS/<name>/`. Each generated `env-<name>.sh` exports `MACKAS_PROJECT_NAME=<name>`, which is what makes the wrapper's live `--runtime-args` recompute land on the right volumes (finding (h)). With no selector, all three paths are exactly what they are today.

Item 13's lock/dump artifacts then have an obvious home: `$MACKAS_LOGS/<name>/` alongside the rung logs. See §4.4.

### Decision E — disk: fix the accounting, do not guess the numbers

**Recommend:** `check` and `setup` sum the caps of **every volume whose name matches the `mackas-*` convention** that actually exists on the machine — the volumes are ground truth; config files can be stale or absent. Report it as a second line under the existing free-space check (`2276-2283`) and keep the existing single-config check as the pass/fail gate.

Do **not** shrink the shipped default caps as part of this item. `volume resize` grows now (finding (j)), so a too-small cap is recoverable, and the right numbers are item 4's unmeasured question. Recommend instead that `setup`, when a selector is used *and* other `mackas-*` volumes already exist, prompt for the TMPDIR size with a lower suggested default and say why.

### Decision F — `mackas build` ambiguity rule, decided up front

`mackas build <project|path> <chain> [--target X]` has a genuine ambiguity: is `meta-qcom` a project name or a directory?

- Contains `/`, or starts with `.` or `~` → a **path**. Resolve it, require it under `$MACKAS_WORK` (kas `cd`s into one checkout; a sibling outside the `/repo` mount cannot work — the same constraint `_mackas_derive_project()` documents at `3444-3448`), derive the project name from the basename.
- Otherwise → a **project name**: look for `~/.config/mackas/projects/<name>.conf`; if absent, fall back to `$MACKAS_WORK/<name>` as a checkout; if neither, refuse and list what does exist.
- A path-based checkout must pass `ensure_workspace_attached()` (`mackas:3019`) **before** the case-sensitivity probe — item 19 flags this explicitly, and getting the order wrong makes the probe report on the underlying case-insensitive drive.

`build` joins the tail-capturing commands in `main()` (`8518-8618`) so `--target` and the chain are parsed by `cmd_build`, not by the global loop.

### Decision G — `mackas projects` as a first-class listing command

Not in the item, but every other decision needs it: `--project NAME` fails better when the tool can say what names exist, `check`/`status` need somewhere to nudge about the shared dl, and the disk-budget line needs a home. `mackas projects` lists `~/.config/mackas/projects/*.conf` with, per project, its volume names, whether each exists, its cap, and whether anything holds it. Small, read-only, and it makes phases 2-4 testable without a build.

---

## 3. Phasing

The item proposes 1 (dl knob + held-volume refusal) → 2 (first-class projects) → 3 (`mackas build`) → 4 (sstate groups + migration helper). **Validation:**

- Phase 1 bundles two unrelated changes. The held-volume refusal fixes an existing invariant violation and depends on nothing; the dl-name knob is a config surface with a small coupling to `adopt_unique_volume_name()`'s `-dl` probe (`4600`). **Split them.**
- Phase 1's dl knob really is shippable alone — the derivation sites are just `1202-1205` and `1279-1285`, and the "empty means derive" idiom `MACKAS_NFS_MOUNT` uses (`609`, `1219`) is already in the file to copy. Confirmed independent. **[verified]**
- Phase 2 as written is far too large: it bundles the config selector, volume derivation, per-project fragment/logs, per-project `work/`, and command scoping. Per-project `work/` is the highest-risk single change in the item (§4.3) and must not ride along with a config-surface change.
- Phase 3 (`mackas build`) depends on the selector and nothing else; it is mostly argument parsing.
- Phase 4's sstate groups are a *two-line* addition to Decision B's rule once the selector exists; the migration helper is independent of everything and could ship at any point.

**Recommended order** — each row independently shippable and independently revertible:

| # | Phase | Depends on | Size | Risk |
|---|---|---|---|---|
| 0 | Held-volume refusal on the build path | — | XS | low |
| 1 | `MACKAS_VOLUME_DL_NAME` + `MACKAS_VOLUME_SSTATE_NAME` knobs | — | S | low |
| 2 | `--project` / `$MACKAS_PROJECT_NAME` selector + `mackas projects` | — | M | medium (security surface) |
| 3 | Project-derived volume names + `mackas-shared-dl` default | 1, 2 | M | **high (backward compat)** |
| 4 | Per-project env.sh, canonical fragment, logs | 2, 3 | M | medium |
| 5 | Per-project `work/` + `KAS_REPO_REF_DIR` | 2, 4 | L | **highest** |
| 6 | `mackas build <project\|path> <chain> [--target]` | 2, 3 | M | medium |
| 7 | sstate groups + migration helper | 3 | S | low |
| 8 | Aggregate disk accounting in `check`/`status` | 2, 3 | S | low |

Phase 8 could move earlier; it is last only because it reads best once `mackas projects` exists.

---

### Phase 0 — Refuse a held volume on the build path

**Why first:** it closes an AGENTS.md invariant-3 gap that exists *today*, single-project, and it is the enforcement mechanism the rest of item 14 assumes ("mackas must detect the held volume and refuse the second build naming the holder"). Shipping it before any sharing exists means the mechanism is proven before it becomes load-bearing.

**Tasks**
- Add `refuse_held_build_volumes()` next to `volume_in_use()` (`mackas:1808`), modelled verbatim on `cmd_exec()`'s loop (`5659-5666`) including its message.
- Call it from `run_kas()` (`4903`) *after* the `--dry-run` early return at `4941`, so `--dry-run` stays a pure no-op that never queries the daemon. Then replace `cmd_exec()`'s inline loop with a call to the same helper.
- Decide the fail-closed policy explicitly: `volume_in_use()` returns 0 ("in use") with a `warn` when `container ls`/`inspect` fails (`1813-1819`). In `run_kas` that means a daemon hiccup blocks a build. **Recommend keeping fail-closed**, matching `cmd_exec`, and *not* adding a `--force` escape — invariant 3 has no escape hatch and `ro` is explicitly not one.

**Files/functions:** `mackas` — new helper near `1808`; `run_kas()` `4903`; `cmd_exec()` `5659-5666`.

**Tests** (new `tests/held_volume.bats`, or extend `tests/volumes.bats`; the mock `container` under `tests/mock/` already supports this shape — `tests/exec.bats` exercises the equivalent path today):
- `shell` refuses when the mock reports the tmp volume held; same for dl and sstate independently.
- `smoketest` refuses likewise, *before* prompting the ladder confirmation.
- `--dry-run shell` does **not** query the daemon (assert the mock recorded no `container ls`) — mutation-test this one, it is easy to write vacuously.
- The refusal message names the specific volume, not "a volume".
- `exec` keeps its existing behaviour after the refactor (regression over `tests/exec.bats`).

**Confidence:** high. Every piece is copied from a working call site. The one judgement call — fail-closed in `run_kas` — is stated and reversible.

---

### Phase 1 — `MACKAS_VOLUME_DL_NAME` and `MACKAS_VOLUME_SSTATE_NAME`

**Tasks**
- Add both to `SETTING_NAMES` (`82-119`) and `SETTINGS_INTERPOLATED` (`397-413`) — finding (f). Default both empty in `set_defaults()` near `576`, with the "empty means derive" comment idiom `MACKAS_NFS_MOUNT` already uses (`609`).
- Derive in `derive_paths()`, **both branches** (`1202-1205` and `1279-1285`) — finding (d). The clean shape is a small `derive_volume_names()` called from each.
- Extend `setup_volumes()`'s whitespace refusal (`3854-3858`) to cover the two new names; today it guards only the stem, and the resulting `-v NAME:/downloads` lands in the same word-split `--runtime-args` string (`kas_runtime_args()` `1398`, mounts at `1404-1406`).
- `status` already prints the three volumes by resolved name (`6779-6781`); check that nothing else prints the *stem* where it would now mislead (`6696-6700`).

**Tests** (`tests/volumes.bats`, which already has the `runtime-args:` family at `70-121`):
- `MACKAS_VOLUME_DL_NAME=shared-dl` puts `-v shared-dl:/downloads` in `runtime-args` and leaves tmp/sstate on the stem.
- Unset keeps `${stem}-dl` byte-identical to today (regression guard, and part of the §5 proof).
- A whitespace-bearing `MACKAS_VOLUME_DL_NAME` is refused by `setup`, not word-split.
- With no `MACKAS_ROOT` at all, `status` reports the same names as with one (covers the two-branch trap in finding (d)).
- Both names appear in `mackas status`'s settings listing and round-trip through `set`/`get`/`unset` (`tests/set_get_unset.bats` shape).

**Risk:** low. One flagged coupling: `adopt_unique_volume_name()` (`4596-4605`) probes `${candidate}-dl` for collisions. Harmless here; becomes *misleading* in phase 3 (it probes a volume the shared-dl default means will never be created). Fix it there, not here.

**Confidence:** high.

---

### Phase 2 — `--project NAME` / `$MACKAS_PROJECT_NAME` as a config selector, and `mackas projects`

**Tasks**
- `main()` (`8496`): add `--project NAME` / `--project=NAME` to the global flag loop (`8506-8517`), captured into a `PROJECT_FLAG` local alongside `config_flag`. It must be a **global** flag, before the command word, matching `--config`; add it to `die_on_misplaced_global_flag()` (`371-378`) so `mackas shell --project foo` gets the right message instead of "unknown option".
- `load_config()` (`818`): in the `else` branch, after the `$MACKAS_CONF` handling (`840-857`), resolve `--project`/`$MACKAS_PROJECT_NAME` to `$HOME/.config/mackas/projects/NAME.conf`. **Apply `config_file_is_safe()`** to the derived path — finding (b). Refuse (do not silently fall through to the search path) when the file is missing, with a message listing what does exist; extend the `allow_missing` path (`825-837`) to it for `set`/`get`/`unset`, which is exactly how a new project config gets bootstrapped.
- Validate `NAME` hard: it becomes a filesystem path component *and* (phase 3) a volume-name component inside a word-split `--runtime-args` string. Refuse anything outside `[A-Za-z0-9._-]`, refuse `.`/`..`, refuse a leading `-`. Reuse the character-class idiom from `refuse_unwritable_setting_value()` (`mackas:958`).
- Refuse `--project` together with `--config`/`$MACKAS_CONF` with a specific message.
- New `cmd_projects()`: list `~/.config/mackas/projects/*.conf`, and per project print name, `MACKAS_ROOT`, `MACKAS_VOLUME_NAME`, and (phase 3 onward) the three resolved volume names with exists/size/held. Read the values by **grepping the file, never sourcing it** — sourcing every config file found is precisely the RCE the search-path restriction exists to prevent, and a listing has no business executing anything. Register it in `main()`'s dispatch (`8660-8679`) and in `usage()`.

**Files/functions:** `main()` `8496-8624`; `load_config()` `818-896`; `die_on_misplaced_global_flag()` `371`; new `cmd_projects()` + `projects_usage()`; `usage()`.

**Tests** (extend `tests/config.bats`, 63 tests, including the RCE guards at `120-159`):
- `--project foo` loads `~/.config/mackas/projects/foo.conf` (fixture `$HOME` redirect, as `tests/config.bats` already does).
- A group-writable project config is **ignored with a warning**, exactly like a group-writable searched config (`tests/config.bats:233`) — mutation-test this; it is the security-critical assertion of the phase.
- A world-writable project config, and one in a group-writable directory, likewise.
- `$MACKAS_PROJECT_NAME=foo` has the same effect; `--project bar` beats it.
- `--project` + `--config` is refused with a message naming both.
- `--project ../../etc/passwd`, `--project .`, `--project -x` are refused before any file access.
- A missing project config is refused with a message listing existing ones — and `mackas --project new set MACKAS_ROOT /x` *creates* it.
- `help`/`-h` with `--project` still never sources anything (`tests/config.bats:173-201` shape).
- `mackas projects` on an empty dir prints a useful nothing-here message; with two fixtures it lists both and does **not** execute a `$(touch sentinel)` planted in one of them.

**Risk:** medium — this touches the config-loading security surface. Every new path needs the same four safety tests the searched path already has.

**Confidence:** high on mechanism and on the safety rule (grounded in finding (b)); medium on the exact UX of `--project` + `--config` (a refusal is defensible, so is "explicit file wins with a warning" — pick one and test it).

---

### Phase 3 — Project-derived volume names and the shared downloads default

**This is the backward-compatibility phase. Read §5 before implementing.**

**Tasks**
- Implement Decision B's `derive_volume_names()` in both `derive_paths()` branches.
- Key derivation off the **selector**, not `MACKAS_PROJECT_DIR` — the rule that makes §5 hold.
- `mackas-shared-dl` becomes the dl default **only** under a selector; per-project opt-out is `MACKAS_VOLUME_DL_NAME` in that project's config (added in phase 1 — which is why phase 1 comes first and is genuinely shippable alone).
- Fix `adopt_unique_volume_name()` (`4596-4605`): stop probing `${candidate}-dl` when the shared-dl convention applies, or a project named `shared` collides confusingly. Consider having `adopt` write `MACKAS_VOLUME_DL_NAME=mackas-shared-dl` explicitly, so an adopted config stays a complete, readable record.
- `restart_container_daemon()` (`1645-1647`): message tweak per finding (e) — "a build is using `<volume>`", not "your build".
- `cmd_destroy()` (`6956`) destroys all three volumes plus the legacy one (`6993`). **Under a shared dl this is a data-loss bug**: destroying project A takes every other project's downloads. It must skip a volume whose name is not derived from this project's own stem, and say so loudly.
- Same audit for `cmd_clean downloads` (`7267-7273`) — recommend a confirmation that names the sharing — and, once groups exist (phase 7), for `clean sstate` (`7275-7277`).

**Tests:**
- No selector, no `MACKAS_VOLUME_NAME` in config → `oe-build-{tmp,dl,sstate}`, byte-identical to today.
- No selector, `MACKAS_VOLUME_NAME=custom` → `custom-{tmp,dl,sstate}`, unchanged.
- `MACKAS_PROJECT_DIR=meta-ai` with **no** selector → still `oe-build-*`. **Mutation-test this**; it is the assertion that stops every existing user's volumes moving.
- `--project meta-ai` → `mackas-meta-ai-tmp`, `mackas-meta-ai-sstate`, `mackas-shared-dl`.
- `--project meta-ai` with `MACKAS_VOLUME_DL_NAME=mackas-meta-ai-dl` → per-project dl (the opt-out).
- `--project meta-ai` with `MACKAS_VOLUME_NAME=legacy-thing` → explicit stem wins over the convention.
- `destroy` under a shared dl refuses to delete `mackas-shared-dl` and says why.
- `runtime-args` under a selector contains no whitespace (re-run the existing `tests/volumes.bats:111` guard with a derived name).

**Risk:** high, concentrated entirely in the "when do we derive" rule. Everything else is mechanical.

**Confidence:** high on mechanism; **high on the rule, but it deserves a second reader** — the failure mode (volumes silently change identity, so the next build is cold and the sstate cache appears to have vanished) is bad enough that the `MACKAS_PROJECT_DIR`-without-selector test should be written first.

---

### Phase 4 — Per-project `env.sh`, canonical fragment and logs

**Tasks**
- `derive_paths()` (`1266-1273`): `MACKAS_ENV_SH`, `MACKAS_KAS_FRAGMENT_SRC` and `MACKAS_LOGS` gain a `<name>` component under a selector; unchanged otherwise.
- `setup_shim_and_env()` (`3231`): the generated `env-<name>.sh` must `export MACKAS_PROJECT_NAME=<name>` using the `${VAR:-…}` guard idiom already used for `MACKAS_KAS_AUTO_FRAGMENT`/`_PROJECT` (`3401-3402`). Item 25 fixed exactly this class of clobbering bug; the new export must not reintroduce it.
- `setup_kas_fragment()` (`4134`) writes the per-project canonical copy; the `cp` into the checkout (`4289`) is unchanged.
- `cleanup_example_project()` (`5381-5387`): re-check that its `rm -f "$MACKAS_KAS_FRAGMENT_SRC"` (`5385`) only ever names the example's own copy — finding (i). Under per-project fragments it becomes *safer*, but assert it with a test rather than assuming.
- `smoketest_rung()`'s log path (`5237`) picks up `MACKAS_LOGS/<name>/` for free; `clean`'s log wipe (`6839` message, `clean_tmpdir_volume` `7039`) must scope to the project's own log dir, not the whole tree.

**Tests:** `env-<name>.sh` exports `MACKAS_PROJECT_NAME`; it is valid bash 3.2 (`tests/volumes.bats:507` shape); a pre-set `MACKAS_PROJECT_NAME` survives sourcing it (the item-25 clobbering regression); `mackas --project a clean` does not touch `logs/b/`; two projects' canonical fragments coexist.

**Risk:** medium. The generated-file surface is well covered; the sharp edge is `clean` scoping.

**Confidence:** high.

---

### Phase 5 — Per-project `work/` and `KAS_REPO_REF_DIR`

**The highest-risk phase. Do not bundle it with anything.**

**Tasks**
- `run_kas()` (`4955`): `KAS_WORK_DIR="$MACKAS_WORK/$name"` under a selector. Add `KAS_REPO_REF_DIR="$MACKAS_WORK/.repo-ref"` to the same env block (kas-container forwards it rw as `/repo-ref` — `kas-upstream/kas-container:634`).
- `derive_paths()` (`1266`): `MACKAS_PROJECT="$MACKAS_WORK/$name/$MACKAS_PROJECT_DIR"`.
- `_mackas_derive_project()` (`3415-3470`): handle the extra level. It has exactly two cases today — `$PWD == $MACKAS_WORK` (strip the leading component from every entry, `3423-3449`) and `${PWD%/*} == $MACKAS_WORK` (entries already relative, `3450-3453`). With `work/<project>/<checkout>` the second now means "cwd is a project dir", and a third case appears. The sibling-spanning refusal (`3444-3448`) must be preserved verbatim — it is what stops a wrong-but-parsing derivation.
- `setup_project()` (`4104`): its `mkdir -p "$MACKAS_WORK"` (`4126`) becomes the per-project dir.
- `clear_stale_sockets()` (called from `run_kas:4977`) sweeps `$MACKAS_WORK/build` and the checkout — re-scope.
- `ensure_workspace_attached()` (`3019`) is unchanged: the mount point stays `work/` itself, per item 19's own analysis.
- Migration for an existing root: `work/` already holds a flat set of checkouts. **Do not auto-move them.** `mackas projects` should report "flat layout" and offer an explicit `mackas project migrate <name>` that `mv`s the known checkouts into `work/<name>/`. Silent restructuring of a directory holding uncommitted work is exactly what this project reserves `confirm()`/`die()` for.

**Tests:** `_mackas_derive_project` unit coverage for all three cwd cases plus the sibling refusal (extend the item-25 tests in `tests/volumes.bats`); `KAS_WORK_DIR` under a selector; flat-layout detection and its refusal to auto-migrate.

**Risk: highest in the item.** See §4.3. **Confidence: medium.** The `KAS_REPO_REF_DIR` mitigation is verified present in the pinned kas but never exercised by mackas — treat "does `/repo-ref` behave over virtiofs" as a live-Mac prerequisite, not an assumption. **[unmeasured]**

---

### Phase 6 — `mackas build <project|path> <chain> [--target X]`

**Tasks**
- `main()` (`8518-8618`): add `build` as a tail-capturing command, same shape as `clean`/`exec`.
- `cmd_build()`: resolve the first positional per Decision F; treat the second positional as `MACKAS_KAS_CONFIG` for this invocation only — an *ephemeral* override, same philosophy as `setup`'s size flags; never persist it. `--target X` maps onto the `build ... --target` invocation `smoketest_ladder()` already builds at `5514`.
- Generate the fragment on demand when missing, reusing the existing offer in `cmd_smoketest` (`5457-5462`) rather than writing a second one.
- Path-based checkouts: `ensure_workspace_attached()` **before** the case-sensitivity probe (Decision F).
- Route through `run_kas()` so phase 0's refusal, `auto_fstrim`, the socket sweep and buildstats clearing all apply unchanged.

**Tests:** name vs path disambiguation both ways, plus `./meta-ai` forcing the path reading; a path outside `$MACKAS_WORK` refused with the `/repo`-mount explanation; `--target` reaches the kas argv (`tests/kas_argv_replay.bats` is the existing fixture-replay shape); a chain given on the command line is not written to any config file.

**Confidence:** high. Mostly argument plumbing over machinery that already exists.

---

### Phase 7 — sstate groups and the migration helper

**Tasks**
- `MACKAS_SSTATE_GROUP` into `SETTING_NAMES`/`SETTINGS_INTERPOLATED`; two lines in `derive_volume_names()` per Decision B.
- `mackas share-downloads` (name TBD): `volume_duplicate` (`7543`) from the current dl volume to `mackas-shared-dl`, then `delete_volume` (`1730`) the old one after confirmation — the item's own `duplicate`+`destroy` in one command. Both primitives already refuse held volumes (`7561`).
- `check`/`status` nudge when a `${stem}-dl` exists alongside a project selector — model it on the existing legacy-volume nudge (`setup_volumes:3866-3872`, plus `MACKAS_VOL_LEGACY` reporting in `check`/`status`).

**Tests:** two projects with the same group resolve to one `mackas-sstate-<group>`; different groups do not; the migration helper refuses rather than merges when `mackas-shared-dl` already exists (confirm `volume_duplicate`'s existing destination check at `7543-7593`); the nudge fires exactly once.

**Confidence:** high.

---

### Phase 8 — Aggregate disk accounting

**Tasks:** per Decision E, sum caps across existing `mackas-*` volumes in `check` (`2276-2283`) and `status`; keep the single-config check as the gate and report the aggregate as information. `status_total_cap_gb()` (`1493`) is the model for "real cap when the volume exists, configured size otherwise".

**Tests:** with three fixture volumes present, the aggregate line reports their combined caps; with none, the line is omitted rather than printing 0.

**Confidence:** high on mechanism; the *numbers* remain item 4's unmeasured question.

---

## 4. The item's open questions

### 4.1 Disk budget — **partially resolvable now**

The item worries that four projects at today's caps plus a shared dl is ~680G of ceiling. Two things change the picture:

- `volume resize` grows a volume now (finding (j)), so a conservative initial cap is no longer a one-way door. Most of the pressure to get the number right up front disappears.
- The caps are ceilings on *sparse* images and `MACKAS_FSTRIM_AUTO=1` (`set_defaults:704`) already reclaims around every run. The real question was never the ceiling but the steady-state footprint of N projects, which nobody has measured.

**Resolution: close the "should setup sum across projects" half (Decision E, phase 8); keep the "what should the per-project caps be" half open and explicitly folded into item 4.** TODO item 4's stale "a volume cannot be grown" line should be corrected in the same commit that lands phase 8 — and so should the identical line in `mackas.conf.example` under `MACKAS_VOLUME_SIZE_*`. **[unmeasured]** on the numbers themselves.

### 4.2 sstate garbage collection / monthly rotation — **stays open, but narrower**

`mackas sstate prune --older-than N[d]` already exists (dispatch `8551`; `tests/sstate.bats`, 20 tests) and is age-based partial cleanup — the *mechanism* monthly rotation would need, without the volume-swapping. Rotation buys one extra thing prune does not: a hard guarantee that a stale hash-equivalence DB is discarded with the objects, since `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` puts the DB inside the volume.

**Resolution: stay open. What would close it is data — does `sstate prune` on a real shared volume leave the hashserve DB referencing pruned objects, and does that hurt?** That is item 21's live-verification territory. Do not build rotation speculatively; per-project (or per-group) `clean sstate` is the escape hatch and already exists.

### 4.3 Shared vs per-project `KAS_WORK_DIR` — **resolvable, and more urgent than the item implies**

The item calls the shared `work/` "churny when two projects pin different revs of the same layer". That undersells it. `run_kas()` sets `KAS_WORK_DIR="$MACKAS_WORK"` (`4955`), so `openembedded-core`, `bitbake` and every `meta-*` land as siblings in one directory. kas's normal `repos_checkout` step moves a shared checkout to whichever revision the *current* project pins — and unlike the `-k` hazard, no `--skip` set protects against it, because a real build *must* run those steps. `work/` is host APFS; the one-VM rule serializes volume access and says nothing about it. Concretely: build project A (oe-core at revA, plus a local commit), build project B (oe-core at revB), return to A — A's local commit is gone and A's TMPDIR is keyed to a tree that no longer exists.

This hazard **does not exist today** because there is one project. Item 14 creates it.

**Resolution: per-project `work/<name>/` (Decision C, phase 5), with `KAS_REPO_REF_DIR` answering the duplication cost.** The "duplicates poky-sized clones" objection is real but has an upstream-supported answer verified present in the pinned kas (finding (k)); what is *not* verified is that it behaves well as a virtiofs bind mount, which is a live-Mac measurement. **[unmeasured]**

**If phase 5 slips, phase 3 must not ship without a loud warning**, because per-project volumes *without* per-project `work/` is the exact configuration that makes this bite: the TMPDIRs stay separate (so nothing forces a rebuild that would surface the mismatch) while the sources underneath them silently swap.

### 4.4 Item 13's lock/dump artifacts need a per-project home — **resolved by phase 4**

The item warns item 13 will bake in the single-project assumption if built first. Decision D gives the answer: `$MACKAS_LOGS/<name>/`, or `$MACKAS_LOGS/` unchanged with no selector. A `lock`/`dump` artifact is per-project *and* per-chain, so the filename should carry a chain slug the way `smoketest_rung()` already slugs its rung name into `smoketest-${n}-${slug}.log` (`5237`) — reuse that slugging rather than inventing a second scheme.

**Resolution: item 13 can proceed independently provided it writes through `$MACKAS_LOGS` rather than a hardcoded path and slugs the chain into the filename.** That is a one-line constraint on item 13, not a dependency on item 14 landing first. Worth recording in item 13's own TODO entry.

### 4.5 (Not in the item, but it belongs here) Composition with item 25's auto-derivation

`_mackas_derive_project()` (`mackas:3415`) exports `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG` into a shell from a hand-typed `kas-container` file list, never over an already-set value (`3457-3467`). Item 14 must **not** extend it to derive a project *selector* or volume names. If it did, a user with an existing `oe-build-*` setup who types `kas-container shell meta-angstrom/kas/angstrom.yml` would have their volumes silently switch to `mackas-meta-angstrom-*` mid-session — a cold build, an apparently-vanished sstate cache, and no message connecting cause to effect. The derivation's own design principle ("a wrong derivation is worse than none") argues against it directly.

**Resolution: derivation stays scoped to `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG`. Volume identity keys off the explicit selector only.** This belongs as a comment in the code and an assertion in the tests, not just a plan note.

---

## 5. Backward-compatibility analysis

The item claims: "with no project named, today's `MACKAS_PROJECT_*` + `oe-build-*` path is frozen and keeps working." **Verified against the real precedence and derivation code, this holds — but only under Decision B's selector rule.**

**Volume naming.** Today `MACKAS_VOL_*` are unconditional string concatenations off `MACKAS_VOLUME_NAME` in both `derive_paths()` branches (`1202-1205`, `1279-1285`), with `MACKAS_VOLUME_NAME` defaulting to `oe-build` (`576`). Under Decision B the `otherwise` arm is that exact concatenation with that exact default. A user who never passes `--project` and never sets `$MACKAS_PROJECT_NAME` reaches it every time. **Frozen.**

**The trap, and why the rule is what it is.** The tempting alternative — "derive `mackas-<project>` when `MACKAS_VOLUME_NAME` is not explicit and a project is known" — breaks two existing populations:

1. Anyone whose config contains `MACKAS_VOLUME_NAME="oe-build"` verbatim. `mark_explicit_from_config()` (`341-346`) compares against the factory value, so that line reads as **not** explicit (finding (g)) and their volumes would move.
2. Every existing user, full stop — they all have `MACKAS_PROJECT_DIR` set (it is how you configure a project today, and `mackas.conf.example` documents it as one of the four settings), and item 25's `_mackas_derive_project()` sets it *automatically* for anyone driving kas by hand (§4.5).

Keying off the **selector** — a surface that does not exist yet, so nobody can already be using it — makes the compatibility argument airtight by construction rather than by careful reasoning about `setting_is_explicit`'s semantics. That is why Decision B is worded as it is.

**Config precedence.** Decision A adds no rung. `--project` decides *which file* `load_config()` sources, inside the existing single-source `else` branch (`840-857`). `snapshot_env`/`restore_env` (`300-320`) and `apply_cli_overrides` (`382`) are untouched, so AGENTS.md invariant 4 is literally unchanged. **[verified]**

**Config safety.** The derived path gets `config_file_is_safe()` (finding (b)) — *stricter* than `--config`. No existing path loses a check.

**Generated files.** Phase 4's per-project `env.sh`/fragment/logs diverge only under a selector. An existing `$MACKAS_BASE/env.sh` keeps its name, content and exports. The one new export (`MACKAS_PROJECT_NAME`) appears only in per-project copies and uses the `${VAR:-…}` guard so it cannot clobber a shell that set it first (`3401-3402` idiom).

**`work/`.** Phase 5 relocates only under a selector. Flat layouts stay flat and are never auto-migrated.

**Regression tests that constitute the proof** (listed in the phases above; gathered here because they are the compatibility contract):
- no selector + no `MACKAS_VOLUME_NAME` → `oe-build-{tmp,dl,sstate}`;
- no selector + `MACKAS_PROJECT_DIR=meta-ai` → still `oe-build-*` (**mutation-test**);
- no selector + `MACKAS_VOLUME_NAME="oe-build"` written verbatim → still `oe-build-*`;
- `env.sh` byte-comparable to today with no selector;
- `runtime-args` byte-identical to today with no selector.

The last two are the strongest form available and are cheap — `tests/volumes.bats` already asserts on `runtime-args` and `env.sh` content in that style.

---

## 6. Migration path for existing single-project users

Three populations, three paths. Nobody is forced to move.

**A. Do nothing.** Everything above is opt-in behind the selector. This must remain true and be stated in the README, not only in this plan.

**B. Adopt shared downloads without adopting projects.** One config line:

```sh
mackas set MACKAS_VOLUME_DL_NAME mackas-shared-dl
```

…preceded by the data move: `mackas volume duplicate oe-build-dl mackas-shared-dl` (`7543`) is an APFS clone — near-free, and it refuses a held source (`7561`) — then `mackas volume destroy oe-build-dl` once a build has proven the new one. Phase 7 wraps exactly this in `mackas share-downloads`, with the confirmation and the ordering (duplicate → verify → destroy, never destroy-first) built in. **This works without phase 2 or 3**, which is the argument for shipping phase 1 early.

**C. Become a named project.** For a user with one project today:

```sh
mackas --project meta-ai set MACKAS_ROOT /Volumes/oe/build     # creates the file
mackas --project meta-ai set MACKAS_PROJECT_DIR meta-ai
mackas --project meta-ai set MACKAS_KAS_CONFIG kas/base.yml:kas/qemuarm64.yml
mackas --project meta-ai set MACKAS_VOLUME_NAME oe-build       # keep the existing volumes
```

The last line matters and should be what `mackas projects` suggests: **keeping the existing stem is a supported end state**, not a half-migration. Renaming volumes to `mackas-meta-ai-*` is optional and costs a `duplicate`+`destroy` per volume; the only reason is cosmetic consistency once a second project exists.

Recommend a `mackas project init [NAME]` in phase 2 or 6 that writes that file from the *currently resolved* settings — four `config_write_setting()` calls (`930`) against values `derive_paths()` has already computed, removing the only genuinely fiddly step. `cmd_adopt()` (`4748-4756`) is the working model.

**The nudge.** `check`/`status` should mention the shared-dl option once a second project's volumes exist on the machine, in the same register as the existing legacy-volume nudge (`3866-3872`) — informational, not nagging, never automatic.

---

## 7. Documentation that goes stale (same commit, per AGENTS.md)

| File / location | What changes |
|---|---|
| `README.md:418` (settings table) | `MACKAS_VOLUME_NAME` row: the stem is now a *fallback*; add `MACKAS_VOLUME_DL_NAME`, `MACKAS_VOLUME_SSTATE_NAME`, `MACKAS_SSTATE_GROUP` |
| `README.md:395-410` (Configuration) | `--project` as a config selector alongside `--config` and the search path; the safety difference |
| `README.md:340-368` (Adopting a root) | reframe as "adopt writes a project config" — one entry point to the project model, not a separate feature |
| `README.md:188-192` (volume examples) | examples use `oe-build-*`; add a project-named one |
| `docs/architecture.md:110`, `124-126`, `152-154`, `170`, `190` | the volume-name table and every literal `oe-build-*` in the `--runtime-args` example |
| `docs/architecture.md:235-245` | the `kas-container` wrapper section — per-project fragment paths, and the §4.5 statement that derivation does *not* touch volume identity |
| `docs/architecture.md:276` | `_mackas_derive_project`'s cwd cases, once phase 5 adds the third |
| `docs/storage.md` | shared dl / sstate groups; the one-VM consequence for cross-project concurrency; per-project caps |
| `mackas.conf.example` | the new settings; meta-ai becomes the worked *project-config* example (the item asks for this explicitly); correct the stale "a volume CANNOT be grown after creation" comment |
| `skills/mackas/SKILL.md` | driving a build against a named project |
| `TODO.md` item 4 | stale "cannot be grown" |
| `TODO.md` item 13 | record the `$MACKAS_LOGS`-relative constraint from §4.4 |
| `TODO.md` item 25 | record the §4.5 boundary |

---

## 8. Suggested landing order and per-commit shape

Each is one commit, docs included:

1. `volumes: refuse a held volume on the build path` — phase 0. Fixes an invariant-3 gap; no new surface.
2. `volumes: MACKAS_VOLUME_DL_NAME / _SSTATE_NAME knobs` — phase 1. Makes migration path B available immediately.
3. `config: --project NAME selects a per-project config file` + `projects: list configured projects` — phase 2, possibly two commits.
4. `volumes: derive names from the project selector; shared downloads by default` — phase 3. **The compatibility tests land in this commit.**
5. `setup: per-project env.sh, kas fragment and logs` — phase 4.
6. `kas: per-project work/ and a shared repo-ref dir` — phase 5, behind its own live verification.
7. `build: mackas build <project|path> <chain> [--target]` — phase 6.
8. `sstate: named sharing groups` + `volumes: share-downloads migration helper` — phase 7.
9. `check: aggregate disk budget across projects` — phase 8.

Commits 1 and 2 are worth landing regardless of whether the rest of item 14 ever proceeds: one fixes a live invariant violation, the other unlocks the shared-downloads win with a single config line.

---

## 9. Confidence summary

| Claim | Confidence |
|---|---|
| adopt already implements the naming convention and per-project config file | **verified** — `4596-4605`, `4740-4756`, `4788` |
| `shell`/`smoketest`/`run_kas` lack a held-volume check | **verified** — read all three |
| `load_config`'s explicit branch skips `config_file_is_safe` | **verified** — `821-862` vs `884-891` |
| Volume names derive in two places | **verified** — `1202-1205`, `1279-1285` |
| `setting_is_explicit` cannot distinguish "absent" from "set to the factory value" | **verified** — `341-346` |
| `KAS_REPO_REF_DIR` exists in the pinned kas and is forwarded rw | **verified** — `kas-upstream/kas-container:242,634`, `kas/context.py:88` |
| `KAS_REPO_REF_DIR` behaves acceptably over virtiofs | **unmeasured** — live-Mac prerequisite for phase 5 |
| Shared `work/` + per-project TMPDIR loses local commits in shared layers | **assumed** — follows from kas's `repos_checkout` semantics; not reproduced |
| Per-project caps should shrink | **unmeasured** — item 4's question, de-risked by `volume resize` |
| Monthly sstate rotation is needed | **open** — needs item 21's live prune data first |
| Decision A (selector, not layer) is the right call | high — but it is a judgement about the config model, and a reviewer disagreeing is a legitimate outcome, not a bug |
