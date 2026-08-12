# A native macOS app for the monitor bridge

Scoping notes for a **separate repository** — a menubar/notification app that
watches a mackas build. Nothing here is built yet. It lives in this repo because
the thing such an app codes against (the bridge's JSON, and how it behaves
around a real smoketest) is defined here, and because the two sharp edges below
are expensive to rediscover.

Why a separate repo: mackas is bash 3.2 plus stdlib-only Python, buildable
and reviewable with what is already on a Mac. A Swift app drags in Xcode, a
signing identity and a release cadence that has nothing to do with the CLI's.
The bridge is a stable HTTP contract precisely so the two can be versioned
apart.

## What already exists, before you write anything

- **The bridge** — `mackas-uibridge/mackasjson.py`, a bitbake UI module that
  runs *inside* the build container and re-serves live progress as JSON. See
  [architecture.md](architecture.md#live-build-progress-the-monitor-bridge)
  for how it gets there without patching bitbake.
- **The poller** — `tools/mackas-monitor` (`mackas monitor`). A progress line
  starts with `[status] done/total  recipe:task` and appends percent, elapsed
  wall time and, while `building`, a failed-so-far count; that leading
  substring is fixed, and anything new goes *after* it, so a consumer
  grepping for it keeps matching. One `watching: <targets> for
  <machine>/<distro>` header precedes them, and on a real terminal the line
  is redrawn in place rather than scrolled — a 90-minute build at the default
  poll interval would otherwise emit thousands of near-identical lines.
  Elapsed time is measured by the poller itself, not derived from the
  payload, which carries no start timestamp. With `--notify` /
  `MACKAS_MONITOR_NOTIFY=1` it also posts native notifications on exactly
  three transitions: build started, build succeeded, build failed. It prefers
  `terminal-notifier` when that is on `PATH` and otherwise uses `osascript`.
  Its notification bodies encode deliberate choices and are worth copying:

  ```
  mackas: build started     console-image for beaglebone/Angstrom
  mackas: build succeeded   console-image for beaglebone/Angstrom · 6253/6253 tasks
  mackas: build failed      linux-yocto_6.6.bb:do_compile · beaglebone/Angstrom
  ```

  Note what is **not** there. "Started" does not name a task, because at the
  `building` edge none is running yet. "Failed" names the task that actually
  failed — from `failed_tasks` — not `current`, which on a parallel build is
  merely whatever happened to be running when everything stopped, and which
  therefore accuses an innocent recipe. Every part is omitted rather than
  padded when the bridge does not know it.

The notification half already covers the common case. An app that also
notifies should say so, and let the user run one or the other — two things
watching the same bridge means two notifications per event.

**The osascript permission gotcha, since an app author will hit the other side
of it:** `osascript` notifications from a terminal are *silently dropped* —
exit 0, no output, nothing on screen — until that terminal application has an
entry under System Settings > Notifications, which no CLI can create for
itself. A real `.app` bundle gets its own entry the first time it asks, and can
ask properly through `UNUserNotificationCenter`. That is one of the few honest
reasons to build the app at all.

## The JSON contract

This is the API. It is small on purpose.

| | |
|---|---|
| **Endpoint** | `GET http://127.0.0.1:<port>/` |
| **Port** | `MACKAS_MONITOR_PORT`, default **8801**, published `-p PORT:PORT` so the host port equals the container port |
| **Other paths** | `404`, empty body |
| **`HEAD`** | `405`, empty body |
| **Every other method** (`POST`, `PUT`, …) | `501` with `BaseHTTPRequestHandler`'s own HTML error body — only `do_GET`/`do_HEAD` exist, so the stdlib default answers |
| **Response** | `Content-Type: application/json`, `Content-Length` always set, never chunked |
| **Auth / TLS / CORS** | none, none, none |

Absence of CORS headers is deliberate: a browser page from another origin
cannot read this. A native app has no such restriction, which is the point of
this document.

```json
{
  "status": "building",
  "targets": ["core-image-base", "console-base-image"],
  "machine": "beaglebone",
  "distro": "angstrom",
  "current": {"recipe": "busybox_1.36.0.bb", "task": "do_compile"},
  "progress": {"done": 412, "total": 3170},
  "failed_tasks": [{"recipe": "linux-yocto_6.6.bb", "task": "do_compile"}],
  "failed_count": 1,
  "recent_events": [{"ts": 1769000000.123, "type": "runQueueTaskStarted",
                     "recipe": "busybox_1.36.0.bb", "task": "do_compile"}]
}
```

| Field | Type | Meaning, and what it is allowed to do |
|---|---|---|
| `status` | string | One of **`idle`**, **`building`**, **`success`**, **`failed`**. Starts `idle`; becomes `building` on the first `ParseStarted`/`*TaskStarted`; becomes `success`/`failed` from bitbake's own exit code once `knotty.main()` returns, or `failed` if it raised. Within one container's life it only ever moves forward, and never leaves `success`/`failed`. Once it reaches a terminal value the bridge keeps serving it for a little while rather than shutting down immediately — see ["the end-of-build race"](#the-end-of-build-race-which-watch-mode-makes-impossible-to-ignore) below. |
| `targets` | array of string | What the build was asked to produce, from bitbake's own parsed command line (`params.options.pkgs_to_build`). Populated **before the build starts**, so it is the one useful thing to show at the `building` edge, when no task is running yet. Empty when bitbake was given no explicit target (it then builds whatever the kas config names) — treat empty as "unknown", not as "nothing". |
| `machine` | string \| null | `MACHINE`, read from the cooker via `server.runCommand(["getVariable", …])` on the **first event-loop call after `bb.ui.knotty.main()` has started** — deliberately not at UI startup, since a pre-knotty round-trip was traced to a real build-killing crash (see [architecture.md](architecture.md#live-build-progress-the-monitor-bridge)). `null` until that first call; it lands at essentially the same instant `status` first becomes `"building"`, so a `"building"` payload with `machine: null` is possible only for a sub-millisecond window, never for a whole poll interval. On a **multiconfig** build this is only the default `MACHINE`; per-multiconfig builds legitimately have several, so treat it as a label rather than a complete description of what was built. |
| `distro` | string \| null | `DISTRO`, same source, same timing, same caveats. |
| `current.recipe` | string \| null | The **basename of the task's recipe file**, e.g. `busybox_1.36.0.bb` — not a `PN`. `null` until a task has started, and left at the last known value afterwards. Every runQueue event carries `taskfile` — completion, failure and skip included — so this is the recipe of the most recent task *event*, not necessarily one that is still running. |
| `current.task` | string \| null | bitbake's task name, e.g. `do_compile`. Same staleness rule. |
| `progress.done` | int | **Phase-dependent.** During parsing it is parsed-recipe count; during the run queue it is `stats.completed`. |
| `progress.total` | int | Same phase split. **It jumps**: the parse total is replaced by the task total, and setscene and the main run queue report their own totals. Do not assume it is monotonic, and never assume `done <= total` across a phase change. |
| `failed_tasks` | array | Tasks that **genuinely failed**, newest last, each `{recipe, task}` with the same recipe-basename convention as `current`. **Setscene failures are deliberately excluded**: a failed setscene task is not a build failure, it only means the sstate object could not be reused and the real task runs instead — bitbake's own knotty treats `runQueueTaskFailed` as fatal and `sceneQueueTaskFailed` as a warning. Listing the latter would name innocent recipes. Capped at 20. |
| `failed_count` | int | The **true** number of distinct failed tasks, which may exceed `len(failed_tasks)` when the cap bites (`bitbake -k` keeps going after a failure). Show this, not the array length, when reporting a total. |
| `recent_events` | array | Newest last, **capped at 50**. Each entry has `ts` (float, Unix seconds, on the *container's* clock) and `type` (the bitbake event name), plus whatever that event carried — `recipe`, `task`. `done`/`total` are deliberately not repeated per event. |

Event `type` values currently produced: `ParseStarted`, `ParseProgress`,
`runQueueTaskStarted`, `sceneQueueTaskStarted`, `runQueueTaskCompleted`,
`sceneQueueTaskCompleted`, `runQueueTaskFailed`, `sceneQueueTaskFailed`,
`runQueueTaskSkipped`.

Rules for a consumer, in rough order of how much pain they save:

- **`recent_events` is not an event log.** It is a 50-deep ring you sample. A
  busy build overruns 50 entries in well under a second of wall time, so any
  poll interval you can actually use will miss events. Drive your UI from
  `status`/`current`/`progress`; use `recent_events` for a "what happened
  lately" panel, never for counting or for reconstructing history.
- **Treat every field as optional.** The bridge's event observer is
  best-effort by design — it swallows any surprise from a bitbake event schema
  rather than take the real build down with it — so a field can be missing,
  `null`, or stale. Fields may also be *added* later; ignore ones you do not
  know instead of failing to parse.
- **There is no build identity in the payload.** No build id, no `BUILDNAME`,
  no start timestamp. If you need to tell one build from the next you must
  infer it (an `idle`→`building` edge, or a `progress` reset), or propose
  adding a field to the bridge rather than guessing in the app.

## Enabling the bridge, and why it is opt-in

```sh
mackas --set MACKAS_MONITOR=1 smoketest &
mackas monitor            # or your app, polling 127.0.0.1:8801
```

This works identically for a hand-typed build in a sourced shell — the
`kas-container` wrapper recomputes `--runtime-args` live per call (see
architecture.md's "Running `kas-container` by hand"), so exporting
`MACKAS_MONITOR=1` before a `kas-container build <files>` publishes the
same bridge, not just through `smoketest`/`shell`:

```sh
export MACKAS_MONITOR=1
kas-container build meta-ai/kas/base.yml &
mackas monitor
```

Off by default (`MACKAS_MONITOR=0`), and it should stay that way. It mounts two
files over the checkout's own `bin/bitbake`, makes bitbake load a mackas module
as its UI, runs a background HTTP thread inside the build, and publishes an
unauthenticated port. Each of those is defensible on its own — together they
are not something to impose on a build that did not ask. See
[security.md](security.md): do not enable it where the published port is
reachable by anything you do not trust.

It is also **best-effort**: `monitor_runtime_args()` adds nothing when the work
directory does not exist yet, when there is no bitbake checkout yet, or when a
path involved contains a space (which would corrupt the whitespace-split
`--runtime-args` string). So `MACKAS_MONITOR=1` does not guarantee a listening
port, and an app must render a port that never appears as "not connected",
never as "the build failed". Every one of those skips warns on stderr, and a
build that really does carry the bridge prints one `live progress bridge:
publishing 127.0.0.1:<port>` line, so the human who opted in learns at build
start which of the two happened — but that is the terminal's story, and an app
watching the port sees neither line.

## The rough edge that will define your app's design

**The bridge does not survive across smoketest rungs.** Tracked in [GitHub
issue #45](https://github.com/koenkooi/mackas/issues/45); it is the single
most important thing to know here.

`mackas smoketest` climbs a ladder — a parse rung, then one build rung per
target — and **each rung is a separate `kas-container` invocation**, so each
rung is a separate container, a separate bitbake, and a separate bridge
process. Between rungs there is nothing listening on the port at all. Then a
new bridge appears, with completely fresh state: `status` back to `idle`,
`progress` back to `0/0`, `failed_tasks` and `recent_events` empty. (`targets` is repopulated immediately, since it comes from the new invocation's own command line.)

What follows for a long-running app:

- **Connection refused is a normal steady state**, not an error to surface. It
  means "between rungs, or no build running". Show it as idle; log it at most
  once.
- **Connection *reset* is a different, also-normal state.** Something holds the
  port — the container is up and Apple `container` is publishing it — but the
  bridge inside is not answering yet, typically because the rung has not
  reached bitbake. It resolves on its own within seconds. Distinguish it from
  refused, as `tools/mackas-monitor` does, rather than reporting one errno for
  both; "starting up" and "nothing there" want different words in a UI.
- **Reconnect forever**, with a small backoff (a second or so — this is
  loopback, there is nothing to be gentle to). Never exit on `ECONNREFUSED`,
  never require the user to restart the app to pick up the next rung.
- **A `success` is one rung's success, not the build's.** A green ladder is
  several `success` states separated by outages. A `failed` *does* end the run
  — smoketest stops on the first failing rung — so `failed` is the one terminal
  state you can trust.
- **State resets are not progress going backwards on the same build**; they are
  a new build. Reset your own derived state (elapsed time, peak counts) on the
  `idle`/reset edge rather than smoothing over it.
- **Do not copy `tools/mackas-monitor` here.** The CLI poller deliberately
  exits (status 2) with a connection error on the first failed fetch, because
  a foreground command that hangs forever on a dead port is worse than one
  that says so. An app has the opposite obligation. (The CLI is likely to
  grow an opt-in watch mode — see below — but exiting stays its default, so
  the rules above, not the CLI's control flow, are what an app should
  follow.)

### The same gap, from the CLI side: multi-build batches

**It is not only smoketest.** The same shape turns up with no smoketest in
sight: a hand-typed batch of N machines, one `kas-container build <machine
files>` per machine, run in sequence with `MACKAS_MONITOR=1` exported. Per
"Enabling the bridge" above, the `kas-container` wrapper recomputes
`--runtime-args` live per call, so *every one* of those invocations publishes
its own bridge on the same port — N separate containers, N separate bridges,
gaps in between. Structurally identical to the rungs; only the thing driving
the sequence differs (a human's shell history instead of `cmd_smoketest`).

What that user wants is one `mackas monitor --notify` running all evening,
announcing start and outcome per machine. What they get is one machine's
worth: `tools/mackas-monitor`'s loop returns the first time `fetch()`
raises, and it also returns as soon as it sees a terminal `status`, so the
process is gone before machine 2's container is up. The workaround that gets
reached for instead is polling each machine's build *log* for a completion
marker — i.e. abandoning the bridge entirely. Two independent users driven
off the bridge by the same one-line behaviour is enough to fix it in the CLI,
not only in a future app.

**Recommended direction: reconnect-and-wait, ended by the human.** As an
opt-in flag (`--watch`, working name), not a change of default. Exiting on a
dead port is right for the common `mackas monitor` typed when a build should
already be running, and the exit status is a usable probe — 0 success, 1 the
build itself failed, 2 no bridge reachable at all — which a script may lean
on. Whatever watch mode does, it must not collapse those three back into one.

Deliberately *not* a "watch N builds" count. A hand-typed batch changes shape
mid-evening; a count one too high hangs, one too low exits early, and nothing
in the bridge lets the tool check which happened. There is no end-of-batch
signal at this layer, and inventing one means coordinating a shell loop that
mackas does not own. Ctrl-C *is* the end-of-batch signal, and for a
human-driven CLI that is the honest answer rather than a missing feature. An
`--idle-timeout` for the unattended case is a fine optional extra; it should
default to off.

Three things it needs, all in `tools/mackas-monitor`:

1. **A failed fetch is a state, not an exit.** Print "waiting for a build" at
   most once per outage, back off about a second, keep polling.
2. **Reset `prev_status` to `None` on every disconnect.** Without this the
   next build is silently un-announced. `transition_message()` only fires on
   a *change*, and its started clause is `status == "building" and
   prev_status in (None, "idle")`. A bridge only begins serving once
   bitbake's UI is up, so the first successful poll of build N+1 is very
   often already `building`; against a stale `prev_status` of `building` that
   is not a change, and nothing notifies. `None` is already the "attached
   mid-build, announce what you found" sentinel, so re-arming reuses existing
   semantics rather than adding any.
3. **Do not exit on `success`/`failed` in watch mode** — notify, then go back
   to waiting.

**The end-of-build race, which watch mode makes impossible to ignore.**
Without a linger, `mackasjson.main()` would call `_finish()` and then, in its
`finally`, shut the server down immediately, with bitbake exiting right
behind it — serving the terminal `status` only for the residual
`serve_forever()` poll window, half a second at the outside. Against the
default 2 s `MACKAS_MONITOR_POLL_INTERVAL` a poller would usually never
observe `success`/`failed` at all: it would see `building`, then the port
would be gone. Today that would cost at most one "build succeeded"
notification; across a batch, one per machine — the entire point of the
feature.

The bridge mitigates this: after `_finish()` sets the terminal status,
`main()`'s `finally` waits for that status to actually reach a client
(`do_GET` signals an event once it has written a terminal-status body), or
for `TERMINAL_LINGER_SECONDS` (5.0) to elapse, whichever comes first, before
shutting the server down. 5 seconds covers two full default 2 s poll windows
(`MACKAS_MONITOR_POLL_INTERVAL` in `tools/mackas-monitor`) plus slack for one
timed-out fetch retry at that tool's own 2.0 s `REQUEST_TIMEOUT`. It is
deliberately not configurable via an env var: nobody has asked for one, and a
wrong value would silently re-break notifications. `KeyboardInterrupt`/
`SystemExit` — a human hitting Ctrl-C, or an explicit exit — skip the linger
entirely and shut down immediately, so Ctrl-C still gets an instant prompt
back.

This is a mitigation, not a full close of the gap: a poll interval raised
well above the default, a poller that first attaches after the linger
window, or the process dying without ever reaching that `finally` (SIGKILL,
`mackas destroy`, OOM) all still miss the terminal status. So "disconnected
while `building`" still means **outcome unknown**: say nothing, never report
it as a failure — that rule stays mandatory regardless of the linger.

**Per-build identity is already good enough here; do not grow a `--label` for
it.** The payload carries no build id (above), but the notification bodies do
not need one: `machine`, `distro` and `targets` come from each new
invocation's own bridge, so consecutive machines already read as "… for
beaglebone/Angstrom" then "… for qemuriscv64/Angstrom", and consecutive
smoketest rungs differ by `targets`. A `--label` echoed into the title is a
three-line change if a batch ever wants its own name, but it is a
*per-process* constant: it can name the batch, never the build within it, so
it does not belong in the reconnect work. Correlating builds across
reconnects into a *history* — the app's problem, not the CLI's — still wants
a real identity field, and that is a bridge change to propose rather than a
heuristic to infer.

## Consider SwiftBar first

If a menubar summary is all you want, an app is the wrong amount of work.
[SwiftBar](https://github.com/swiftbar/SwiftBar) runs plugins in the xbar
plugin format and is the maintained one — xbar itself has gone quiet. A plugin
is just an executable file, and the entire protocol is stdout:

- the **first line** is the menu bar text;
- a line of `---` starts the dropdown; lines after it are menu items;
- a trailing `| key=value` adds styling or behaviour (`color=`, `sfimage=`,
  `font=`, `href=`, `bash=`/`terminal=false` to run something on click);
- the **refresh interval is encoded in the filename**: `mackas.5s.sh` reruns
  every 5 seconds (`s`/`m`/`h`/`d`).

So the whole thing is: fetch the JSON, print a summary line, print a few detail
lines. Near-zero logic, no signing, no release process, and the
disappearing-endpoint problem collapses to "print `mackas: idle` when curl
fails". [GitHub issue #44](https://github.com/koenkooi/mackas/issues/44)
suggests shipping it from this repo as `menubar/mackas.plugin.sh` — small
enough to belong here, unlike the app.

Build the real app only when you need what a plugin cannot do: notifications
with actions, history across rungs, several builds at once, or a UI that is
alive between refreshes.

## What the app must not do

Non-negotiables, consistent with [security.md](security.md):

- **No telemetry, no phone-home, no crash reporting to a third party.** mackas
  makes no network calls of its own; an app that watches it must not be the
  exception that does.
- **Connect to `127.0.0.1` only.** Never bind a port, never advertise over
  Bonjour/mDNS, never offer to watch another machine's build. The bridge binds
  `0.0.0.0` *inside the container* only because that loopback is the
  container's, not the Mac's — it is not an invitation to go over the LAN.
- **Read-only.** `GET /` is the entire API. There are no write endpoints and
  none should be invented — especially not ones that would shell into a running
  build.
- **No credentials, nothing in the Keychain.** There is nothing to
  authenticate; if a future version needs auth, that belongs in the bridge, not
  in an app-side secret.
- **Never invoke `container` directly.** Everything mackas does through the
  Apple `container` runtime goes through mackas so the one-VM-per-volume rule
  holds; an ext4 volume mounted by two VMs at once corrupts. If the app needs
  to *act*, it shells out to `mackas <subcommand>`, or it does nothing.

Two practical notes: a sandboxed app needs
`com.apple.security.network.client` even to reach `127.0.0.1`; and keeping the
app GPL-3.0-or-later, like mackas, avoids an awkward conversation later even
though a separate repo talking pure HTTP is free to choose otherwise.
