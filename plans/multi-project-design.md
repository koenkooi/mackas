# Design: first-class multi-project support for mackas

Status: proposal for review. No code has been written. Grounded against mackas @ `5ae6099` (10,128 lines), `plans/14-first-class-projects.md`, TODO item 14, and the prior-art research (kas multi-project usage, repo/West/direnv/mise/bitbake-setup/docker-compose).

---

## 1. Summary

**The problem.** mackas today is structurally single-project: one root, one flat `work/` that is `KAS_WORK_DIR` for everything, one volume stem (`oe-build`) naming exactly three ext4 volumes. A second project means either typing `--config <full path>` on every invocation against a fully separate adopted root with its own private download cache, or sharing everything with the first project — including a flat `work/` where kas's `repos_checkout` will silently reset one project's layer pins when the other builds. The owner's requirements: multiple projects with different volumes on one machine; shared sstate and downloads volumes across projects, but never concurrently; and a UX that deduces the project from `$PWD` or the kas yaml location instead of demanding flags.

**The core bet.** Project identity is *pinned once, explicitly* (a standalone config file at `~/.config/mackas/projects/<name>.conf`, the file `adopt` already writes) and thereafter *selected implicitly* by structural matching: `$PWD` (or the kas yaml path) resolves to a project only when it lies inside a directory that a pinned project config already points at. Inference selects among pinned identities; it never mints one. This is the direnv/mise trust model with the consent moved to pin time, combined with west/repo's marker-based root discovery — and it makes the backward-compatibility argument hold by construction: a user with no pinned projects has nothing for inference to match, so nothing changes. Volume sharing needs no new concurrency mechanism at all: "shared but not concurrently" is exactly what the existing one-VM-per-ext4-volume rule already enforces, once the held-volume refusal (a pre-existing invariant-3 gap) actually ships on the build path.

## 2. Prior art synthesis

What the research supports adopting, and what it doesn't:

**Adopt: the two-level split (west, repo).** Directory search resolves *where you are*; it never fuzzy-matches *what you mean*. West walks up for `.west`; repo walks up for `.repo`; neither ever disambiguates between competing candidates — ambiguity is impossible by construction (exactly one marker on the path to `/`). mackas's equivalent marker is not a dotfile in the tree but the pinned config's recorded path: "is physical `$PWD` inside `<root>/work/<name>/` for some pinned `<name>`" is a total-order question with at most one answer per root. This is the derivation rule in §4.

**Adopt: consent before acting on a guess (direnv, mise).** direnv never executes an `.envrc` without a one-time `direnv allow`; mise fails hard rather than guessing in non-interactive contexts. mackas's version: the pinning act (`mackas project add` / `adopt`, both explicit user commands) *is* the allow. Inference only ever activates configs the user deliberately created, and every command that acts on a derived selection prints which project it resolved and why (one line, once per shell, reusing the existing `_MACKAS_PROJECT_NOTED` pattern).

**Adopt: never let a re-derivable name be the durable key (docker compose).** Compose deriving project identity from the directory name meant a rename orphaned volumes. mackas already has the right shape: `adopt` writes the resolved name into a config file once. The design rule that follows: a renamed or moved directory makes derivation *fail closed with a message*, never silently re-derive a fresh identity and touch fresh volumes.

**Adopt: bitbake-setup's cache-sharing shape.** One shared sstate + hashserve DB by default across Setups (`common-sstate=yes`), one `dl-dir` knob, per-setup build trees. mackas inverts the sstate default (private by default, shared opt-in via groups — justified in §5) but the "downloads shared by one convention knob, build trees always private" structure transfers directly. Note what does *not* transfer: bitbake-setup's *selection* UX is shell-state-based (sourced environment), not directory-based — mackas already has that half too (the generated `env.sh` exporting variables), and this design keeps both tiers rather than choosing one.

**What doesn't transfer / thin ground.** The research found no public repo running N genuinely independent kas trees with documented shared-cache wiring — iris-kas and isar-cip-core are both one-tree-many-targets via includes/multiconfig, a different problem. So there is no field-proven convention to copy for the exact "separate products, shared dl/sstate" case; the closest confirmed pattern is the env-var one (shared `DL_DIR`/`SSTATE_DIR` set process-wide, per-project `KAS_WORK_DIR`), which kas's own overlap rule is designed around. `KAS_REPO_REF_DIR` is documented and deliberate but unproven at scale in public, and unproven entirely over virtiofs — it stays the highest-risk phase, gated on live verification. The kas-devel shared-cache permissions thread ("don't write shared dirs directly, use mirrors") is about multi-*user* Linux hosts with concurrent writers; it does not apply to a single-user Mac where the one-VM rule serializes all access — worth saying explicitly so it isn't misapplied here.

## 3. The `~/oe/work` rethink

**Today** (unchanged for anyone who doesn't opt in):

```
~/oe -> $MACKAS_ROOT                  # MACKAS_SHORT_LINK
$MACKAS_ROOT/
  work/                               # KAS_WORK_DIR for everything
    meta-ai/                          # the checkout
    openembedded-core/  bitbake/ ...  # kas-cloned siblings
  bin/  container-volumes/  logs/  env.sh  macos.yml
```

**Proposed, with projects pinned** (additive; legacy contents untouched):

```
$MACKAS_ROOT/
  work/
    meta-ai/                # legacy checkout — still owned by the legacy (no-project) config
    openembedded-core/      # legacy kas-cloned sibling — untouched
    .repo-ref/              # shared git reference store (KAS_REPO_REF_DIR), created with the first project
    meta-qcom/              # PROJECT WORKSPACE for pinned project "meta-qcom" = its KAS_WORK_DIR
      meta-qcom/            #   the config checkout (mounted at /repo)
      poky/  meta-oe/ ...   #   kas-cloned layers, private to this project
  logs/meta-qcom/
  env-meta-qcom.sh
  macos-meta-qcom.yml
```

Key properties:

- **A project workspace is `work/<name>/`, and it is that project's entire `KAS_WORK_DIR`** — checkout and layer clones together, private. This dissolves the shared-`work/` data-loss hazard (the plan's finding 3: two projects pinning different revs of `openembedded-core`, kas resetting one under the other) structurally rather than by discipline. The `work/meta-qcom/meta-qcom/` stutter when the repo name equals the project name is cosmetic and accepted; it is what makes the layout uniform.
- **A first-level directory under `work/` is a project workspace if and only if a pinned config for that name exists.** Filesystem shape alone never decides. A legacy checkout `work/meta-ai/` with no pinned config is just a checkout, exactly as today. Consequence: `mackas project add <name>` must refuse a name that collides with an existing first-level entry in `work/` unless it is converting that very entry (see §8 migration).
- **Clone duplication cost is paid in git objects once**, via `KAS_REPO_REF_DIR=$MACKAS_WORK/.repo-ref` (kas's native, documented shared-object mechanism, explicitly safe for concurrent access on POSIX filesystems). This ships late (§8 phase 6) because it needs live verification over virtiofs on a real Mac first; until then, per-project workspaces work but duplicate full clones.
- **`MACKAS_SHORT_LINK` is unchanged.** `~/oe` still points at the one root. Projects are subdirectories of one root's `work/`, not new roots — `adopt` remains the tool for genuinely separate roots (external drive, migrated Mac), and adopted roots' projects participate in selection identically because selection reads pinned configs, not the short link (§4).
- **Zero-change guarantee for existing users, by construction:** every new path (`work/<name>/`, `env-<name>.sh`, `macos-<name>.yml`, `logs/<name>/`, `.repo-ref/`) is created only by an explicit `mackas project add`/`adopt`, and every behavioral fork keys off "a project selector resolved," which requires a pinned config to exist. No pinned configs → the code paths, file layout, volume names, and `KAS_WORK_DIR` are byte-identical to today. This is the plan's Decision B ("key off the selector, never off `MACKAS_PROJECT_DIR`") extended to the whole design: `MACKAS_PROJECT_DIR` is set for essentially every existing user, so nothing may ever key off it; the selector surface is new, so keying off it cannot affect anyone who hasn't used it.

## 4. Project identity & selection

### Pinning (identity creation — always explicit)

Two commands create pinned identities, both writing the same artifact, a **complete standalone config** at `~/.config/mackas/projects/<name>.conf`:

- **`mackas adopt <root>`** — exists today, unchanged role: adopting a foreign/second physical root. Already writes this exact file with `MACKAS_ROOT`, `MACKAS_VOLUME_NAME` (via `adopt_unique_volume_name()` → `mackas-<name>[-N]`), `MACKAS_PROJECT_*`. The design keeps it and treats its output as the canonical schema.
- **`mackas project add <name> [--url U --branch B | --from <existing-checkout>]`** — new; the in-root sibling of `adopt`. Creates `work/<name>/`, writes the pinned config (`MACKAS_ROOT` = current root, `MACKAS_VOLUME_NAME=mackas-<name>` via the same `adopt_unique_volume_name()` collision logic, dl/sstate policy per §5), and offers to clone or convert a checkout. Pin-time is where the two consequential choices are made explicitly, once: volume naming (a converted legacy setup may keep `oe-build` as a supported end state, per the plan's §6 population C) and dl/sstate sharing.

`mackas projects` (the plan's Decision G) lists everything pinned — name, root, volume names, volumes-exist, held-by — by **grepping, never sourcing** the config files. It is the discovery surface that makes a failed inference recoverable ("no project matched; you have: ...").

### Selection (per invocation — which config file `load_config()` sources)

Selection order, most explicit first; exactly one source wins and the rest are ignored:

1. `--config <path>` / `--project <name>` (CLI; mutually exclusive with each other)
2. `$MACKAS_CONF` / `$MACKAS_PROJECT_NAME` (environment; mutually exclusive)
3. **Derivation from physical `$PWD`** (new)
4. Default search path (`~/.config/mackas/config`, `~/.mackas.conf`) — today's behavior, and the terminal fallback

This is *selector* precedence — which file to source — and is orthogonal to invariant 4's value precedence. Once a file is selected, `defaults → config file → environment → --set` proceeds exactly as today: `snapshot_env`/`restore_env`/`apply_cli_overrides` are untouched. No fifth rung exists; a selector never contributes values, only a filename. (§6 expands.)

### The derivation rule, precisely

When no explicit selector is present:

1. Compute physical `$PWD` (`pwd -P`) — this defuses the short-link problem: `~/oe` is a symlink, and a user standing in `~/oe/work/meta-qcom/meta-qcom` has a logical path that never textually contains `$MACKAS_ROOT`. All comparisons in this design are physical-path comparisons on both sides.
2. Enumerate `~/.config/mackas/projects/*.conf`; for each, **grep** (never source) `MACKAS_ROOT`, and form the candidate workspace path `<root>/work/<name>` (name from the filename). Grep-not-source matters for invariant 5: no candidate file executes during selection; only the single winner is sourced, and — because the user did not type this path — only after `config_file_is_safe()` passes, unlike the typed `--config` path which deliberately skips it. The plan's Decision A gets this exactly right and it is load-bearing: a derived path under a predictable, name-guessable location is an ambush surface, not a request.
3. Physical-prefix-match `$PWD` against each candidate workspace. Zero matches → fall to tier 4 (today's behavior, verbatim). Exactly one → select it. More than one (only possible pathologically, e.g. an adopted root nested inside another root's `work/`) → **die, listing the candidates** — fail closed, never pick.
4. Special case, cwd == `work/` itself with a kas chain argument in hand (the documented hand-typed flow): the first path component of the first colon-entry names the workspace — `kas-container build meta-qcom/kas/base.yml:...` from `work/` derives project `meta-qcom` **iff pinned**, else derives nothing. This is the "location of the kas yamls" half of the owner's requirement, and it extends the existing `_mackas_derive_project()` logic rather than replacing it.

### Relationship to the existing machinery

- **`_mackas_derive_project()` (env.sh)** today derives `MACKAS_PROJECT_DIR`/`MACKAS_KAS_CONFIG` from `$PWD` — informational values, never volume-affecting, only-if-unset. It gains a project-aware first step (match against the project workspace, not just `$MACKAS_WORK`) and, on a pinned match, additionally exports `MACKAS_PROJECT_NAME`. The only-if-unset discipline is kept for all three.
- **The `bin/kas-container` wrapper** re-invokes `mackas runtime-args` as a fresh subprocess. That subprocess inherits cwd, so tier-3 derivation works inside it *automatically* — a hand-typed `kas-container build ...` from inside a pinned project workspace gets that project's volumes with no flag, no sourced env, no shell function. This is the single biggest non-hostility win in the design, it covers the primary real-world workflow (hand-typed kas-container, per the owner), and it is safe by the same construction: no pin, no match, frozen legacy behavior.
- **Per-project `env-<name>.sh`** (plan Decision D, kept) exports `MACKAS_PROJECT_NAME=<name>`, making tier 2 carry the selection into every subprocess for users who source it — the bitbake-setup shell-state strategy, layered *on top of* directory derivation rather than instead of it. Belt and suspenders: either tier alone resolves correctly; when both are present, tier 2 (explicit) wins.
- **Explicit override as escape hatch, not primary path:** `--project <name>` / `MACKAS_PROJECT_NAME` exist for cross-project operations from anywhere (`mackas --project meta-qcom clean` from `~`), CI, and scripts. When an explicit selector contradicts a would-be derivation (standing in A, `--project B`), explicit wins silently for read-only commands and with a one-line note for destructive ones.

### Failure modes of derivation (each with its defined outcome)

| Situation | Outcome |
|---|---|
| cwd outside any root/workspace | No derivation; tier 4; commands that require a project print the `mackas projects` list and die |
| cwd in a legacy checkout (`work/meta-ai/`, unpinned) | No derivation — not a project. Today's behavior exactly, including the existing `MACKAS_PROJECT_DIR` note |
| cwd reached via symlink / the `~/oe` short link | Physical-path comparison on both sides; resolves correctly |
| Workspace directory renamed/moved after pinning | Prefix match fails → fail closed, tier 4; `mackas projects` shows the stale pin (`work/<name>` missing) with a suggested `project repair`/re-pin. Never re-mint an identity from the new name (the compose lesson) |
| Two projects with the same name | Impossible within one root (filesystem uniqueness) and within the config dir (one file per name); `adopt_unique_volume_name()` already disambiguates volume stems machine-wide |
| Nested candidate workspaces (adopted root inside another root's `work/`) | Multiple matches → die listing both; `adopt` additionally warns at pin time when it would create this nesting |
| Chain spans sibling workspaces (`meta-a/...:meta-b/...` from `work/`) | Derive nothing (existing deliberate behavior — the sibling sits outside the `/repo` mount anyway) |
| Non-interactive invocation where derivation would matter but fails | Die with the candidate list; never prompt, never guess (the mise rule) |

Naming caveat to resolve before implementation: `_mackas_derive_project()` already exports a variable called `MACKAS_PROJECT` (checkout name, informational). The selector `MACKAS_PROJECT_NAME` is uncomfortably close. Options: rename the selector (`MACKAS_PROJECT_SELECT`?) or fold the old variable into the new one where a pin exists. Flagged in §9 rather than decided here.

## 5. Volume model

**Naming.**

| Volume | Unpinned (today) | Pinned project `<name>` | Override knob |
|---|---|---|---|
| tmp (`/build`) | `oe-build-tmp` | `mackas-<name>-tmp` — **always private** | `MACKAS_VOLUME_NAME` (stem) |
| dl (`/downloads`) | `oe-build-dl` | `mackas-shared-dl` — **shared by default** | `MACKAS_VOLUME_DL_NAME` |
| sstate (`/sstate`) | `oe-build-sstate` | `mackas-<name>-sstate` — private by default; `MACKAS_SSTATE_GROUP=<g>` → `mackas-sstate-<g>` | `MACKAS_VOLUME_SSTATE_NAME` |

This is the plan's Decision B and TODO item 14's stated convention, kept as-is, including the two asymmetric defaults and their rationale: downloads are content-addressed-ish upstream tarballs and git mirrors — near-zero cross-project poisoning risk, high dedup value — so shared-by-default is right; sstate is hash-keyed but bulkier and occasionally worth isolating (and mixing raises the cache-management questions in §9), so opt-in groups. `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` already travels with the sstate volume, so a shared sstate group shares its hash-equivalence DB coherently, and the one-VM rule serializes SQLite access — no new mechanism. New name knobs get the same no-spaces validation as `MACKAS_VOLUME_NAME` (the unquoted `--runtime-args` word-split constraint). All naming derives from the **selector**, never from `MACKAS_PROJECT_DIR` — restating it because it is the entire backward-compat proof: `oe-build-*` is frozen for the unpinned path forever.

**"Not concurrently" enforcement.** There is no new mechanism, and that is the point. Invariant 3 already states that a volume may be mounted by exactly one running container — the enforcement gap is that `cmd_shell()`/`cmd_smoketest()`/`run_kas()` don't currently *check*. The fix (the plan's phase 0, correctly identified as a pre-existing bug rather than a feature of this design) is: before any command that would mount volumes, resolve the three volume names, check each against running containers, and refuse a held one — with a message that names the holder, and, by reverse-grepping the pinned configs for the volume name, which *project* holds it ("`mackas-shared-dl` is mounted by a running build of project meta-ai; wait for it or stop it"). Sharing makes collisions likelier but changes nothing about their handling: two projects sharing `mackas-shared-dl` serialize on it exactly as invariant 3 requires, and mackas refuses the second build rather than ever double-mounting. `ro` remains explicitly not an escape hatch. The check-then-start TOCTOU window between two racing invocations is acknowledged in §9.

**Destruction safety with shared volumes.** `mackas destroy` under a project selector destroys only that project's *private* volumes. A shared volume (`mackas-shared-dl`, `mackas-sstate-<g>`) is refused with the list of pinned projects referencing it (grep of the configs) and requires the explicit `mackas volume destroy <name>` form. Same rule for `clean` variants that touch dl/sstate.

**Migration from `oe-build-{tmp,dl,sstate}`** — three supported populations, matching the plan's §6:

- **(A) Do nothing.** Stays on `oe-build-*` indefinitely. Fully supported, not deprecated.
- **(B) Shared downloads only, no projects:** set `MACKAS_VOLUME_DL_NAME=mackas-shared-dl`, seed it with the landed `volume duplicate` from `oe-build-dl`, `destroy` the old one. Works with only the phase-1 knobs, before any project machinery exists.
- **(C) Become a pinned project:** `mackas project add <name> --from work/<checkout>` converts in place — and pin-time asks the one question that matters: keep `oe-build-*` (writes `MACKAS_VOLUME_NAME=oe-build` into the project conf; supported end state, no data moves) or migrate to `mackas-<name>-*` via `volume duplicate`. Nothing is ever renamed or moved silently; `confirm()` per the automate-fixes rule, `die()` only for what mackas can't decide.

Disk accounting: keep the plan's Decision E — `check`/`setup` sum the caps of every existing `mackas-*` volume machine-wide (ground truth over config) as an informational line, existing single-config check stays the pass/fail gate, shipped default caps never shrink.

## 6. Config model

**A per-project config is a complete, standalone config file — not an overlay, not a layer.** This is the plan's Decision A, kept in full, because it is the only shape that composes with invariant 4 without amendment:

- The selector (any tier of §4) decides **which single file** `load_config()` sources at its one existing source-point. Rung 2 of `defaults → config file → environment → --set` is occupied by exactly one file, same as today.
- `snapshot_env`/`restore_env` still make the environment beat that file; `apply_cli_overrides` still beats everything. Untouched code, untouched order — the invariant holds by construction, not by reasoning about interactions.
- `MACKAS_PROJECT_NAME` is deliberately **not** in `SETTING_NAMES`: it cannot be written by `mackas set` into a config file (a selector inside the selected file is circular), and it doesn't participate in snapshot/restore. It is selection metadata, not a setting.
- The derived file path goes through `config_file_is_safe()` (file and directory owned by user/root, not group/world-writable) precisely because the user didn't type it — preserving the existing, correct asymmetry where typed `--config` paths are requests and implicit paths are audited.
- `~/.config/mackas/projects/<name>.conf` is `adopt`'s existing output file, unchanged in location and written by the same `config_write_setting()` writer `mackas set` uses. `mackas project add` writes the same schema. `mackas --project <name> set FOO bar` (or `mackas set` from inside the workspace, via derivation) edits the project's file — and every `set` prints which file it wrote, so a derived selection can't silently edit an unexpected file.

The cost of standalone-not-overlay, stated plainly: a machine-wide preference (say a volume-size default) must be repeated per project file rather than inherited from the global config. That is the price of keeping invariant 4 at four rungs, and `project add` mitigates it by seeding new project configs from the current effective settings at pin time. If repetition proves painful in practice, revisiting layering is a future *invariant amendment* discussion, not something this design smuggles in.

## 7. Failure modes and safety

Beyond the derivation table in §4:

- **Wrong volumes attached because of a wrong guess.** Structurally prevented: derivation can only select pinned configs, matches on physical-path containment (no name fuzzing, no leaf-name string-matching), and fails closed on zero or multiple matches. The residual risk is a *stale correct* guess — user pinned a project long ago, forgot, and is surprised volumes differ from the legacy stem. Mitigation: the once-per-shell note ("project meta-qcom selected (derived from cwd): volumes mackas-meta-qcom-tmp / mackas-shared-dl / mackas-meta-qcom-sstate"), plus `mackas status`/`projects` always showing the resolution and its tier.
- **Pinning an existing checkout silently switches an active workflow's volumes.** Handled at pin time, the only place it can happen: `project add --from` explicitly asks keep-`oe-build` vs migrate (§5C). Derivation never changes volumes for an unpinned directory.
- **Concurrent builds racing onto a shared volume.** Held-volume refusal (phase 0) plus the one-VM rule covers the steady state; the check→start race window remains (§9). Single-user Mac makes this low-probability; a flock-style guard is a possible hardening, not a blocker.
- **`do_cleanall`/`do_cleansstate` against a shared cache** (the documented upstream footgun): with the one-VM rule there is no *concurrent* victim, but a clean can still delete artifacts other projects rely on. `mackas clean`'s sstate/dl-touching modes gain the same shared-volume refusal as `destroy` (§5), pointing at the explicit `volume`-level command.
- **sstate poisoning across projects in a shared group.** Bitbake sstate is keyed by task-input hash; the Yocto autobuilders share sstate across distros routinely, and target-recipe reuse is hash-safe. The real cross-host hazard, `NATIVELSBSTRING`, is neutralized here because every project builds in the same kas container image — same host distro string. Residual caveat: projects pinning *different kas container image versions* could fragment (not corrupt) the shared cache — wasted space, not wrong builds. Documented, not blocked.
- **Downloads poisoning.** `DL_DIR` entries are upstream artifacts keyed by name+checksum; a wrong or truncated tarball fails checksum verification at fetch time regardless of which project wrote it. Sharing dl is the safe default the whole ecosystem uses.
- **Selector file as attack surface.** Covered in §6: derived paths pass `config_file_is_safe()`; candidates are grepped, never sourced; only the winner is sourced. `MACKAS_PROJECT_NAME` validation must reject path separators and `..` outright (it is a filename component, nothing more) before it ever touches a path.
- **`work/.repo-ref` corruption or virtiofs misbehavior** (highest technical risk in the design): kas documents concurrent-safe reference-dir use on POSIX filesystems, but virtiofs is exactly where "POSIX enough" goes to die. Phase-gated on a live-Mac verification build; the fallback if it fails is simply per-project full clones — correct, just fatter, and the design works without it.
- **`mackas dump` and logs landing in a flat namespace** (item 13 retrofit): per-project `logs/<name>/` (Decision D) owns this; until that phase, flat logs are cosmetically messy, never unsafe.

## 8. Migration and phasing

Adapted from the plan's 9 phases; each independently shippable and revertible. The reordering versus the plan: pinning (`project add`) and derivation land as their own phases, with derivation *after* the selector and pinning exist to match against.

| Phase | What ships | Size / risk |
|---|---|---|
| 0 | **Held-volume refusal on every build path** (`shell`, `smoketest`, `run_kas`), with holder-project attribution in the message. A pre-existing invariant-3 gap; ships first, alone. | XS / low |
| 1 | `MACKAS_VOLUME_DL_NAME` / `MACKAS_VOLUME_SSTATE_NAME` knobs + no-spaces validation. Unlocks migration population B immediately. | S / low |
| 2 | `--project` / `$MACKAS_PROJECT_NAME` selector (config-file resolution, `config_file_is_safe`, mutual-exclusion rules) + read-only `mackas projects`. | M / medium (security surface) |
| 3 | `mackas project add` (pinning; workspace dir creation; pin-time volume/sharing choices; `--from` conversion with keep-stem option) + volume-name derivation from the selector + shared-dl default under a selector. The backward-compat-critical phase. | M / high |
| 4 | **`$PWD`/kas-yaml derivation tier** — grep-based candidate matching, physical paths, fail-closed rules, wrapper-subprocess coverage, once-per-shell note. | M / medium |
| 5 | Per-project `env-<name>.sh` (exporting the selector), `macos-<name>.yml`, `logs/<name>/` (absorbs the item-13 dump retrofit). | M / medium |
| 6 | Per-project `KAS_WORK_DIR=work/<name>/` + shared `KAS_REPO_REF_DIR=work/.repo-ref` — **gated on a live-Mac virtiofs verification build before shipping**. Until this phase, pinned projects still share the flat `work/` (with the phase-0 refusal and serialized builds limiting, but not eliminating, the repos_checkout hazard — the reason this phase matters). | L / highest |
| 7 | `mackas build <name|path> <chain> [--target]`, with the plan's Decision F ambiguity rule (`/` or leading `./`/`~` → path; else pinned name) and the positional made optional when tier-3 derivation resolves. | M / medium |
| 8 | `MACKAS_SSTATE_GROUP` + migration helper (`volume duplicate`-based) + shared-volume destroy/clean refusals. | S / low |
| 9 | Aggregate machine-wide disk accounting in `check`/`setup`. | S / low |

Note the ordering wart between 3 and 6: phases 3–5 give pinned projects distinct volumes and configs while still sharing flat `work/` until 6 lands. If the virtiofs verification for `.repo-ref` drags, an acceptable interim is shipping per-project `work/<name>/` in phase 6 *without* the ref dir (full clones), taking the disk hit for safety. Converting a `--from` legacy checkout before phase 6 leaves it physically in flat `work/`; the move into `work/<name>/` happens as a `confirm()`-offered step when phase 6 lands (kas re-clones the sibling layers into the workspace — cheap after `.repo-ref`, a re-download before it, which is why conversion-with-move waits).

## 9. Open questions and trade-offs

Genuine judgment calls, with the alternative stated rather than buried:

1. **`KAS_REPO_REF_DIR` over virtiofs is unverified.** The whole "per-project work without duplicating poky-sized clones" story rests on it. If it fails live testing, the fallback is full per-project clones — safe, ~2–5 GB extra per project. Decision needed only at phase 6, with data in hand.
2. **Selector variable naming.** `MACKAS_PROJECT_NAME` (plan's choice) collides conceptually with the existing derived `MACKAS_PROJECT`/`MACKAS_PROJECT_DIR`. Alternatives: rename the selector, or unify the derive function's output variable with the selector where a pin exists. Small, but user-visible forever once shipped — worth a deliberate call.
3. **Standalone configs vs. layering.** §6 accepts per-project repetition of machine-wide preferences to keep invariant 4 at four rungs. The alternative — a global-then-project two-file source order — is genuinely more convenient and genuinely a fifth rung. This design says no; if real usage produces config-drift pain across many projects, that is a future invariant discussion, not a quiet addition.
4. **sstate default: private (this design) vs. shared (bitbake-setup's `common-sstate=yes`).** Prior art leans shared; this design leans private because mackas's serialized one-VM world makes a shared sstate volume a *contention* point (builds queue on it), not just a cache. If groups see heavy adoption, flipping the default for new projects is a one-line policy change later. Reasonable people could start shared.
5. **TOCTOU on the held-volume check.** A lock file (`container-volumes/<vol>.lock` flock) would close the race between two invocations starting simultaneously. Cost: another state file that can go stale after a crash and needs `repair`-style handling. Deferred as hardening; the single-user reality makes the window mostly theoretical.
6. **Shared-cache garbage collection.** A long-lived `mackas-shared-dl`/`mackas-sstate-<g>` only grows; the qcom CI rotates sstate monthly. Whether mackas needs `volume prune`-style aging for shared volumes (and by what policy — atime is unreliable on ext4-in-image) is unresolved; the existing sstate-prune machinery is per-volume and may simply suffice when pointed at shared names.
7. **Disk budget.** ~680 GB worst case for four projects with private tmp/sstate + shared dl remains unmeasured (same status as TODO item 4). Phase 9's aggregate accounting produces the number; nothing in this design commits to a budget before then.
8. **Should `mackas set` follow derivation?** §6 says yes (selection decides the file; `set` prints the file). The conservative alternative — require an explicit `--project` for any write — trades a small surprise risk for extra friction on the most common tweak ("set this project's cap while standing in it"). This design picks derivation-with-echo; flagged because it is the one place a derived selection *writes* rather than reads.
---

## 10. Addendum: two-way sstate mirroring — the RO HTTP mirror and post-build retrieve-and-push

Owner requirement, added after §1–§9 were written: under multi-project support, "the 2-way sstate mirror thing becomes more important, as well as a way to have a RO sstate mirror (http) and a post-build retrieve-and-push method to update the mirror." Unpacked: "two-way" = the consume direction that already ships (`mackas-mirrord` serving the sstate tree over HTTP into builds — TODO item 35's territory) plus the publish direction that does not exist anywhere yet (TODO item 46 / GitHub issue #1). Grounded against `mackas-mirrord` (2734 lines, `CacheManager` at line 826), `fetch_tmp_subdir()` (mackas:6333–6537), `cmd_retrieve()` (6651–6844), `sstate_prune()`/`cmd_sstate()` (7104–7222), `setup_kas_fragment()` (4407–4421), and the push-side prior-art research (ccache/sccache, Bazel REAPI, actions/cache, GitLab CI, `sstate.bbclass` read from openembedded-core source, the upstream autobuilder's `PUBLISH_SSTATE`, and RidgeRun's rsync-to-mirror CI pattern).

### 10.1 Why this matters more under multi-project

§5's entire sharing story is *volume* sharing: same machine, same ext4 image, serialized by the one-VM rule, opt-in via `MACKAS_SSTATE_GROUP`. That model has a structural ceiling this design already named in §9 Q4: a shared sstate volume is a contention point — builds queue on it. An HTTP mirror is a second sharing plane with the opposite properties: read access is plain concurrent HTTP GETs, so N projects (or N machines) consume the same warm cache simultaneously with zero volume contention, no held-volume refusal, no queueing. The two planes compose: a project keeps its *private* `mackas-<name>-sstate` volume (fast local writes, no serialization against siblings) and still gets cross-project/cross-machine hits via `SSTATE_MIRRORS` pointing at the shared mirror.

**Effect on §9 Q4 (sstate private vs. shared default): the mirror strengthens private-by-default.** The main argument *for* shared-by-default was hit rate; the mirror delivers that hit rate without the contention cost that was the argument *against*. With a mirror in the picture, `MACKAS_SSTATE_GROUP` narrows to its genuinely best case — same-machine projects that want write-through sharing with no mirror round-trip — and stops being the only sharing mechanism. Q4's answer stays "private by default," now with a better recommendation attached: share via the mirror first, via groups only when the mirror round-trip measurably hurts.

**Effect on §9 Q6 (shared-cache GC): the push path changes prune's risk profile** (developed in §10.5) — and the mirror inherits the growth problem Q6 describes, which becomes a new open question (§11 Q12) rather than making Q6 harder.

### 10.2 The RO HTTP mirror: substantially shipped — do not rebuild it

Being plain about what exists, because the owner's phrasing ("a way to have a RO sstate mirror (http)") could read as a feature request: **this is shipped, hardened, and verified with a real build.** `mackas-mirrord` serves the sstate and downloads trees read-only over HTTP with path validation, credential store, rate limiting, and the `CacheManager` hot-object accelerator; `MACKAS_USE_HTTP_MIRRORS=1` + `MACKAS_HTTP_MIRROR_SSTATE`/`MACKAS_HTTP_MIRROR_DL` generate the `SSTATE_MIRRORS`/`own-mirrors` fragment (mackas:4407–4421); `mackas check` live-probes reachability (2542–2565); NFS-vs-HTTP ambiguity is a hard `die` (4399–4403). There is no HTTP write path, and §10.4 argues that absence is a feature to preserve, not a gap to fill.

What multi-project actually still needs on the read side is small:

- **Per-project mirror URLs cost nothing.** §6's standalone per-project configs already carry `MACKAS_HTTP_MIRROR_*` like any other setting, and `project add`'s seed-from-effective-settings behavior propagates the machine's mirror URLs into new project configs at pin time. No new mechanism.
- **`MACKAS_SSTATE_GROUP` does not imply a mirror URL.** A group names a *volume*; a mirror URL names a *network endpoint*, usually on another machine. Deriving one from the other would be exactly the kind of magic §4 refuses. They stay independent knobs.
- **Mirror tree layout: one flat shared tree by default** (e.g. `<mirror>/sstate/`, matching the upstream public mirror's `all/` convention), not per-project or per-group subtrees. Justification is §7's existing poisoning analysis, which transfers wholesale: sstate is task-input-hash keyed, `NATIVELSBSTRING` is uniform because every project builds in the same kas container image, and differing image versions fragment (waste space in) the cache rather than corrupt it. Hit rate is the point of the mirror; a flat tree maximizes it. A project that wants isolation points its `MACKAS_HTTP_MIRROR_SSTATE` (and push destination) at a subtree — a config choice, not a mechanism. Flagged in §11 Q9 since reasonable people could default to per-group subtrees.

### 10.3 The publish direction: `mackas sstate push`, built on the retrieve machinery

**Surface: a new `sstate` subcommand, not a sixth retrieve object.** `cmd_retrieve()`'s contract is "copy build *products* out of the tmp volume for the user to keep or inspect" — all five objects live in `MACKAS_VOL_TMP`, and the result belongs to the user. sstate lives in its own volume (`MACKAS_VOL_SSTATE`, mounted at `/sstate`) and the goal is publication, not inspection; bolting it onto `retrieve` would contort both contracts. Instead, `fetch_tmp_subdir()` generalizes to `fetch_volume_subdir(<volume>, ...)` — a parameter change, since nothing in its mechanism is tmp-specific — and `cmd_sstate()` gains a `push` subcommand beside `prune`. This is the owner's "retrieve-and-push" reading: reuse the machinery, don't expose the verb.

**This resolves item 46's first open question — push from a host-side copy, not from the volume directly.** Three reasons, in order: (1) the hardened copy-with-verification path (chunked `cksum` manifests, source/dest comparison, tar fallback on mismatch, hard `die` on double mismatch) exists only on the host-copy path, and it exists precisely because a real >18G artifact was once copied with the right size but wrong content — publishing to a shared mirror is the *last* place to skip that check; (2) push credentials (ssh keys) stay on the host — the throwaway container remains network-free and credential-free; (3) pushing from inside a container against the live volume would put a long network transfer inside the window where the volume is held, exactly what the one-VM rule exists to keep short and predictable.

**Flow of one push:**

1. Resolve the sstate volume from the selector (§4) — private or group volume, both legitimate sources. `volume_in_use` → refuse, same as `sstate_prune()`.
2. Throwaway container mounts the volume read-only plus a host staging dir; copies **only objects newer than the last-push stamp** (a host-side stamp file per volume+destination pair, compared via `find -newer`; sstate objects are written once and never modified, so mtime is trustworthy for *newness* here even though §10.5 rejects it for *aging*). Lost stamp = full re-scan; `--ignore-existing` at the transport layer makes that merely slow, never wrong — self-healing.
3. Run the manifest verification (`retrieve_verify_script()` in-container, `retrieve_verify_local()` on the host) over the staged copy; tar fallback and hard-fail semantics identical to retrieve. The volume is released here — the network transfer happens with nothing mounted.
4. Two-pass `rsync --ignore-existing` over ssh to the directory `mackas-mirrord` serves: pass 1 everything except `*.siginfo`, pass 2 the siginfo files (ordering rationale in §10.4).
5. Update the stamp only after rsync exits clean. Staging dir is then removable (or kept as an rsync `--link-dest` accelerator — implementation detail).

**Transport: rsync over ssh, and specifically not HTTP PUT.** The research puts the alternatives on a spectrum. At one end, ccache/sccache push naked PUTs per object with *no documented integrity story* — they get away with it only because hash-keyed consumers ignore bad entries. At the other, Bazel/REAPI and actions/cache run real two-phase protocols (FindMissingBlobs → upload → commit; reserve → chunked PATCH → commit) — the right properties, but they require a protocol-speaking server. rsync-to-the-served-directory gets the Bazel properties without the server: `--ignore-existing` is a filesystem-native FindMissingBlobs (never re-upload, never overwrite), and rsync's default temp-file-then-rename is per-object atomic visibility — the same same-directory-rename pattern `sstate.bbclass` itself uses (confirmed from `sstate_create_and_sign_package` source) and that bazel-remote implements server-side. Adding PUT to `mackas-mirrord` is rejected outright: the daemon's read-only-ness is a security property the owner explicitly wants ("a RO sstate mirror"), and turning the build-facing HTTP endpoint writable would trade it for a worse version of what ssh already provides. Write path authenticated out-of-band, read path anonymous and RO — that split *is* the design.

**Trigger: explicit first, auto opt-in later.** `mackas sstate push` ships as an explicit command. A later phase adds `MACKAS_SSTATE_PUSH_AUTO=1`: after a *successful* `run_kas`/wrapper build, run the push (backgrounded or foregrounded — §11 Q14 territory for the failed-build case). Gating on build success matches every CI precedent in the research (actions/cache `post-if: success()`, RidgeRun's pipeline-stage gating) — with the difference that mackas adds the staging verification those pipelines lack.

### 10.4 Integrity and safety

Each mechanism mapped to the failure it kills, grounded in what the research found actually goes wrong:

- **Corrupt bytes leaving the host** (the `cp -r` divergence class, observed live on this machine): the staged copy is manifest-verified before rsync starts. This is the exact gap in the RidgeRun pattern — "the build stage succeeded" says nothing about the bytes rsync then publishes — closed with machinery mackas already trusts.
- **Partial upload visible to a consumer**: rsync per-file temp-then-atomic-rename; a consumer's GET sees the old state (miss) or the whole file, never a torn one. Never `--inplace`.
- **Two machines pushing concurrently**: `--ignore-existing` makes published objects immutable — first committer wins, the actions/cache immutable-key rule. And by Bazel's content-addressing argument, two pushers racing on the same hash-derived path are pushing identical bytes anyway, so even the race that slips through the no-overwrite check is harmless. No locking needed, by construction.
- **Signature-before-payload window**: the research flagged that `sstate.bbclass` places the `.siginfo` before renaming the payload into place, with the safety of that ordering unverified. This design doesn't inherit the question — the two-pass rsync (payloads, then siginfo) guarantees a mirror consumer never sees a signature for an absent package, at the cost of one extra rsync invocation.
- **A bad-but-well-formed object polluting consumers**: hash-keyed consumption bounds the damage — a corrupt archive fails setscene unpack and bitbake falls back to the real task; a hash-mismatched object is simply never fetched. This is the same safety net ccache/sccache lean on entirely; here it is the *last* line, not the only one. §7's cross-project analysis (uniform `NATIVELSBSTRING` from the shared kas image; image-version skew fragments, never corrupts) applies to the mirror unchanged.
- **The mirror host itself**: writes arrive only via ssh-authenticated rsync from machines holding keys; the HTTP surface stays read-only with `mackas-mirrord`'s existing path validation. No new attack surface on the build-facing side.

### 10.5 Composition with §5, the one-VM rule, and `sstate prune`

**Yes, push needs the volume, and yes, it gets the full one-VM discipline.** Steps 1–3 of §10.3 mount the sstate volume in a throwaway container — same shape as `sstate_prune()` and `fetch_tmp_subdir()`, same `volume_in_use` refusal, same phase-0 held-volume message with project attribution. Push during a build is refused, which is correct twice over: mechanically (invariant 3) and semantically (only completed builds publish). The deliberate refinement: the volume is held only for stage+verify, not for the network transfer — a slow uplink never extends the window in which sibling projects are locked out of a shared group volume. A shared `mackas-sstate-<g>` is a first-class push source; pushers serialize on it like any other user of the volume.

**Prune ordering — taking the position item 46 left open: push first, prune second, and it is pushing that makes pruning safe, not pruning that makes pushing cheap.** The alternative (prune-then-push, to shrink the transfer) buys nothing — `--ignore-existing` plus stamp-based staging already keeps pushes incremental — and costs the mirror objects it would otherwise have archived. Push-then-prune inverts the risk profile of the whole aging problem: once objects are on the mirror, a locally pruned object downgrades from "forced rebuild" to "HTTP refetch," which also defuses the items-36/45 objection to `sstate_prune()`'s wall-clock `mtime +N` cutoff — against a pushed volume, an over-aggressive cutoff is a performance bug, not a correctness one, so the `MAX(last-touched)`-relative cutoff fix stops gating the push path. No code coupling initially (the commands compose in documented order); a later `sstate prune --pushed-only`, consulting the push stamp, is the natural hardening if unpushed-object loss ever bites in practice.

**Phasing**: three rows appended to §8's table, all after phase 1 (they need nothing from the project machinery, only the volume-name knobs, and work identically for unpinned `oe-build-sstate`): **P-a** `fetch_volume_subdir` generalization + `mackas sstate push` with stamp, verify, two-pass rsync (M / medium — the new surface); **P-b** `MACKAS_SSTATE_PUSH_AUTO` post-build hook (S / low); **P-c** the same push for downloads (S / low, §11 Q13). That independence is worth stating: retrieve-and-push is severable from multi-project and could ship first — multi-project is what makes it *important*, not what makes it *possible*.

## 11. Addendum open questions

Continuing §9's numbering and style:

9. **Flat shared mirror tree vs. per-group subtrees as the default.** §10.2 picks flat for hit rate, leaning on §7's hash-safety analysis. The counter-position: subtree-per-group mirrors the §5 private-by-default philosophy and keeps one project's image-version fragmentation out of another's listing. Cheap to change before anyone depends on the layout; expensive after.
10. **Cross-machine hash equivalence.** `BB_HASHSERVE_DB_DIR = "${SSTATE_DIR}"` travels with the volume, so same-machine consumers share equivalence state — but a mirror consumer on another machine has its own DB and will miss OEEquivHash-mediated hits the pusher's machine would get. The upstream public mirror pairs `SSTATE_MIRRORS` with `BB_HASHSERVE_UPSTREAM`; whether the mirror host should also run `bitbake-hashserv` (and whether kas-in-container can reach it cleanly over vmnet NAT) is unverified and could materially cap the cross-machine hit rate.
11. **Staging disk cost.** Stage-then-verify-then-push doubles the transient footprint of new objects on the host. A verified streaming path (`tar | ssh`, checksums computed in-stream) would eliminate it but forfeits the compare-two-manifests-then-retry structure that caught the real corruption. Measure first push sizes in practice before optimizing; the design accepts the staging cost.
12. **Mirror-side GC.** The mirror only grows — Q6 relocated to another host, where `sstate_prune()`'s throwaway-container shape doesn't reach. Options: a prune mode in `mackas-mirrord` (whose item-35 sqlite/last-access work would provide exactly the usage data flat mtime lacks), a cron'd find on the mirror host, or explicitly out of scope. Unresolved; note the item-35 overlap so the two designs land coherently.
13. **Downloads push.** Item 46 covers dl too; the machinery is identical and dl objects are even safer (name+checksum-keyed, §7). Deferred only for sequencing — nothing in §10 is sstate-specific except the siginfo two-pass.
14. **Push after a failed build.** Completed tasks' sstate objects are individually valid regardless of overall build outcome, so pushing them is hash-safe in principle and would warm the mirror faster for iterating teams. Every CI precedent gates on success anyway. Default gates on success; whether an explicit `sstate push` (no auto) should run against a failed build's volume without protest, or warn, is a small UX call left open.
15. **Stamp-file semantics with multiple destinations.** One stamp per volume+destination pair handles the obvious case; whether anyone will genuinely push one volume to two mirrors (and whether that deserves support or a "don't" in the docs) is unknown. Costless to defer — the stamp is keyed, not global.