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
# "not recommended for production use". This server only ever emits
# generated JSON documents of its own -- "/" and, since #146, "/recipes" --
# or, since #147, a bounded tail of a log file whose path the bridge
# ALREADY RECORDED ITSELF in `log_path` ("/log?tid=<tid>&lines=<n>"). It
# never reads an arbitrary path off disk: `/log` only ever opens a value
# already present in `_log_paths`, looked up by the `tid` query parameter --
# never `self.path`, never any other request-supplied string treated as a
# filesystem path. Still built on bare BaseHTTPRequestHandler so every
# response is code in this file, not inherited behaviour to audit.
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
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bb.event
import bb.ui.knotty

PORT = int(os.environ.get("MACKAS_MONITOR_PORT", "8801"))
# #142: empty for the unpinned oe-build-* setup, a real project name
# otherwise -- mackas always passes this flag (monitor_runtime_args()), so
# there is no "unset" case here to worry about, just possibly-empty.
PROJECT = os.environ.get("MACKAS_PROJECT", "")
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

# log_path/log_tail (#147). `_log_paths` holds one entry per RUNNING task
# (same lifetime as MAX_TASK_PROGRESS) PLUS one per entry in `failed_tasks`
# (same lifetime as MAX_FAILED_TASKS) -- see the "Log paths and tails"
# section below for why those two outlive _task_pids/_task_meta instead of
# sharing their eviction. Capped at the sum of both so a build with threads
# maxed out AND a full failed list still fits without evicting a live or
# still-interesting entry.
MAX_LOG_PATHS = MAX_TASK_PROGRESS + MAX_FAILED_TASKS
# Lines kept in the root payload's `log_tail`, captured once at TaskFailed
# time. Matches mackas-monitor-app's own BridgeState.maxLogTailLines, so
# nothing sent here is ever thrown away again at decode time.
MAX_LOG_TAIL_LINES = 200
# Bytes scanned from the END of a log file to build that captured tail.
# Large enough to comfortably hold 200 lines of ordinary bitbake task
# output; small enough to bound one disk read even against a multi-GB log
# (do_compile on a failing recipe can be enormous).
LOG_TAIL_CAPTURE_BYTES = 64 * 1024

# GET /log?tid=<tid>&lines=<n> (#147) is a single on-demand request, not
# something polled every second like `/`, so it can afford a larger budget
# than the inline failure-time capture above -- but it is still bounded, so
# one huge log cannot turn a single request into an unbounded response.
MAX_LOG_REQUEST_LINES = 1000
LOG_REQUEST_READ_BYTES = 256 * 1024

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
    # #142: which project this build is for, from the container's own
    # MACKAS_PROJECT env var (read once at import time -- unlike machine/
    # distro, this needs no cooker round-trip, so none of _set_machine()'s
    # first-waitEvent timing rules apply). Empty string, never omitted --
    # a consumer should not have to special-case "key absent" vs "no project".
    "project": PROJECT,
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
    # EVERY tracked task, reporting or not -- see _publish_task_progress.
    # "percent"/"rate" are present per-entry only when that task has reported
    # one, which is why this is rebuilt by hand rather than json.dumps'd
    # straight off a dict that always carries both keys.
    "running": [],
    # The true, uncapped number of running tasks -- distinct from len(running)
    # once MAX_TASK_PROGRESS caps the list itself. See _active_pids.
    "active": 0,
    # Per-recipe task history (#146) -- see the "Per-recipe task history"
    # section below for the full shape and the state vocabulary. Only ever
    # holds recipes that currently have a task in "running"; the complete
    # table (including everything already finished) is _recipe_tasks,
    # served separately via GET /recipes -- see _publish_recipes().
    "recipes": {},
    # Log file paths (#147), keyed by the full `tid` -- same shape as
    # `running[].tid` -- for every RUNNING task and for every entry
    # `failed_tasks` still remembers. Never built by hand from ${T}: taken
    # straight off TaskStarted/TaskFailed's own `logfile` attribute. See
    # the "Log paths and tails" section below for the full lifecycle.
    "log_path": {},
    # The last MAX_LOG_TAIL_LINES lines of a FAILED task's log, captured
    # once at TaskFailed time, keyed by the same `tid` as `log_path`. A
    # running task's live tail is NOT kept here -- poll GET /log?tid=...
    # for that instead, so a busy build is never forced to re-send every
    # running task's tail on every `/` poll.
    "log_tail": {},
    "recent_events": [],
    # Bumped each time the HTTP server thread itself dies and gets restarted
    # (see _serve_forever_resilient) -- normally 0 for the whole build. A
    # nonzero value here is the one place a consumer can tell the bridge went
    # dark and came back, distinct from an ordinary transient poll failure.
    "bridge_restarts": 0,
    # Four more fields join this dict dynamically, once known -- never
    # pre-populated with None here, so each is OMITTED from the served JSON
    # entirely (not served as `null`) until it actually has a value:
    #   "threads"/"buildname": from getVariable, in _set_machine(), same
    #     timing and multiconfig caveats as "machine"/"distro" above.
    #   "continue_on_failure": from bitbake's own already-parsed
    #     command-line options, in _set_continue_on_failure() -- no cooker
    #     round-trip, so no need to wait for the first waitEvent() either.
    #   "phase": one of "parsing"/"sstate"/"tasks", advanced forward-only in
    #     _advance_phase() off events the bridge already receives for other
    #     reasons -- no new event subscription.
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
# pid -> {"tid": str|None, "pn": str|None, "pv": str|None, "mc": str}, the
# extra TaskStarted attributes `running[]` needs that `_task_pids` does not
# carry (kept separate so `_task_pids`' own tuple shape -- read directly by
# existing callers -- never has to change). Evicted in lockstep with
# `_task_pids`, so a pid never appears in one without the other.
_task_meta = {}
# The SAME pids as `_task_pids`, but never evicted -- `_task_pids` is capped
# at MAX_TASK_PROGRESS so `running[]` cannot grow without bound, but `active`
# must stay the true count regardless, so a consumer can tell when `running`
# was truncated. A set rather than a counter: idempotent add/discard can
# never drift the way a hand-kept +1/-1 tally could.
_active_pids = set()
# tid -> log path, and tid -> captured tail lines (#147). Deliberately
# separate from _task_pids/_task_meta rather than riding along in them:
# those are pid-keyed and get wiped by _untrack_task the moment a task
# ends, but a FAILED task's log_path/log_tail must keep serving for as
# long as that failure stays in `failed_tasks` -- see _capture_failure_log
# and _untrack_task's own `keep_log` parameter below.
_log_paths = {}
_log_tails = {}


def _evict_oldest(mapping, cap):
    """Drop oldest-first until MAPPING is under CAP. Caller holds _lock.

    dicts preserve insertion order (3.7+, which is this module's floor), so
    the first key is the longest-tracked pid -- the one a missed end-of-task
    event would have leaked."""
    while len(mapping) >= cap:
        del mapping[next(iter(mapping))]


def _publish_task_progress():
    """Rebuild the served lists from the tracking maps. Caller holds _lock.

    Rebuilt wholesale rather than patched incrementally so the served value
    can never outlive the tasks it describes: a task_progress entry is
    present exactly while its pid is both running and reporting, and a
    running entry exactly while its pid is tracked at all. Also re-run on
    every GET, so `elapsed` is measured against the clock at serve time
    rather than frozen at whenever the task last had a percentage to
    report."""
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

    # Every tracked task, reporting or not -- the entire point of `running`
    # over `task_progress`. `percent`/`rate` are added only when that pid has
    # actually reported one (checked individually: a report whose own
    # progress was negative, bitbake's "busy, amount unknown", still counts
    # as reporting for `rate` even though it carries no usable `percent`),
    # so an un-instrumented `do_configure` serves with neither key rather
    # than a misleading `null`.
    running = []
    for pid, (recipe, task, started) in _task_pids.items():
        meta = _task_meta.get(pid) or {}
        entry = {
            "tid": meta.get("tid"),
            "pn": meta.get("pn"),
            "pv": meta.get("pv"),
            "mc": meta.get("mc", ""),
            "recipe": recipe,
            "task": task,
            "started": started,
        }
        report = _task_reports.get(pid)
        if report is not None:
            if report["percent"] is not None:
                entry["percent"] = report["percent"]
            if report["rate"] is not None:
                entry["rate"] = report["rate"]
        running.append(entry)
    _state["running"] = running
    # Uncapped on purpose -- see _active_pids' own comment.
    _state["active"] = len(_active_pids)


def _track_task(pid, recipe, task, tid=None, pn=None, pv=None, mc="", logfile=None):
    if not pid or pid <= 0:
        return
    with _lock:
        # Uncapped: added before the capped map below ever evicts anything,
        # so the true count is never short even on a build with more
        # concurrent tasks than MAX_TASK_PROGRESS.
        _active_pids.add(pid)
        if pid not in _task_pids:
            _evict_oldest(_task_pids, MAX_TASK_PROGRESS)
            _evict_oldest(_task_meta, MAX_TASK_PROGRESS)
        # Unconditional, so a reused pid starts its clock over rather than
        # inheriting the age of whatever task held it before.
        _task_pids[pid] = (recipe, task, time.time())
        _task_meta[pid] = {"tid": tid, "pn": pn, "pv": pv, "mc": mc}
        # log_path (#147), straight off TaskStarted's own `logfile` --
        # never a hand-built ${T} path. See the "Log paths and tails"
        # section below for the full lifecycle.
        if tid and logfile:
            if tid not in _log_paths:
                _evict_oldest(_log_paths, MAX_LOG_PATHS)
            _log_paths[tid] = logfile
            _state["log_path"] = dict(_log_paths)
        _publish_task_progress()


def _untrack_task(pid, keep_log=False):
    """Stop tracking PID. KEEP_LOG=True (TaskFailed only -- see
    _capture_failure_log) leaves this task's `_log_paths`/`_log_tails`
    entry in place, since a failure's log must keep serving for as long as
    it stays in `failed_tasks`, well past when the task itself stops being
    'running'. KEEP_LOG=False (TaskSucceeded/TaskFailedSilent) drops it:
    neither case belongs in `failed_tasks`, so neither should keep serving
    a log_path entry once the task is gone."""
    if not pid or pid <= 0:
        return
    with _lock:
        _active_pids.discard(pid)
        _task_pids.pop(pid, None)
        meta = _task_meta.pop(pid, None)
        _task_reports.pop(pid, None)
        if not keep_log and meta:
            tid = meta.get("tid")
            if tid:
                # Both pops must run unconditionally -- an `or` short-
                # circuits on the first truthy pop, which would then skip
                # (and so leak) a stale _log_tails[tid] left over from an
                # earlier failure of this same tid within one build (e.g.
                # a retried task that now succeeds).
                had_path = _log_paths.pop(tid, None) is not None
                had_tail = _log_tails.pop(tid, None) is not None
                if had_path or had_tail:
                    _state["log_path"] = dict(_log_paths)
                    _state["log_tail"] = dict(_log_tails)
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


# ---------------------------------------------------------------------------
# Per-recipe task history (#146)
#
# Each recipe's task-by-task past, keyed by PN ("mc:<name>:<pn>" on a
# non-default multiconfig), each value a list of {"task", "state",
# "started", "ended"} dicts. Built from the worker's bb.build TaskStarted,
# TaskSucceeded, and TaskFailed: they carry the real PN and multiconfig, and
# they are in knotty's event mask, which this bridge inherits. The runQueue
# completion and skip events are not in that mask and never arrive here.
#   running   -- TaskStarted, no outcome yet.
#   ran       -- TaskSucceeded.
#   restored  -- TaskSucceeded for <task>_setscene: sstate restored <task>.
#   failed    -- TaskFailed.
# A failed setscene attempt is not recorded; the real task runs instead.
# Tasks skipped because their stamp is current, and noexec tasks, never run
# in a worker and fire none of these, so they do not appear. `started` and
# `ended` are epoch seconds from the event's own `time`, omitted when unknown.
#
# One row per (recipe, task): a later event replaces the earlier row. The
# outer table is uncapped (thousands of recipes on an image build), which is
# why `/` only carries recipes with a running task; GET /recipes has all.
# ---------------------------------------------------------------------------

# key -> {taskname: row}; lists are built from .values() only when served.
_recipe_tasks = {}

SETSCENE_SUFFIX = "_setscene"


def _recipe_key(mc, pn):
    return ("mc:" + mc + ":" + pn) if mc else pn


def _record_recipe_task(event, name):
    """Upsert a bb.build task event into `_recipe_tasks`; any other NAME is a
    no-op, so callers can pass their whole event group through."""
    pn = getattr(event, "pn", None)
    taskname = getattr(event, "taskname", None)
    if not pn or not taskname or name not in ("TaskStarted", "TaskSucceeded", "TaskFailed"):
        return
    setscene = taskname.endswith(SETSCENE_SUFFIX)
    if setscene:
        if name != "TaskSucceeded":
            return
        taskname = taskname[: -len(SETSCENE_SUFFIX)]
    key = _recipe_key(getattr(event, "_mc", None) or "", pn)
    when = getattr(event, "time", None) or time.time()

    with _lock:
        # Not setdefault: only store a recipe once a row is written.
        tasks = _recipe_tasks.get(key, {})
        previous = tasks.get(taskname, {})
        if setscene:
            entry = {"task": taskname, "state": "restored"}
        elif name == "TaskStarted":
            entry = {"task": taskname, "state": "running", "started": when}
        else:
            entry = {"task": taskname, "state": "ran" if name == "TaskSucceeded" else "failed"}
            if "started" in previous:
                entry["started"] = previous["started"]
            entry["ended"] = when
        tasks[taskname] = entry
        _recipe_tasks[key] = tasks
        _publish_recipes()


def _publish_recipes():
    """Rebuild the served `recipes` dict from `_recipe_tasks`. Caller holds
    _lock.

    Root-payload-only (the issue's second proposed shape): a recipe appears
    here only while at least one of its tracked tasks is still `running` --
    the full table can reach thousands of entries on an image build, and
    serving all of it on every 1-second poll of `/` would mean re-sending
    nearly all of it, nearly unchanged, every second. `GET /recipes` (or
    `?pn=<pn>`) always has the full table -- see _recipes_payload()."""
    _state["recipes"] = {
        key: list(tasks.values())
        for key, tasks in _recipe_tasks.items()
        if any(t["state"] == "running" for t in tasks.values())
    }


def _recipes_payload(pn):
    """The full per-recipe task table, or just PN's, for GET /recipes.
    Caller holds _lock. `pn` of None returns everything; a PN that was
    never seen returns {} -- same "say nothing rather than guess"
    convention as the rest of this module, not a 404 (the path itself is
    valid, there is just nothing recorded for it yet)."""
    if pn is not None:
        tasks = _recipe_tasks.get(pn)
        return {pn: list(tasks.values())} if tasks is not None else {}
    return {key: list(tasks.values()) for key, tasks in _recipe_tasks.items()}


# ---------------------------------------------------------------------------
# Log paths and tails (#147)
#
# `log_path` closes the gap `running`/`failed_tasks` leave: a consumer can
# see WHAT is running or has failed, but not where its log lives inside the
# container (macOS cannot read ${T}/${WORKDIR} on the TMPDIR ext4 volume
# directly). Taken straight off TaskStarted/TaskFailed's own `logfile`
# attribute -- see bb/build.py's TaskBase.__init__, which every one of
# those events inherits -- NEVER rebuilt by hand from ${T}, since that
# would silently drift the moment bitbake's own layout changes.
#
# `log_path` tracks two different lifetimes in the SAME dict:
#   - a RUNNING task's entry, added in _track_task (alongside _task_meta)
#     and dropped in _untrack_task the moment that task ends -- unless it
#     ended via TaskFailed, see below.
#   - a FAILED task's entry, which must keep serving for as long as that
#     failure is still listed in `failed_tasks` -- well past when the task
#     stops being "running". _untrack_task's `keep_log=True` is what keeps
#     TaskFailed from dropping it the way TaskSucceeded/TaskFailedSilent do.
# Both share _log_paths/MAX_LOG_PATHS rather than two separate maps, since
# a given tid is only ever in one state at a time.
#
# `log_tail` is deliberately NOT a live tail of every running task -- that
# would mean re-reading and re-sending every running task's log on every
# `/` poll, which is exactly the "huge log, unbounded response" risk the
# issue calls out. It is captured ONCE, at TaskFailed time, bounded to
# MAX_LOG_TAIL_LINES -- a snapshot for post-mortem, not a stream. A still-
# running task's live tail is served on demand instead, via GET
# /log?tid=<tid>&lines=<n> (_serve_log below), which only ever opens a
# path already present in `_log_paths` -- never the request's own `tid`
# string, and never any path this module did not record itself.
# ---------------------------------------------------------------------------


def _tail_lines(path, max_lines, max_bytes):
    """Up to MAX_LINES lines from the end of PATH, having read at most
    MAX_BYTES from the end of the file. Best-effort: any OSError (missing
    file, permission, deleted mid-build, a symlink that no longer resolves)
    returns None rather than raising -- callers treat None as "no tail
    available", never as a reason to fail the caller's own event handling.

    Reads at most MAX_BYTES from the END of the file first, so a log many
    times that size still costs one bounded read rather than scaling with
    the file -- the line split happens only on that bounded window, never
    on the whole file."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            read_size = min(size, max_bytes)
            f.seek(size - read_size, os.SEEK_SET)
            data = f.read(read_size)
    except OSError:
        return None
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    # The read window can start mid-line when it didn't cover the whole
    # file -- drop that first, possibly-truncated line rather than serve a
    # fragment that looks like a complete one.
    if read_size < size and lines:
        lines = lines[1:]
    return lines[-max_lines:] if max_lines > 0 else []


def _capture_failure_log(tid, logfile):
    """At TaskFailed time: make sure `_log_paths[tid]` names LOGFILE, and
    snapshot a bounded tail of it into `_log_tails[tid]`. Best-effort
    throughout, same contract as the rest of this module's event handling
    -- a missing TID (this module could not build one), a missing
    LOGFILE, or an unreadable file each leave one or both maps untouched
    rather than raising. Called from _observe()'s TaskFailed branch,
    before _untrack_task(pid, keep_log=True) runs."""
    if not tid or not logfile:
        return
    with _lock:
        if tid not in _log_paths:
            _evict_oldest(_log_paths, MAX_LOG_PATHS)
        _log_paths[tid] = logfile
        _state["log_path"] = dict(_log_paths)
    # File I/O happens OUTSIDE _lock -- a slow or stuck filesystem read
    # here must never block the HTTP handler thread from serving `/`.
    tail = _tail_lines(logfile, MAX_LOG_TAIL_LINES, LOG_TAIL_CAPTURE_BYTES)
    if tail is None:
        return
    with _lock:
        if tid not in _log_tails:
            _evict_oldest(_log_tails, MAX_FAILED_TASKS)
        _log_tails[tid] = tail
        _state["log_tail"] = dict(_log_tails)


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


def _set_continue_on_failure(params):
    """Record whether this build was told to keep going after a failure.

    From bitbake's own already-parsed command-line options -- the same
    params.options main() already has (see _set_targets, which reads
    params.options.pkgs_to_build the same way). Deliberately NOT getVariable
    (this is a parser flag, not cooker state -- no server round-trip, so
    none of _set_machine()'s first-waitEvent timing concerns apply here) and
    NOT inferred from whether tasks kept running after a failure (without
    -k bitbake also lets already-running tasks finish, so that would get the
    polarity wrong on a healthy, non-continuing build).

    bitbake's own attribute name for `-k`/`--continue` changed between
    versions, both with the same store_false/default-True shape (true means
    "halt on the first failure"; -k flips it to false): current bitbake's
    argparse parser calls it `halt`, older optparse-based bitbake called it
    `abort`. Checked explicitly, in that order, with no third guess --
    verified against bitbake's own lib/bb/main.py source rather than
    assumed. A confidently wrong polarity here is worse than the field
    simply being left out, so an options object with neither name present
    leaves `continue_on_failure` out entirely."""
    try:
        options = getattr(params, "options", None)
        if options is None:
            return
        if hasattr(options, "halt"):
            halt_on_failure = bool(options.halt)
        elif hasattr(options, "abort"):
            halt_on_failure = bool(options.abort)
        else:
            return
        with _lock:
            _state["continue_on_failure"] = not halt_on_failure
    except Exception:
        # Best-effort context, never a reason to fail a build.
        pass


def _set_machine(server):
    """Ask the cooker what MACHINE, DISTRO, BUILDNAME and BB_NUMBER_THREADS
    this build is for.

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
    into one bitbake reports as failed via a non-zero exit code. `threads`/
    `buildname` are read from this exact same call site for exactly that
    reason -- not a new, separately-timed round-trip.

    `machine`/`distro`/`buildname` are plain strings; `threads` is an int.
    On a MULTICONFIG build MACHINE is only the default one, and
    per-multiconfig builds legitimately have several; a consumer should
    treat it as a label, not as a complete description of what was built.
    `buildname` is also the `tmp/buildstats/<BUILDNAME>/` directory name.
    Each field is left OUT of the served state entirely (never served as
    `null`) until its own getVariable call has actually returned a usable
    value."""
    for key, var in (("machine", "MACHINE"), ("distro", "DISTRO"),
                     ("buildname", "BUILDNAME")):
        try:
            value, error = server.runCommand(["getVariable", var])
            if not error and value:
                with _lock:
                    _state[key] = str(value)
        except Exception:
            # Best-effort context, never a reason to fail a build.
            pass
    try:
        value, error = server.runCommand(["getVariable", "BB_NUMBER_THREADS"])
        if not error and value is not None:
            with _lock:
                _state["threads"] = int(value)
    except Exception:
        # Same best-effort contract as above; BB_NUMBER_THREADS is normally
        # a plain digit string, but a non-numeric value (should never
        # happen, but this module never trusts that it can't) leaves the
        # field out rather than raising.
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


# phase -> the event-name families that mean the build has reached (at
# least) that far. Order matters: bitbake fires these in exactly this
# sequence -- parsing completes before the scene queue can decide what it
# can reuse, which settles before the run queue executes anything -- so a
# phase transition only ever moves forward. No new event subscription:
# every name below is one knotty's own mask already requests and this
# module already handles for other fields.
_PHASE_ORDER = ("parsing", "sstate", "tasks")
_PHASE_FOR_EVENT = {
    "ParseStarted": "parsing",
    "ParseProgress": "parsing",
    "sceneQueueTaskStarted": "sstate",
    "sceneQueueTaskCompleted": "sstate",
    "sceneQueueTaskFailed": "sstate",
    "runQueueTaskStarted": "tasks",
    "runQueueTaskCompleted": "tasks",
    "runQueueTaskFailed": "tasks",
    "runQueueTaskSkipped": "tasks",
}


def _advance_phase(event_type):
    """Record the furthest build phase reached so far. Caller holds _lock.

    Forward-only: an event type outside the three families above leaves
    `phase` untouched, and one inside them never moves it backwards -- a
    build already in "tasks" cannot be reported back to "sstate" by, say, a
    late-arriving sceneQueue event from hash-equivalence reopening the scene
    queue. `phase` itself stays absent (never served as `null`) until the
    very first qualifying event, same convention as threads/buildname."""
    phase = _PHASE_FOR_EVENT.get(event_type)
    if phase is None:
        return
    current = _state.get("phase")
    if current is None or _PHASE_ORDER.index(phase) > _PHASE_ORDER.index(current):
        _state["phase"] = phase


def _record(event_type, **fields):
    """Update the shared state under lock. Called only from the event tee,
    a single thread, but the HTTP handler thread reads concurrently."""
    with _lock:
        _advance_phase(event_type)
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
        # Drop log_path for anything that was still "running" when the
        # build ended -- same reasoning as task_progress/running above,
        # it's no longer true. A FAILED task's entry is untouched here: it
        # was never in _task_meta to begin with (_untrack_task popped it
        # with keep_log=True), so this loop can't reach it.
        for meta in _task_meta.values():
            tid = meta.get("tid")
            if tid:
                _log_paths.pop(tid, None)
                _log_tails.pop(tid, None)
        _state["log_path"] = dict(_log_paths)
        _state["log_tail"] = dict(_log_tails)
        _task_meta.clear()
        _active_pids.clear()
        _state["task_progress"] = []
        _state["running"] = []
        _state["active"] = 0


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
            #
            # `mc` is TaskBase's PRIVATE `_mc` (bb/build.py sets
            # self._mc = d.getVar("BB_CURRENT_MC"); there is no public `mc`
            # attribute, and no property either) -- "" for the default
            # multiconfig, same as BB_CURRENT_MC itself. `pn`/`pv` are public.
            # `tid` is built the same way bitbake's own runqueue.build_tid()
            # does (mc:<mc>:<fn>:<task> when mc, else <fn>:<task>) from
            # TaskBase's private `_fn`: the worker's fn, which carries any
            # `virtual:native:` prefix. `taskfile` is d.getVar("FILE"), the
            # bare recipe path, and would make zlib and zlib-native collide.
            taskfile = getattr(event, "taskfile", "") or ""
            taskname = getattr(event, "taskname", None)
            mc = getattr(event, "_mc", None) or ""
            fn = getattr(event, "_fn", None) or taskfile
            tid = None
            if fn and taskname:
                tid = (("mc:" + mc + ":" + fn + ":" + taskname) if mc
                       else (fn + ":" + taskname))
            _track_task(
                getattr(event, "pid", 0),
                os.path.basename(taskfile) or None,
                taskname,
                tid=tid,
                pn=getattr(event, "pn", None),
                pv=getattr(event, "pv", None),
                mc=mc,
                # TaskBase.__init__ (bb/build.py) sets this on every task
                # event, TaskStarted included -- see the "Log paths and
                # tails" section above for why it's recorded here rather
                # than rebuilt from ${T} by hand.
                logfile=getattr(event, "logfile", None),
            )
            _record_recipe_task(event, name)
        elif name in ("TaskSucceeded", "TaskFailedSilent"):
            _record_recipe_task(event, name)
            _untrack_task(getattr(event, "pid", 0))
        elif name == "TaskFailed":
            _record_recipe_task(event, name)
            # Build the tid from THIS event, the same way TaskStarted's
            # branch does (worker fn in _fn, not FILE), rather than looking
            # it up in the pid-keyed, capped _task_meta: an evicted or unseen
            # TaskStarted must not lose the failure's log.
            taskname = getattr(event, "taskname", None)
            mc = getattr(event, "_mc", None) or ""
            fn = getattr(event, "_fn", None) or getattr(event, "taskfile", "") or ""
            tid = None
            if fn and taskname:
                tid = (("mc:" + mc + ":" + fn + ":" + taskname) if mc
                       else (fn + ":" + taskname))
            _capture_failure_log(tid, getattr(event, "logfile", None))
            _untrack_task(getattr(event, "pid", 0), keep_log=True)
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
        # Routing only -- existing "/" behaviour and the 404 for a truly
        # unknown path are both unchanged, just moved into their own
        # methods so adding "/recipes" (#146) and "/log" (#147) does not
        # have to touch either.
        path, _, query = self.path.partition("?")
        if path == "/":
            self._serve_root()
            return
        if path == "/recipes":
            self._serve_recipes(query)
            return
        if path == "/log":
            self._serve_log(query)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _serve_root(self):
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

    def _serve_recipes(self, query):
        """GET /recipes[?pn=<pn>] -- the full per-recipe task table (#146),
        kept off the hot `/` path on purpose; see _publish_recipes()'s own
        docstring for why. Never touches `_terminal_fetched`: that signal
        means specifically "a client has seen the terminal status via `/`",
        which this path does not serve."""
        pn = (urllib.parse.parse_qs(query).get("pn") or [None])[0]
        with _lock:
            body = json.dumps(_recipes_payload(pn)).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_log(self, query):
        """GET /log?tid=<tid>&lines=<n> -- a bounded tail of the log file
        the bridge itself already recorded for TID in `log_path` (#147).

        SECURITY: `tid` is used ONLY as a dict key into `_log_paths` --
        never concatenated into, or otherwise treated as, a filesystem
        path. A `tid` this module never recorded (wrong, made up, or for a
        task that has since been evicted) gets a 404, same as any other
        unknown resource -- never an attempt to guess or construct a path
        for it. See the module's own "never reads an arbitrary path off
        disk" invariant at the top of this file."""
        tid = (urllib.parse.parse_qs(query).get("tid") or [None])[0]
        with _lock:
            path = _log_paths.get(tid) if tid else None
        if not path:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # No `lines`, or one that doesn't parse, gets the same sane default
        # as the inline failure-time capture (MAX_LOG_TAIL_LINES) rather
        # than silently jumping to the request-side maximum -- a typo in
        # the query string should not change how much gets served.
        raw_lines = (urllib.parse.parse_qs(query).get("lines") or [""])[0]
        try:
            lines = int(raw_lines) if raw_lines else MAX_LOG_TAIL_LINES
        except ValueError:
            lines = MAX_LOG_TAIL_LINES
        lines = max(1, min(lines, MAX_LOG_REQUEST_LINES))
        tail = _tail_lines(path, lines, LOG_REQUEST_READ_BYTES)
        body = json.dumps({"tid": tid, "lines": tail if tail is not None else []}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
    _set_continue_on_failure(params)
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
