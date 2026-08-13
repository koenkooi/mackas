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

**Before building against this bridge at all, check whether you actually
need it.** If the only thing your consumer wants is "tell me when this build
finished" — a script, a CI-style caller, a Claude Code workflow — the
build's own exit code is a more reliable signal than anything the bridge can
give: it covers kas-level failures the bridge never sees, and (for
`smoketest`) it isn't fooled by the parse-only first rung reaching `success`
before any real build starts. `mackas monitor --help`'s "A DONE-SIGNAL
WITHOUT POLLING" section spells out the pattern. The bridge earns its keep
for genuine *progress* — a menubar app, a live percentage, a human watching
— which is what the rest of this document is actually scoped to.

## What already exists, before you write anything

- **The bridge** — `mackas-uibridge/mackasjson.py`, a bitbake UI module that
  runs *inside* the build container and re-serves live progress as JSON. See
  [architecture.md](architecture.md#live-build-progress-the-monitor-bridge)
  for how it gets there without patching bitbake.
- **The poller** — `tools/mackas-monitor` (`mackas monitor`). A progress line
  starts with `[status] done/total  recipe:task` and appends percent, elapsed
  wall time, progress from inside whichever tasks are reporting any, and,
  while `building`, a failed-so-far count; that leading substring is fixed,
  and anything new goes *after* it, so a consumer
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

**The published port can reset instead of answering, and an app will hit that
too.** Apple `container`'s `-p` forward sometimes completes the TCP handshake
on the published port and then resets the request rather than proxying it:
`nc -z 127.0.0.1 8801` succeeds while an HTTP `GET` through the same port gets
`ECONNRESET`. The bridge is not the problem — inside the container it is
correctly bound on `0.0.0.0:<port>`, and that same `GET` to the container's own
IP returns the full, correct payload every time. `tools/mackas-monitor` routes
around it, and the recipe is worth copying: on a reset, and only a reset —
never a refusal, never a timeout — it asks the runtime where the container
actually is. `container ls` gives the running IDs, `container inspect` each
one, and the build being watched is the first whose
`configuration.publishedPorts[]` names the polled port as its `hostPort`.
Matching on the published port rather than on the image picks out the right
container even with others running. What it then polls is that entry's
`containerPort` at `status.networks[].ipv4Address` with the prefix length
stripped (inspect reports CIDR, `192.168.64.76/24`) — going direct bypasses the
forward, so the host→container port mapping has to be undone.

Three properties of that fallback are not optional. The address cannot be
resolved ahead of time or cached: every build run is a new container on a new
IP off the runtime's own subnet, so it is resolved live, on the first reset,
and never on the working path — a poll that answers should not spawn a
subprocess. The runtime is asked at most once per outage, so a bridge that
resets on both addresses gives up instead of looping. And every way the query
can come up empty — no `container` on `PATH`, a daemon that is down, an ID that
exits mid-walk, an inspect payload in a shape you do not recognise — reads as
"no answer available" rather than as an error of its own, because the fallback
is the connection message you would have shown anyway.

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
| **Endpoint** | `GET http://127.0.0.1:<port>/`, or the container's own address when the forward resets that port ([above](#what-already-exists-before-you-write-anything)) |
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
  "task_progress": [{"recipe": "systemd_257.bb", "task": "do_compile",
                     "percent": 42, "rate": null}],
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
| `task_progress` | array | Progress **inside** the tasks that are running *right now* and report any, each `{recipe, task, percent, rate}` with the same recipe-basename convention as `current`. Empty is the normal case, not an error: most tasks report nothing (see ["what actually reports"](#what-actually-reports-sub-task-progress) below), and an entry disappears the moment its task ends, so a stale percentage can never outlive the recipe it described. `percent` is an int 0–100, or `null` for bitbake's own "progress is happening but we cannot say how much" — draw an indeterminate bar for that, never a zero. `rate` is an extra display string when the producer has one (`"1.2M/s"` from the download fetchers) and `null` otherwise. Bounded by `BB_NUMBER_THREADS` in practice and hard-capped at 32. |
| `recent_events` | array | Newest last, **capped at 50**. Each entry has `ts` (float, Unix seconds, on the *container's* clock) and `type` (the bitbake event name), plus whatever that event carried — `recipe`, `task`. `done`/`total` are deliberately not repeated per event. |

Event `type` values currently produced: `ParseStarted`, `ParseProgress`,
`runQueueTaskStarted`, `sceneQueueTaskStarted`, `runQueueTaskCompleted`,
`sceneQueueTaskCompleted`, `runQueueTaskFailed`, `sceneQueueTaskFailed`,
`runQueueTaskSkipped`.

The events behind `task_progress` are deliberately **not** among them.
`bb.build.TaskProgress` fires roughly once per percentage point per
instrumented task, which would flush that 50-deep ring several times a second
and destroy the one thing it is for; `bb.build.TaskStarted`/`TaskSucceeded`/
`TaskFailed`/`TaskFailedSilent` are consumed only to attribute those
percentages to a task, and would otherwise duplicate the `runQueue` events
already listed, at twice the volume. So `task_progress` is the whole of what
the bridge exposes from them.

Rules for a consumer, in rough order of how much pain they save:

- **`recent_events` is not an event log.** It is a 50-deep ring you sample. A
  busy build overruns 50 entries in well under a second of wall time, so any
  poll interval you can actually use will miss events. Drive your UI from
  `status`/`current`/`progress`; use `recent_events` for a "what happened
  lately" panel, never for counting or for reconstructing history.
- **`progress.done`/`total` are task-level, so on a healthy build they can sit
  still for a very long time.** They count bitbake *tasks*, and a task is
  indivisible to them: a recipe with one large `do_compile` holds the counter
  at the same number for tens of minutes while only the cheap tasks around it
  (`do_fetch`, `do_rm_work`, …) move it along. That reads as a stuck build and
  is not one. `task_progress` covers some of that gap and `current.recipe`/
  `current.task` plus elapsed time cover the rest: with all three, a long
  single task reads as "still on `linux-yocto:do_compile`, 42%" or at worst
  "still on `linux-yocto:do_compile`, 14 minutes" rather than as "frozen".
  Never fold `task_progress` back into `progress` — one task at 42% has still
  completed zero tasks, and a counter that moves in fractions would make the
  totals meaningless.
- **Treat every field as optional.** The bridge's event observer is
  best-effort by design — it swallows any surprise from a bitbake event schema
  rather than take the real build down with it — so a field can be missing,
  `null`, or stale. Fields may also be *added* later; ignore ones you do not
  know instead of failing to parse.
- **There is no build identity in the payload.** No build id, no `BUILDNAME`,
  no start timestamp. If you need to tell one build from the next you must
  infer it (an `idle`→`building` edge, or a `progress` reset), or propose
  adding a field to the bridge rather than guessing in the app.

### What actually reports sub-task progress

`task_progress` is thin on purpose: it relays what bitbake already publishes,
and nothing more. Knowing which tasks that covers is what keeps an empty array
from looking like a bug.

bitbake's progress framework is `bb/progress.py`. A task opts in with a
`progress` varflag on its shell function — `bb/build.py`'s `exec_func_shell`
hands it to `create_progress_handler`, which wraps the task's own stdout in a
handler that scrapes it: `percent` for a bare `NN%`, `outof:REGEX` for an
N-of-M pair, or `custom:CLASS` for a handler supplied by the metadata.
Python-side code can construct a handler directly instead. Every one of them
fires `bb.build.TaskProgress`, which is the same event bitbake's own `knotty`
terminal UI draws its inline progress bars from — so this needs **no patch to
bitbake and none to OE-core**, and the bridge sees it purely by tee'ing the
handler `knotty.main()` already drives.

What opts in today:

- **ninja-generated compiles**, which is the common case. `cmake.bbclass` sets
  `do_compile[progress] = "outof:^\[(\d+)/(\d+)\]\s+"` for its default `Ninja`
  generator (and `"percent"` when told to use `Unix Makefiles` instead);
  `meson.bbclass` sets the same ninja regex. So most of a modern image's
  expensive compiles report.
- **`cargo`/`cargo_c`/`waf`** `do_compile`, and `libc-package.bbclass`'s
  `oe_runmake`, each with their own regex.
- **`do_rootfs`**, via `image.bbclass`'s `MultiStageProgressReporter` — the
  single longest opaque task in an image build.
- **downloads**, from bitbake's own fetchers rather than from any bbclass:
  `git` (which is also where `percent: null` comes from — it reports
  indeterminate progress while counting objects), `wget`, `s3` and `perforce`
  each construct a handler directly, so `do_fetch` reports, and `wget`/`git`/
  `s3` are the ones that fill in `rate`.

What does **not**, and will not without a change to OE-core that mackas does
not carry: plain `autotools`/`make` `do_compile`, which is a large minority of
recipes and has no `progress` varflag at all, and every task nobody has
instrumented (`do_configure`, `do_install`, `do_package`, …). A build can
therefore be perfectly healthy with `task_progress` empty for minutes.

One thing the event cannot give you, however the task was instrumented: the
underlying **N of M**. `OutOfProgressHandler` divides the pair out to a
percentage before firing, and `TaskProgress` carries only that number plus an
optional `rate` string. So `systemd:do_compile 42%` is available and
`systemd:do_compile 762/1814` is not, without patching bitbake.

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
- **Connection *reset* is a different, also-normal state**, and it has two
  causes. Something holds the port — the container is up and Apple `container`
  is publishing it — but either the bridge inside is not answering yet,
  typically because the rung has not reached bitbake, or the forward is
  resetting a bridge that is up and would answer on the container's own
  address. The first clears on its own within seconds; the second clears only
  by going direct, per ["the published port can reset instead of
  answering"](#what-already-exists-before-you-write-anything) above. Either
  way, distinguish reset from refused, as `tools/mackas-monitor` does, rather
  than reporting one errno for both; "starting up" and "nothing there" want
  different words in a UI.
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
- **Connect to this Mac only** — the published `127.0.0.1` port, or, when that
  port resets, the address the runtime itself reports for the container
  publishing it. Never bind a port, never advertise over Bonjour/mDNS, never
  offer to watch another machine's build. The bridge binds `0.0.0.0` *inside
  the container* only because that loopback is the container's, not the Mac's —
  it is not an invitation to go over the LAN.
- **Read-only.** `GET /` is the entire API. There are no write endpoints and
  none should be invented — especially not ones that would shell into a running
  build.
- **No credentials, nothing in the Keychain.** There is nothing to
  authenticate; if a future version needs auth, that belongs in the bridge, not
  in an app-side secret.
- **Never make the `container` runtime *do* anything.** Everything that acts on
  it goes through mackas so the one-VM-per-volume rule holds; an ext4 volume
  mounted by two VMs at once corrupts. If the app needs to *act*, it shells out
  to `mackas <subcommand>`, or it does nothing. The single exception is the
  read-only `container ls` / `container inspect` lookup above, used to find the
  address of the container publishing the polled port: it starts nothing,
  mounts nothing and changes nothing, which is why `tools/mackas-monitor` is
  allowed to run it too.

Two practical notes: a sandboxed app needs
`com.apple.security.network.client` even to reach `127.0.0.1`; and keeping the
app GPL-3.0-or-later, like mackas, avoids an awkward conversation later even
though a separate repo talking pure HTTP is free to choose otherwise.
