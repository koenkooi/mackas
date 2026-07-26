# A native macOS app for the monitor bridge

Scoping notes for a **separate repository** — a menubar/notification app that
watches a mackas build. Nothing here is built yet. It lives in this repo because
the thing such an app codes against (the bridge's JSON, and how it behaves
around a real smoketest) is defined here, and because the two sharp edges below
are expensive to rediscover.

Why a separate repo: mackas is POSIX shell plus stdlib-only Python, buildable
and reviewable with what is already on a Mac. A Swift app drags in Xcode, a
signing identity and a release cadence that has nothing to do with the CLI's.
The bridge is a stable HTTP contract precisely so the two can be versioned
apart.

## What already exists, before you write anything

- **The bridge** — `mackas-uibridge/mackasjson.py`, a bitbake UI module that
  runs *inside* the build container and re-serves live progress as JSON. See
  [architecture.md](architecture.md#live-build-progress-the-monitor-bridge)
  for how it gets there without patching bitbake.
- **The poller** — `tools/mackas-monitor` (`mackas monitor`), which prints
  `[status] done/total  recipe:task` lines and, with `--notify` /
  `MACKAS_MONITOR_NOTIFY=1`, posts native notifications on exactly three
  transitions: build started, build succeeded, build failed. It prefers
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
| **`HEAD`, and every other method** | `405`, empty body |
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
| `status` | string | One of **`idle`**, **`building`**, **`success`**, **`failed`**. Starts `idle`; becomes `building` on the first `ParseStarted`/`*TaskStarted`; becomes `success`/`failed` from bitbake's own exit code once `knotty.main()` returns, or `failed` if it raised. Within one container's life it only ever moves forward, and never leaves `success`/`failed`. |
| `targets` | array of string | What the build was asked to produce, from bitbake's own parsed command line (`params.options.pkgs_to_build`). Populated **before the build starts**, so it is the one useful thing to show at the `building` edge, when no task is running yet. Empty when bitbake was given no explicit target (it then builds whatever the kas config names) — treat empty as "unknown", not as "nothing". |
| `machine` | string \| null | `MACHINE`, read from the cooker at UI startup via `server.runCommand(["getVariable", …])` — the same mechanism knotty uses for its own config. `null` if unset or unreadable. On a **multiconfig** build this is only the default `MACHINE`; per-multiconfig builds legitimately have several, so treat it as a label rather than a complete description of what was built. |
| `distro` | string \| null | `DISTRO`, same source and same caveats. |
| `current.recipe` | string \| null | The **basename of the task's recipe file**, e.g. `busybox_1.36.0.bb` — not a `PN`. `null` until a task has started, and left at the last known value afterwards (task-completion events carry no recipe, so this is the last *started* recipe, not necessarily the one that just finished). |
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

Off by default (`MACKAS_MONITOR=0`), and it should stay that way. It mounts two
files over the checkout's own `bin/bitbake`, makes bitbake load a mackas module
as its UI, runs a background HTTP thread inside the build, and publishes an
unauthenticated port. Each of those is defensible on its own — together they
are not something to impose on a build that did not ask. See
[security.md](security.md): do not enable it where the published port is
reachable by anything you do not trust.

It is also **best-effort**: `monitor_runtime_args()` silently adds nothing when
there is no checkout yet, or when a path involved contains a space (which would
corrupt the whitespace-split `--runtime-args` string). So `MACKAS_MONITOR=1`
does not guarantee a listening port. An app must render that as "not
connected", never as "the build failed".

## The rough edge that will define your app's design

**The bridge does not survive across smoketest rungs.** Recorded in TODO.md
item 22; it is the single most important thing to know here.

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
  exits with a connection error on the first failed fetch, because a
  foreground command that hangs forever on a dead port is worse than one that
  says so. An app has the opposite obligation.

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
fails". TODO.md item 22 suggests shipping it from this repo as
`menubar/mackas.plugin.sh` — small enough to belong here, unlike the app.

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
