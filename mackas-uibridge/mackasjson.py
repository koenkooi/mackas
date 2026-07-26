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

_lock = threading.Lock()
_state = {
    "status": "idle",
    # What this build was asked to produce, and what for. Both known before
    # any event arrives (see _set_targets/_set_machine), so they are the one
    # useful thing a "build started" notification can say -- at that moment
    # no task is running yet.
    "targets": [],
    "machine": None,
    "distro": None,
    "current": {"recipe": None, "task": None},
    "progress": {"done": 0, "total": 0},
    # Only genuine task failures, never setscene ones -- see _observe.
    "failed_tasks": [],
    "failed_count": 0,
    "recent_events": [],
}


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

    server.runCommand(["getVariable", ...]) is knotty's OWN way of reading
    configuration (bb/ui/knotty.py reads BBINCLUDELOGS, BB_CONSOLELOG and
    friends exactly like this), and this runs from the same place -- once, at
    UI startup, before the event loop -- so it is not a new mechanism and it
    does not race a busy cooker the way registering a second observer does.

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
            _record(name, **fields)
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
            _record(name, **fields)
    except Exception:
        # Best-effort observation only -- never let a schema surprise here
        # propagate into the real build's own event loop.
        pass


class _TeeEventHandler:
    """Wraps the real eventHandler bb.ui.knotty.main() drives. Every method
    it doesn't override is delegated via __getattr__, so knotty sees the
    exact same interface it always does -- only waitEvent() is intercepted,
    to observe each event on its way through, unchanged, to knotty."""

    def __init__(self, real):
        self._real = real

    def waitEvent(self, delay):
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
        if self.path != "/":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with _lock:
            body = json.dumps(_state).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main(server, eventHandler, params):
    _set_targets(params)
    _set_machine(server)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), _Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        rc = bb.ui.knotty.main(server, _TeeEventHandler(eventHandler), params)
        _finish("failed" if rc else "success")
        return rc
    except BaseException:
        _finish("failed")
        raise
    finally:
        # shutdown() alone stops serve_forever()'s loop but leaves the
        # listening socket open -- confirmed live: without server_close()
        # too, bitbake's own exit logged a ResourceWarning for it.
        httpd.shutdown()
        httpd.server_close()
