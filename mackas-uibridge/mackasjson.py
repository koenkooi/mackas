#
# mackas-uibridge/mackasjson.py — a bitbake UI module (bb.ui.mackasjson) that
# serves live build progress as JSON over HTTP, for macOS to poll.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS AND WHY IT IS SHAPED THIS WAY
#
# See TODO.md item 22 in the mackas repo for the full history. Short version:
# a build running inside the container is invisible to macOS beyond mackas's
# own coarse rung/log reporting. Two earlier designs both bootstrapped a
# separate bitbake server and attached a SECOND, --observe-only client to
# it -- both failed for structural reasons (a "Cooker is busy" registration
# race, and an unavoidable AttributeError in OE-core's base bbclass event
# handling that observe-only clients cannot work around, confirmed by
# reading bb/command.py's readonly-command allowlist: an observer is
# server-side REFUSED from ever calling updateConfig, so no client-side
# workaround exists).
#
# This module is not an observer. It is the FIRST and ONLY UI client --
# bitbake believes it is just running its normal default UI (knotty), same
# as always. It gets there via bb.main.create_bitbake_parser()'s "-u"
# defaulting from the BITBAKE_UI environment variable, and bb.ui being a
# plain, runtime-appendable package (bb/ui/__init__.py does nothing special)
# -- see mackas-uibridge/bitbake, the wrapper that arranges both of those
# before calling bb.main.bitbake_main(). Because this is a real client, not
# an observer, params.updateToServer() runs normally, so the base bbclass
# event handling that crashed the observer design gets everything it
# expects, and the "Cooker is busy" registration race cannot occur since
# this client is present from the very start of the build, not attaching
# to one already running.
#
# main() below does NOT reimplement bitbake's terminal UI. It wraps
# eventHandler in a thin tee proxy -- every event is inspected here (to
# update the JSON state this module serves) and then handed through
# UNCHANGED to the real bb.ui.knotty.main(), which does everything else:
# terminal output, exit codes, control flow. The interactive experience via
# 'kas-container shell'/'mackas smoketest' is therefore unchanged; this
# module is a pure side-channel tap, not a UI replacement.
#
# The same crash resurfaced once more, via a second path: _set_machine()
# used to be called from main() directly, before bb.ui.knotty.main() ever
# ran -- i.e. before knotty's own params.updateToServer() call had handed
# the cooker its real environment. That getVariable round-trip forced the
# same premature, empty-environment config parse the observer design hit,
# reaching a real build as a base.bbclass AttributeError. The standing
# invariant this module now maintains is: no server round-trip before
# bb.ui.knotty.main() has run. _set_machine() is therefore only ever called
# from inside _TeeEventHandler.waitEvent(), on its first invocation.
#
# ---------------------------------------------------------------------------
# WHY NOT SimpleHTTPRequestHandler
#
# Same reasoning as mirror-server/mackas-mirrord: its own docs say it is
# "not recommended for production use". This server only ever emits ONE
# generated JSON document (never reads an arbitrary path off disk), but it
# is still built on bare BaseHTTPRequestHandler so every response is code in
# this file, not inherited behaviour to audit.
#
# Binds 0.0.0.0 (not 127.0.0.1 -- that is the CONTAINER's own loopback, not
# the Mac's) on MACKAS_MONITOR_PORT (env, matching the -p publish mackas'
# own kas_runtime_args() adds when MACKAS_MONITOR=1); reachable from macOS
# on whatever host port that -p mapping published to. No auth, no TLS: this
# is a read-only, same-machine, single-build status feed, published only
# for the duration of one container run.
# ---------------------------------------------------------------------------

"""bb.ui module: serve live build progress as JSON over HTTP."""

import json
import os
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bb.event
import bb.ui.knotty

PORT = int(os.environ.get("MACKAS_MONITOR_PORT", "8801"))
MAX_RECENT_EVENTS = 50

# A -k build can fail a lot of tasks; keep the list bounded but report the
# true total alongside it, so a consumer showing "3 of 47" is never lying by
# omission.
MAX_FAILED_TASKS = 20

# One entry per RUNNING task, so both maps below are naturally bounded by
# BB_NUMBER_THREADS. The cap exists only so a TaskStarted whose matching
# TaskSucceeded/TaskFailed never arrives (a worker killed outright) cannot
# grow them without limit; it evicts oldest-first, which is exactly the
# stale entry in that case.
MAX_TASK_PROGRESS = 32

_lock = threading.Lock()

# See item 31's fix in main()/do_GET() below: after _finish() sets a terminal
# status, the server lingers for a bit rather than shutting down immediately,
# so a poller actually has a chance to observe "success"/"failed" instead of
# only ever seeing "building" followed by the port disappearing.
TERMINAL_STATUSES = ("success", "failed")
# Covers two full default 2-second poll windows (MACKAS_MONITOR_POLL_INTERVAL
# in tools/mackas-monitor) plus slack for one timed-out fetch retry (that
# tool's own REQUEST_TIMEOUT is 2.0). Deliberately NOT configurable via an
# env var: nobody has asked for one, and a wrong value would silently
# re-break notifications -- don't add one even if it looks like a natural
# knob.
TERMINAL_LINGER_SECONDS = 5.0
_terminal_fetched = threading.Event()

_state = {
    "status": "idle",
    # What this build was asked to produce, and what for. "targets" is known
    # before any event arrives (see _set_targets, pure client-side, no server
    # round-trip); "machine"/"distro" arrive later, with the first waitEvent
    # call (see _set_machine/_TeeEventHandler.waitEvent) -- they need a
    # getVariable round-trip to the cooker, which is only safe to issue once
    # bb.ui.knotty.main() has handed the real environment to the server.
    "targets": [],
    "machine": None,
    "distro": None,
    "current": {"recipe": None, "task": None},
    "progress": {"done": 0, "total": 0},
    # How much of this build sstate could cover -- see _observe_sstate. null
    # until the scene queue has settled, never a half-built tally.
    "sstate": None,
    # Only genuine task failures, never setscene ones -- see _observe.
    "failed_tasks": [],
    "failed_count": 0,
    # Progress INSIDE a still-running task, for the tasks that report any --
    # see _observe_task_progress and _publish_task_progress.
    "task_progress": [],
    "recent_events": [],
    # Bumped each time the HTTP server thread itself dies and gets restarted
    # (see _serve_forever_resilient) -- normally 0 for the whole build. A
    # nonzero value here is the one place a consumer can tell the bridge went
    # dark and came back, distinct from an ordinary transient poll failure.
    "bridge_restarts": 0,
}

# ---------------------------------------------------------------------------
# Sub-task progress
#
# bitbake has a real progress framework, bb/progress.py, and its events reach
# every UI client -- no patch to bitbake or OE-core is involved in any of
# this. A task opts in with a `progress` varflag on its shell function
# (bb/build.py exec_func_shell -> create_progress_handler), which wraps the
# task's own stdout in a handler that scrapes it: "percent" for a bare NN%,
# "outof:REGEX" for an N-of-M pair, or a custom handler class. Python-side
# code can instantiate a handler directly instead, which is what bitbake's
# own git/wget/s3/perforce fetchers do, so do_fetch reports download progress
# too. Every one of those fires bb.build.TaskProgress, the same event
# knotty's own inline progress bars are drawn from.
#
# TaskProgress deliberately does NOT inherit from TaskBase, so it carries no
# recipe or task of its own -- bb/build.py's own comment says "The event PID
# can be used to determine which task it came from". So attribution is a
# pidmap keyed off TaskStarted, exactly as bitbake's bb/ui/uihelper.py builds
# one for knotty. That helper is created inside knotty's main() and is not
# reachable from here, hence a second, equivalent map rather than a peek at
# knotty's.
#
# knotty's own event mask (bb/ui/knotty.py's _evt_list) already requests
# bb.build.TaskStarted/TaskSucceeded/TaskFailed/TaskFailedSilent and
# bb.build.TaskProgress, and this module's tee sits in front of the handler
# knotty drives -- so these arrive here with no extra registration, and would
# keep arriving even if the mask were narrowed, since knotty needs them for
# its own progress bars.
#
# Note what this is NOT recorded as: a TaskProgress entry never lands in
# recent_events. A single instrumented compile fires one per percentage
# point, which would flush that 50-deep ring several times a second and
# destroy the one thing it is for. TaskStarted/TaskSucceeded/TaskFailed are
# kept out for the same reason -- they duplicate the runQueue events already
# recorded there, at twice the volume.
# ---------------------------------------------------------------------------

# pid -> (recipe, task, started), from TaskStarted; dropped when the task
# ends. `started` is time.time() at the event, which is what makes a task's
# own age reportable -- an observation, never an estimate of what is left.
_task_pids = {}
# pid -> {"percent": int|None, "rate": str|None}, from TaskProgress. Only
# tasks that have actually reported anything appear here, so a build whose
# recipes are all plain make-based keeps this empty rather than listing every
# running task with nothing to say about it.
_task_reports = {}


def _evict_oldest(mapping, cap):
    """Drop oldest-first until MAPPING is under CAP. Caller holds _lock.

    dicts preserve insertion order (3.7+, which is this module's floor), so
    the first key is the longest-tracked pid -- the one a missed end-of-task
    event would have leaked."""
    while len(mapping) >= cap:
        del mapping[next(iter(mapping))]


def _publish_task_progress():
    """Rebuild the served list from the two maps. Caller holds _lock.

    Rebuilt wholesale rather than patched incrementally so the served value
    can never outlive the tasks it describes: an entry is present exactly
    while its pid is both running and reporting. Also re-run on every GET, so
    `elapsed` is measured against the clock at serve time rather than frozen
    at whenever the task last had a percentage to report."""
    now = time.time()
    out = []
    for pid, report in _task_reports.items():
        recipe, task, started = _task_pids.get(pid, (None, None, None))
        out.append({
            "recipe": recipe,
            "task": task,
            "percent": report["percent"],
            "rate": report["rate"],
            # Wall seconds since this task started. Unlike a build-wide ETA
            # this cannot be wrong -- it is an observation -- and it is the
            # only scale a null percent has.
            "elapsed": None if started is None else max(0, int(now - started)),
        })
    _state["task_progress"] = out


def _track_task(pid, recipe, task):
    if not pid or pid <= 0:
        return
    with _lock:
        if pid not in _task_pids:
            _evict_oldest(_task_pids, MAX_TASK_PROGRESS)
        # Unconditional, so a reused pid starts its clock over rather than
        # inheriting the age of whatever task held it before.
        _task_pids[pid] = (recipe, task, time.time())


def _untrack_task(pid):
    if not pid or pid <= 0:
        return
    with _lock:
        _task_pids.pop(pid, None)
        if _task_reports.pop(pid, None) is not None:
            _publish_task_progress()


def _observe_task_progress(pid, progress, rate):
    """Record one TaskProgress against the task that fired it.

    Ignored for a pid no TaskStarted has claimed -- bitbake's own uihelper
    does the same (`if event.pid > 0 and event.pid in self.pidmap`), because
    an unattributed percentage names nothing and pids get reused.

    bitbake's own scale is 0-100, or NEGATIVE for "progress is happening but
    we cannot say how much" (bb/build.py TaskProgress's docstring); git's
    fetcher fires exactly that while counting objects. That becomes a null
    percent here rather than a made-up number -- the entry's presence is
    what says the task is alive."""
    try:
        value = float(progress)
    except (TypeError, ValueError):
        return
    with _lock:
        if pid not in _task_pids:
            return
        if pid not in _task_reports:
            _evict_oldest(_task_reports, MAX_TASK_PROGRESS)
        _task_reports[pid] = {
            "percent": None if value < 0 else max(0, min(100, int(value))),
            # An extra display string when the producer has one (wget/git/s3
            # report a transfer rate); most do not.
            "rate": str(rate) if rate else None,
        }
        _publish_task_progress()


def _set_targets(params):
    """Record what the build was asked to build, from bitbake's own parsed
    command line.

    Not from a BuildStarted event: knotty's event mask is matched on the
    EXACT class name (bb/event.py's UIEventFilter.filter does
    `str(event.__class__)[8:-2] not in self.eventmask`), and its list carries
    "bb.event.BuildBase", not "bb.event.BuildStarted" -- so BuildStarted is
    never delivered to a UI at all, and knotty itself never handles one.
    params.options.pkgs_to_build (bb/cookerdata.py:31) is the real source,
    and it has the advantage of being known before the build starts."""
    try:
        pkgs = getattr(getattr(params, "options", None), "pkgs_to_build", None)
        if pkgs:
            with _lock:
                _state["targets"] = [str(p) for p in pkgs]
    except Exception:
        pass


def _set_machine(server):
    """Ask the cooker what MACHINE and DISTRO this build is for.

    MUST be called only from inside knotty's event loop -- i.e. from
    _TeeEventHandler.waitEvent(), never before bb.ui.knotty.main() has run.
    A pre-knotty call was traced to a real crash: knotty.main() calls
    params.updateToServer(server, os.environ.copy()) near its own top,
    before its event loop starts, and that is what hands the real
    environment to the cooker. A getVariable round-trip issued before that
    forces the cooker to parse its base configuration prematurely, against
    an empty environment (self.configuration.env == {}), which leaves
    BB_ORIGENV with no PATH entry; OE-core's base.bbclass
    setup_hosttools_dir() then does origbbenv.getVar("PATH") -> None ->
    path.split(":") and raises AttributeError. That crash reaches the
    client as a logged ERROR event, turning an otherwise-successful build
    into one bitbake reports as failed via a non-zero exit code.

    Both are plain strings here. On a MULTICONFIG build MACHINE is only the
    default one, and per-multiconfig builds legitimately have several; a
    consumer should treat this as a label, not as a complete description of
    what was built."""
    for key, var in (("machine", "MACHINE"), ("distro", "DISTRO")):
        try:
            value, error = server.runCommand(["getVariable", var])
            if not error and value:
                with _lock:
                    _state[key] = str(value)
        except Exception:
            # Best-effort context, never a reason to fail a build.
            pass


# JSON key -> RunQueueStats attribute (bb/runqueue.py). All four or none:
# a partially-populated tally would read as a real, terrible sstate hit rate.
SSTATE_FIELDS = (
    ("covered", "setscene_covered"),
    ("notcovered", "setscene_notcovered"),
    ("total", "setscene_total"),
    ("skipped", "skipped"),
)


def _observe_sstate(stats):
    """Record how much of this build sstate covered, from a runQueue event.

    Only runQueue ones: bb/runqueue.py sets sqdone before it ever asks the
    scheduler for a real task, so these counts have settled by the first one,
    whereas a sceneQueue event still carries a tally being built up. It keeps
    updating rather than latching, since hash equivalence can reopen the
    scene queue mid-build.

    `covered`/`notcovered`/`total` are setscene tasks -- unambiguously sstate.
    `skipped` is real tasks that did not have to run, which is mostly sstate
    but also counts already-current stamps, hence served alongside rather
    than as the sstate number."""
    values = {}
    for key, attr in SSTATE_FIELDS:
        value = getattr(stats, attr, None)
        # bool is an int subclass; nothing here is ever a flag.
        if not isinstance(value, int) or isinstance(value, bool):
            return
        values[key] = value
    with _lock:
        _state["sstate"] = values


def _record(event_type, **fields):
    """Update the shared state under lock. Called only from the event tee,
    a single thread, but the HTTP handler thread reads concurrently."""
    with _lock:
        if event_type in ("ParseStarted", "TaskStarted", "sceneQueueTaskStarted",
                          "runQueueTaskStarted"):
            _state["status"] = "building"
        if "recipe" in fields or "task" in fields:
            _state["current"] = {
                "recipe": fields.get("recipe", _state["current"]["recipe"]),
                "task": fields.get("task", _state["current"]["task"]),
            }
        if "done" in fields or "total" in fields:
            _state["progress"] = {
                "done": fields.get("done", _state["progress"]["done"]),
                "total": fields.get("total", _state["progress"]["total"]),
            }
        # A REAL task failure -- runQueueTaskFailed only. Deliberately not
        # sceneQueueTaskFailed: a failed setscene task is not a build failure,
        # it just means the sstate object could not be reused and the real
        # task runs instead. knotty draws exactly the same line (bb/ui/
        # knotty.py: runQueueTaskFailed sets return_value = 1 and logs an
        # error; sceneQueueTaskFailed only logs a warning), and listing the
        # latter would name innocent tasks in a "build failed" notification.
        if event_type == "runQueueTaskFailed":
            failed = {"recipe": fields.get("recipe"), "task": fields.get("task")}
            if failed not in _state["failed_tasks"]:
                _state["failed_count"] += 1
                if len(_state["failed_tasks"]) < MAX_FAILED_TASKS:
                    _state["failed_tasks"].append(failed)

        entry = {"ts": time.time(), "type": event_type}
        entry.update({k: v for k, v in fields.items() if k not in ("done", "total")})
        _state["recent_events"].append(entry)
        del _state["recent_events"][:-MAX_RECENT_EVENTS]


def _finish(status):
    with _lock:
        _state["status"] = status
        # Nothing is running once the build has ended, so nothing may still
        # claim to be mid-task. Normally every task's own end event has
        # already cleared this; a build that died with workers still up (or
        # one whose last events never arrived) would otherwise serve a
        # frozen percentage next to a terminal status for the whole linger
        # window -- see TERMINAL_LINGER_SECONDS.
        _task_pids.clear()
        _task_reports.clear()
        _state["task_progress"] = []


def _observe(event):
    """Extract whatever this event has to offer; never raise -- a malformed
    or unexpected event must never take the real build down with it."""
    try:
        name = bb.event.getName(event)
        if name in ("ParseStarted",):
            _record(name, total=getattr(event, "total", 0))
        elif name in ("ParseProgress",):
            _record(name, done=getattr(event, "current", 0), total=getattr(event, "total", 0))
        elif name in ("runQueueTaskStarted", "sceneQueueTaskStarted"):
            stats = getattr(event, "stats", None)
            fields = {
                "recipe": os.path.basename(getattr(event, "taskfile", "") or "") or None,
                "task": getattr(event, "taskname", None),
            }
            if stats is not None:
                fields["done"] = stats.completed
                fields["total"] = stats.total
                if name.startswith("runQueue"):
                    _observe_sstate(stats)
            _record(name, **fields)
        elif name == "TaskStarted":
            # bb.build.TaskStarted, not the runQueue one: this is the event
            # fired in the worker, and its pid is what TaskProgress will be
            # keyed by. TaskBase carries taskfile/taskname, so the recipe
            # basename convention is the same one `current` uses.
            _track_task(
                getattr(event, "pid", 0),
                os.path.basename(getattr(event, "taskfile", "") or "") or None,
                getattr(event, "taskname", None),
            )
        elif name in ("TaskSucceeded", "TaskFailed", "TaskFailedSilent"):
            _untrack_task(getattr(event, "pid", 0))
        elif name == "TaskProgress":
            _observe_task_progress(getattr(event, "pid", 0),
                                   getattr(event, "progress", None),
                                   getattr(event, "rate", None))
        elif name in ("runQueueTaskCompleted", "sceneQueueTaskCompleted",
                      "runQueueTaskFailed", "sceneQueueTaskFailed",
                      "runQueueTaskSkipped"):
            stats = getattr(event, "stats", None)
            # recipe as well as task: a failure list saying only "do_compile"
            # names nothing useful, and every runQueue event carries taskfile
            # (bb/runqueue.py runQueueEvent.__init__).
            fields = {
                "recipe": os.path.basename(getattr(event, "taskfile", "") or "") or None,
                "task": getattr(event, "taskname", None),
            }
            if stats is not None:
                fields["done"] = stats.completed
                fields["total"] = stats.total
                if name.startswith("runQueue"):
                    _observe_sstate(stats)
            _record(name, **fields)
    except Exception:
        # Best-effort observation only -- never let a schema surprise here
        # propagate into the real build's own event loop.
        pass


class _TeeEventHandler:
    """Wraps the real eventHandler bb.ui.knotty.main() drives. Every method
    it doesn't override is delegated via __getattr__, so knotty sees the
    exact same interface it always does -- only waitEvent() is intercepted,
    to observe each event on its way through, unchanged, to knotty.

    Also the sole place _set_machine() is called from: the first waitEvent()
    call is only ever reached after knotty.main() has already run
    params.updateToServer(), so firing it here (rather than at UI startup)
    is what keeps that getVariable round-trip from racing the cooker's own
    config parse. See _set_machine()'s docstring for the crash this avoids."""

    def __init__(self, real, server):
        self._real = real
        self._server = server
        self._machine_fetched = False

    def waitEvent(self, delay):
        if not self._machine_fetched:
            self._machine_fetched = True
            _set_machine(self._server)
        event = self._real.waitEvent(delay)
        if event is not None:
            _observe(event)
        return event

    def __getattr__(self, name):
        return getattr(self._real, name)


class _Handler(BaseHTTPRequestHandler):
    server_version = "mackasjson/1.0"

    def log_message(self, fmt, *args):
        pass  # bitbake's own console is the log; stay quiet on stdout/stderr.

    def do_GET(self):
        # A poller that gives up mid-response (mackas-monitor's own
        # REQUEST_TIMEOUT is 2.0s) closes its end while this is still
        # writing, which raises BrokenPipeError/ConnectionError here --
        # expected, not a bug, and nothing can be done once it happens
        # (the peer is already gone). Catching it here keeps it from
        # reaching socketserver's own handle_error path, which prints a
        # traceback for every occurrence and is where an unrelated
        # earlier fd/socket-exhaustion incident was first noticed.
        try:
            self._do_GET()
        except (BrokenPipeError, ConnectionError, OSError) as exc:
            print("mackasjson: client disconnected mid-response (%r)" % (exc,),
                  file=sys.stderr)

    def _do_GET(self):
        if self.path != "/":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with _lock:
            status = _state["status"]
            # Re-age the running tasks against the clock now, not whenever
            # they last reported: TaskProgress can go quiet for minutes (a
            # "busy" fetch counting objects), and a frozen age is exactly the
            # reading this field exists to disprove.
            _publish_task_progress()
            body = json.dumps(_state).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        # Only signal once the terminal state has actually reached a client
        # -- i.e. after the write above returns -- and only for the real
        # JSON body path, never for "building" or an error response.
        if status in TERMINAL_STATUSES:
            _terminal_fetched.set()

    def do_HEAD(self):
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()


class _FastBindHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer, minus the reverse-DNS lookup its server_bind()
    does unconditionally. HTTPServer.server_bind() calls
    socket.getfqdn(host) to set self.server_name -- nothing here ever reads
    server_name (clients connect straight to 127.0.0.1:PORT), so that call
    is pure cost. Usually a few ms, but getfqdn("0.0.0.0") triggers a real
    reverse-DNS/NSS lookup whose latency depends entirely on the host's
    network config -- measured 5+ seconds on a CI runner with unusual DNS,
    against ~10ms on a normal Mac. Skip it: use the bind address itself."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def _serve_forever_resilient(httpd):
    """serve_forever() returning at all -- other than via main()'s own
    httpd.shutdown() at build end -- means the listening socket has gone
    dark for whatever ran it, with nothing left to ever answer a poll again
    for the rest of the build. A single request's own failure can't cause
    that (socketserver already isolates it -- see do_GET's own comment for
    the one path this module additionally guards), but nothing rules out
    every other cause (fd exhaustion, a stdlib edge case), so treat any
    unexpected return as a crash and keep the bridge alive on the same port
    rather than trust that it can't happen."""
    while True:
        try:
            httpd.serve_forever()
            return  # only reached via shutdown() -- a real, intended stop
        except Exception as exc:
            with _lock:
                _state["bridge_restarts"] += 1
            print("mackasjson: bridge server thread crashed (%r), restarting"
                  % (exc,), file=sys.stderr)


def main(server, eventHandler, params):
    _set_targets(params)
    httpd = _FastBindHTTPServer(("0.0.0.0", PORT), _Handler)
    thread = threading.Thread(target=_serve_forever_resilient, args=(httpd,),
                               daemon=True)
    thread.start()
    linger = True
    try:
        rc = bb.ui.knotty.main(server, _TeeEventHandler(eventHandler, server), params)
        _finish("failed" if rc else "success")
        return rc
    except (KeyboardInterrupt, SystemExit):
        # A human hitting Ctrl-C (or an explicit exit) wants their prompt
        # back immediately -- don't make them wait out the linger window.
        linger = False
        _finish("failed")
        raise
    except BaseException:
        _finish("failed")
        raise
    finally:
        if linger:
            # Mitigation, not a guarantee: a poll interval raised well above
            # the default, a poller that first attaches after this window,
            # or the process dying without reaching this finally at all
            # (SIGKILL, `mackas destroy`) will still miss the terminal
            # status. The poller-side rule -- "disconnected while building"
            # means outcome unknown, never report it as a failure -- must
            # stay documented regardless (a separate docs task covers that).
            _terminal_fetched.wait(TERMINAL_LINGER_SECONDS)
        # shutdown() alone stops serve_forever()'s loop but leaves the
        # listening socket open -- confirmed live: without server_close()
        # too, bitbake's own exit logged a ResourceWarning for it.
        httpd.shutdown()
        httpd.server_close()
