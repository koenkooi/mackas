#!/usr/bin/env python3
#
# Tests for mackas-uibridge/mackasjson.py -- the in-container bridge that runs
# as bitbake's first real UI client and re-serves progress as JSON.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The module imports bb.event and bb.ui.knotty, which only exist inside a
# bitbake run, so they are stubbed here before import. Nothing else is faked:
# _observe, _record and _set_targets are the real code, driven with event
# objects shaped exactly like the ones bitbake fires (bb/runqueue.py's
# runQueueEvent sets taskid/taskstring/taskname/taskfile/taskhash/stats).
#
# The distinction these tests exist to pin: a FAILED SETSCENE TASK IS NOT A
# BUILD FAILURE. bitbake's own knotty treats runQueueTaskFailed as fatal
# (return_value = 1, logged as an error) and sceneQueueTaskFailed as a warning
# whose own message says "real task will be run instead". A notification that
# named setscene failures would accuse innocent recipes on a perfectly healthy
# build, which is worse than saying nothing.

import http.client
import importlib.machinery
import importlib.util
import json
import os
import sys
import threading
import time
import types
import unittest
from http.server import ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_bridge():
    """Import mackasjson.py with bitbake's modules stubbed out."""
    for name in ("bb", "bb.event", "bb.ui", "bb.ui.knotty"):
        sys.modules.setdefault(name, types.ModuleType(name))
    # _observe calls bb.event.getName(event); mirror bitbake's own definition
    # (bb/event.py getName) rather than inventing one.
    sys.modules["bb.event"].getName = lambda e: (
        e.__name__ if getattr(e, "__name__", None) is not None else e.__class__.__name__
    )
    sys.modules["bb"].event = sys.modules["bb.event"]
    sys.modules["bb"].ui = sys.modules["bb.ui"]
    sys.modules["bb.ui"].knotty = sys.modules["bb.ui.knotty"]

    path = os.path.join(REPO, "mackas-uibridge", "mackasjson.py")
    loader = importlib.machinery.SourceFileLoader("mackasjson", path)
    spec = importlib.util.spec_from_loader("mackasjson", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


bridge = _load_bridge()


class _Stats:
    """bb/runqueue.py's RunQueueStats, with the attribute names it really
    has -- one instance is created per build and .copy()'d onto every
    runQueue/sceneQueue event."""

    def __init__(self, completed=0, total=0, setscene_covered=0,
                 setscene_notcovered=0, setscene_total=0, skipped=0):
        self.completed = completed
        self.total = total
        self.setscene_covered = setscene_covered
        self.setscene_notcovered = setscene_notcovered
        self.setscene_total = setscene_total
        self.skipped = skipped


def _event(cls_name, **attrs):
    """An event object whose CLASS NAME is what bb.event.getName returns."""
    return type(cls_name, (), attrs)()


def _task_event(cls_name, taskfile, taskname, done=0, total=0, stats=None):
    return _event(
        cls_name,
        taskfile=taskfile,
        taskname=taskname,
        taskstring=f"{taskfile}:{taskname}",
        stats=_Stats(done, total) if stats is None else stats,
    )


class BridgeTestCase(unittest.TestCase):
    def setUp(self):
        # The module keeps one global _state; reset it between tests rather
        # than reimporting, which would also reset the stubs.
        bridge._state.clear()
        bridge._state.update({
            "status": "idle",
            "targets": [],
            "machine": None,
            "distro": None,
            "current": {"recipe": None, "task": None},
            "progress": {"done": 0, "total": 0},
            "sstate": None,
            "failed_tasks": [],
            "failed_count": 0,
            "task_progress": [],
            "recent_events": [],
        })
        # The sub-task progress pidmaps are module globals too, and a pid
        # left over from a previous test would attribute the next test's
        # TaskProgress to the wrong recipe.
        bridge._task_pids.clear()
        bridge._task_reports.clear()


class TargetsTest(BridgeTestCase):
    def test_targets_come_from_the_parsed_command_line(self):
        # NOT from a BuildStarted event: knotty's event mask is matched on the
        # exact class name and lists bb.event.BuildBase, so BuildStarted is
        # never delivered to a UI at all.
        params = types.SimpleNamespace(
            options=types.SimpleNamespace(pkgs_to_build=["core-image-base", "llama-cpp"])
        )
        bridge._set_targets(params)
        self.assertEqual(bridge._state["targets"], ["core-image-base", "llama-cpp"])

    def test_no_targets_is_empty_not_an_error(self):
        params = types.SimpleNamespace(options=types.SimpleNamespace(pkgs_to_build=[]))
        bridge._set_targets(params)
        self.assertEqual(bridge._state["targets"], [])

    def test_a_params_object_of_the_wrong_shape_never_raises(self):
        # A schema surprise here must not take the real build down.
        for bad in (None, object(), types.SimpleNamespace(), types.SimpleNamespace(options=None)):
            bridge._set_targets(bad)
            self.assertEqual(bridge._state["targets"], [])

    def test_targets_are_stringified(self):
        params = types.SimpleNamespace(
            options=types.SimpleNamespace(pkgs_to_build=["a", 7])
        )
        bridge._set_targets(params)
        self.assertEqual(bridge._state["targets"], ["a", "7"])


class MachineTest(BridgeTestCase):
    class _Server:
        """server.runCommand(["getVariable", NAME]) -> (value, error), the
        exact shape bb/ui/knotty.py itself relies on for BBINCLUDELOGS."""
        def __init__(self, values=None, error=None, raises=False):
            self.values = values or {}
            self.error = error
            self.raises = raises
            self.calls = []

        def runCommand(self, cmd):
            self.calls.append(cmd)
            if self.raises:
                raise RuntimeError("cooker is busy")
            return self.values.get(cmd[1]), self.error

    def test_machine_and_distro_come_from_the_cooker(self):
        srv = self._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        bridge._set_machine(srv)
        self.assertEqual(bridge._state["machine"], "beaglebone")
        self.assertEqual(bridge._state["distro"], "angstrom")
        self.assertEqual(srv.calls,
                         [["getVariable", "MACHINE"], ["getVariable", "DISTRO"]])

    def test_an_error_from_the_cooker_leaves_them_unset(self):
        bridge._set_machine(self._Server({"MACHINE": "beaglebone"}, error="boom"))
        self.assertIsNone(bridge._state["machine"])

    def test_an_unset_variable_leaves_them_unset(self):
        bridge._set_machine(self._Server({"MACHINE": None, "DISTRO": ""}))
        self.assertIsNone(bridge._state["machine"])
        self.assertIsNone(bridge._state["distro"])

    def test_a_raising_server_never_propagates(self):
        # Best-effort context must never be a reason to fail a build.
        bridge._set_machine(self._Server(raises=True))
        self.assertIsNone(bridge._state["machine"])


class FailedTaskTest(BridgeTestCase):
    def test_a_real_task_failure_is_recorded_with_its_recipe(self):
        bridge._observe(_task_event(
            "runQueueTaskFailed", "/l/meta/recipes/busybox_1.36.bb", "do_compile", 4, 10))
        self.assertEqual(
            bridge._state["failed_tasks"],
            [{"recipe": "busybox_1.36.bb", "task": "do_compile"}])
        self.assertEqual(bridge._state["failed_count"], 1)

    def test_a_setscene_failure_is_NOT_a_build_failure(self):
        # The whole point. bitbake runs the real task instead; naming the
        # recipe in a "build failed" notification would be an accusation.
        bridge._observe(_task_event(
            "sceneQueueTaskFailed", "/l/meta/recipes/zlib_1.3.bb", "do_populate_sysroot_setscene",
            1, 10))
        self.assertEqual(bridge._state["failed_tasks"], [])
        self.assertEqual(bridge._state["failed_count"], 0)
        # ...but it is still visible in the raw event stream.
        self.assertTrue(any(e["type"] == "sceneQueueTaskFailed"
                            for e in bridge._state["recent_events"]))

    def test_a_completed_task_is_not_a_failure(self):
        bridge._observe(_task_event(
            "runQueueTaskCompleted", "/l/meta/recipes/zlib_1.3.bb", "do_compile", 5, 10))
        self.assertEqual(bridge._state["failed_tasks"], [])
        self.assertEqual(bridge._state["failed_count"], 0)

    def test_the_same_failure_seen_twice_is_counted_once(self):
        for _ in range(3):
            bridge._observe(_task_event(
                "runQueueTaskFailed", "/l/busybox_1.36.bb", "do_compile", 4, 10))
        self.assertEqual(len(bridge._state["failed_tasks"]), 1)
        self.assertEqual(bridge._state["failed_count"], 1)

    def test_many_failures_are_capped_but_the_count_stays_true(self):
        # `bitbake -k` keeps going after a failure, so the list has to be
        # bounded -- but a consumer showing "3 of 47" must be able to say 47.
        n = bridge.MAX_FAILED_TASKS + 7
        for i in range(n):
            bridge._observe(_task_event(
                "runQueueTaskFailed", f"/l/pkg{i}_1.0.bb", "do_compile", i, 100))
        self.assertEqual(len(bridge._state["failed_tasks"]), bridge.MAX_FAILED_TASKS)
        self.assertEqual(bridge._state["failed_count"], n)

    def test_distinct_tasks_of_one_recipe_are_distinct_failures(self):
        bridge._observe(_task_event("runQueueTaskFailed", "/l/busybox_1.36.bb", "do_compile"))
        bridge._observe(_task_event("runQueueTaskFailed", "/l/busybox_1.36.bb", "do_install"))
        self.assertEqual(bridge._state["failed_count"], 2)


class ProgressTest(BridgeTestCase):
    def test_a_started_task_sets_status_current_and_progress(self):
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/meta/recipes/busybox_1.36.bb", "do_compile", 3, 10))
        self.assertEqual(bridge._state["status"], "building")
        self.assertEqual(bridge._state["current"],
                         {"recipe": "busybox_1.36.bb", "task": "do_compile"})
        self.assertEqual(bridge._state["progress"], {"done": 3, "total": 10})

    def test_an_unknown_event_is_ignored_without_raising(self):
        bridge._observe(_event("SomeFutureBitbakeEvent", nothing="useful"))
        self.assertEqual(bridge._state["status"], "idle")

    def test_an_event_missing_the_attributes_never_raises(self):
        bridge._observe(_event("runQueueTaskStarted"))
        self.assertEqual(bridge._state["status"], "building")

    def test_recent_events_are_capped(self):
        for i in range(bridge.MAX_RECENT_EVENTS + 25):
            bridge._observe(_task_event("runQueueTaskCompleted", f"/l/p{i}.bb", "do_compile"))
        self.assertEqual(len(bridge._state["recent_events"]), bridge.MAX_RECENT_EVENTS)


class TaskProgressTest(BridgeTestCase):
    """Progress from inside a running task -- bb.build.TaskProgress, the same
    event knotty draws its inline progress bars from.

    The distinction pinned here: TaskProgress does NOT inherit from TaskBase,
    so it names no recipe and no task; bb/build.py's own comment says the
    event PID is what identifies the task it came from. So everything below
    hangs off a TaskStarted-built pidmap, exactly as bitbake's own
    bb/ui/uihelper.py does for knotty."""

    @staticmethod
    def _started(pid, taskfile, taskname):
        return _event("TaskStarted", pid=pid, taskfile=taskfile, taskname=taskname)

    @staticmethod
    def _progress(pid, progress, rate=None):
        return _event("TaskProgress", pid=pid, progress=progress, rate=rate)

    def test_progress_is_attributed_to_the_task_that_fired_it(self):
        bridge._observe(self._started(4242, "/l/meta/recipes/systemd_257.bb", "do_compile"))
        bridge._observe(self._progress(4242, 42))
        self.assertEqual(bridge._state["task_progress"], [
            {"recipe": "systemd_257.bb", "task": "do_compile",
             "percent": 42, "rate": None, "elapsed": 0},
        ])

    def test_a_rate_string_is_carried_through(self):
        # wget/git/s3 fetchers pass one; a compile does not.
        bridge._observe(self._started(7, "/l/zlib_1.3.bb", "do_fetch"))
        bridge._observe(self._progress(7, 30, "1.2M/s"))
        self.assertEqual(bridge._state["task_progress"][0]["rate"], "1.2M/s")

    def test_a_negative_percent_means_unknown_not_a_number(self):
        # bitbake's own convention: negative == "progress is happening but we
        # cannot say how much" (git counting objects). Inventing a percentage
        # here would draw a bar that lies.
        bridge._observe(self._started(9, "/l/linux-yocto_6.6.bb", "do_fetch"))
        bridge._observe(self._progress(9, -1))
        self.assertEqual(bridge._state["task_progress"], [
            {"recipe": "linux-yocto_6.6.bb", "task": "do_fetch",
             "percent": None, "rate": None, "elapsed": 0},
        ])

    def test_percent_is_clamped_to_0_100(self):
        bridge._observe(self._started(11, "/l/a_1.0.bb", "do_compile"))
        bridge._observe(self._progress(11, 150))
        self.assertEqual(bridge._state["task_progress"][0]["percent"], 100)

    def test_a_float_percent_is_accepted(self):
        # MultiStageProgressReporter (OE-core's image.bbclass do_rootfs)
        # fires floats, not ints.
        bridge._observe(self._started(13, "/l/core-image-base.bb", "do_rootfs"))
        bridge._observe(self._progress(13, 12.7))
        self.assertEqual(bridge._state["task_progress"][0]["percent"], 12)

    def test_a_later_report_replaces_the_earlier_one(self):
        bridge._observe(self._started(21, "/l/zlib_1.3.bb", "do_compile"))
        bridge._observe(self._progress(21, 10))
        bridge._observe(self._progress(21, 55))
        self.assertEqual(len(bridge._state["task_progress"]), 1)
        self.assertEqual(bridge._state["task_progress"][0]["percent"], 55)

    def test_progress_for_an_unknown_pid_is_ignored(self):
        # bitbake's uihelper guards the same way. An unattributed percentage
        # names nothing, and pids are reused.
        bridge._observe(self._progress(31337, 50))
        self.assertEqual(bridge._state["task_progress"], [])

    def test_a_finished_task_stops_being_reported(self):
        # The entry must not outlive the task: a stale "42%" next to a recipe
        # that finished ten minutes ago is worse than no number at all.
        bridge._observe(self._started(55, "/l/zlib_1.3.bb", "do_compile"))
        bridge._observe(self._progress(55, 42))
        self.assertEqual(len(bridge._state["task_progress"]), 1)
        bridge._observe(_event("TaskSucceeded", pid=55,
                                taskfile="/l/zlib_1.3.bb", taskname="do_compile"))
        self.assertEqual(bridge._state["task_progress"], [])

    def test_a_failed_task_stops_being_reported_too(self):
        for ending in ("TaskFailed", "TaskFailedSilent"):
            bridge._task_pids.clear()
            bridge._task_reports.clear()
            bridge._state["task_progress"] = []
            bridge._observe(self._started(66, "/l/busybox_1.36.bb", "do_compile"))
            bridge._observe(self._progress(66, 5))
            bridge._observe(_event(ending, pid=66, taskfile="/l/busybox_1.36.bb",
                                    taskname="do_compile"))
            self.assertEqual(bridge._state["task_progress"], [], ending)

    def test_several_tasks_report_independently(self):
        bridge._observe(self._started(1, "/l/a_1.0.bb", "do_compile"))
        bridge._observe(self._started(2, "/l/b_2.0.bb", "do_compile"))
        bridge._observe(self._progress(1, 10))
        bridge._observe(self._progress(2, 90))
        self.assertEqual(
            [(e["recipe"], e["percent"]) for e in bridge._state["task_progress"]],
            [("a_1.0.bb", 10), ("b_2.0.bb", 90)])

    def test_a_started_task_that_never_reports_is_not_listed(self):
        # Most tasks have no progress varflag at all; listing them with
        # nothing to say would make the field useless noise.
        bridge._observe(self._started(3, "/l/plainmake_1.0.bb", "do_compile"))
        self.assertEqual(bridge._state["task_progress"], [])

    def test_progress_events_never_enter_recent_events(self):
        # One per percentage point would flush the 50-deep ring several times
        # a second and destroy the one thing it is for.
        bridge._observe(self._started(4, "/l/a_1.0.bb", "do_compile"))
        for pct in range(100):
            bridge._observe(self._progress(4, pct))
        self.assertEqual(bridge._state["recent_events"], [])

    def test_task_lifecycle_events_never_enter_recent_events_either(self):
        # They duplicate the runQueue events already recorded there.
        bridge._observe(self._started(5, "/l/a_1.0.bb", "do_compile"))
        bridge._observe(_event("TaskSucceeded", pid=5, taskfile="/l/a_1.0.bb",
                                taskname="do_compile"))
        self.assertEqual(bridge._state["recent_events"], [])

    def test_progress_does_not_move_the_build_wide_counter(self):
        # progress.done/total count bitbake TASKS; a task at 42% has still
        # completed zero of them.
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile", 3, 10))
        bridge._observe(self._started(6, "/l/a_1.0.bb", "do_compile"))
        bridge._observe(self._progress(6, 42))
        self.assertEqual(bridge._state["progress"], {"done": 3, "total": 10})

    def test_a_leaked_pid_cannot_grow_the_maps_without_limit(self):
        # A worker killed outright never fires TaskSucceeded/TaskFailed, so
        # the cap (evicting oldest-first) is what keeps a long build bounded.
        n = bridge.MAX_TASK_PROGRESS + 10
        for pid in range(1, n + 1):
            bridge._observe(self._started(pid, f"/l/p{pid}_1.0.bb", "do_compile"))
            bridge._observe(self._progress(pid, 50))
        listed = [e["recipe"] for e in bridge._state["task_progress"]]
        self.assertLessEqual(len(listed), bridge.MAX_TASK_PROGRESS)
        # ...and it is the OLDEST that went, which is the stale one in the
        # only case this cap exists for: the newest task is still reported,
        # the first one is not.
        self.assertIn(f"p{n}_1.0.bb", listed)
        self.assertNotIn("p1_1.0.bb", listed)

    def test_a_malformed_progress_event_never_raises(self):
        bridge._observe(self._started(8, "/l/a_1.0.bb", "do_compile"))
        for bad in (None, "nope", object()):
            bridge._observe(self._progress(8, bad))
        self.assertEqual(bridge._state["task_progress"], [])

    def test_a_started_event_missing_everything_never_raises(self):
        bridge._observe(_event("TaskStarted"))
        bridge._observe(_event("TaskProgress"))
        bridge._observe(_event("TaskSucceeded"))
        self.assertEqual(bridge._state["task_progress"], [])


class TaskElapsedTest(BridgeTestCase):
    """How long each reporting task has been running.

    An observation, not a prediction -- which is the whole reason it is here
    and a build-wide ETA is not: sstate makes task count and wall time
    anti-correlated, so a percentage-derived estimate would be confidently
    wrong. This one cannot be."""

    @staticmethod
    def _started(pid, taskfile, taskname):
        return _event("TaskStarted", pid=pid, taskfile=taskfile, taskname=taskname)

    @staticmethod
    def _progress(pid, progress, rate=None):
        return _event("TaskProgress", pid=pid, progress=progress, rate=rate)

    def _age(self, pid, seconds):
        """Backdate PID's recorded start, so elapsed is deterministic."""
        recipe, task, started = bridge._task_pids[pid]
        bridge._task_pids[pid] = (recipe, task, started - seconds)

    def test_elapsed_counts_from_the_task_start_not_the_first_report(self):
        # An instrumented compile fires its first TaskProgress well after it
        # began; dating the age from that would understate every task.
        bridge._observe(self._started(101, "/l/systemd_257.bb", "do_compile"))
        self._age(101, 90)
        bridge._observe(self._progress(101, 42))
        self.assertEqual(bridge._state["task_progress"][0]["elapsed"], 90)

    def test_a_busy_task_with_no_percent_still_has_an_age(self):
        # The gap this closes: bitbake's negative progress means "happening,
        # amount unknown", and a bare "busy" has no scale at all.
        bridge._observe(self._started(102, "/l/linux-yocto_6.6.bb", "do_fetch"))
        self._age(102, 3661)
        bridge._observe(self._progress(102, -1))
        entry = bridge._state["task_progress"][0]
        self.assertIsNone(entry["percent"])
        self.assertEqual(entry["elapsed"], 3661)

    def test_each_task_is_aged_independently(self):
        bridge._observe(self._started(103, "/l/a_1.0.bb", "do_compile"))
        bridge._observe(self._started(104, "/l/b_2.0.bb", "do_compile"))
        self._age(103, 10)
        self._age(104, 500)
        bridge._observe(self._progress(103, 5))
        bridge._observe(self._progress(104, 5))
        self.assertEqual(
            [e["elapsed"] for e in bridge._state["task_progress"]], [10, 500])

    def test_a_reused_pid_starts_its_clock_over(self):
        # No end event in between -- the case _track_task's unconditional
        # assignment exists for. A worker whose TaskSucceeded never arrived
        # leaves its pid in the map, and the next task to get that pid must
        # not inherit its age.
        bridge._observe(self._started(105, "/l/a_1.0.bb", "do_compile"))
        self._age(105, 600)
        bridge._observe(self._started(105, "/l/b_2.0.bb", "do_compile"))
        bridge._observe(self._progress(105, 5))
        entry = bridge._state["task_progress"][0]
        self.assertEqual(entry["recipe"], "b_2.0.bb")
        self.assertEqual(entry["elapsed"], 0)

    def test_an_unknown_start_time_is_null_not_zero(self):
        # A report whose pid is no longer in the pidmap already renders
        # recipe/task as null; a fabricated "0 seconds" would be worse than
        # saying nothing, and would read as a task that just began.
        with bridge._lock:
            bridge._task_reports[106] = {"percent": 50, "rate": None}
            bridge._publish_task_progress()
        self.assertEqual(bridge._state["task_progress"], [
            {"recipe": None, "task": None, "percent": 50,
             "rate": None, "elapsed": None},
        ])


class SstateCoverageTest(BridgeTestCase):
    """How much of the build sstate covered, off the RunQueueStats object
    every runQueue/sceneQueue event already carries (bb/runqueue.py creates
    one per build and .copy()s it onto each event).

    The distinction pinned here: this is only read from runQueue events.
    bb/runqueue.py sets sqdone before it ever asks the scheduler for a real
    task, so the setscene counts are settled by then -- a sceneQueue event
    carries a tally still being built up, and serving that would report a
    warm cache as a cold one for the whole scene-queue phase."""

    @staticmethod
    def _stats(**kwargs):
        return _Stats(**kwargs)

    def test_coverage_is_read_off_a_runqueue_event(self):
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/busybox_1.36.bb", "do_compile",
            stats=self._stats(completed=1200, total=3170, setscene_covered=412,
                              setscene_notcovered=38, setscene_total=450,
                              skipped=1204)))
        self.assertEqual(bridge._state["sstate"], {
            "covered": 412, "notcovered": 38, "total": 450, "skipped": 1204,
        })

    def test_it_starts_out_unknown_rather_than_zero(self):
        self.assertIsNone(bridge._state["sstate"])

    def test_a_scenequeue_event_does_not_publish_a_half_built_tally(self):
        bridge._observe(_task_event(
            "sceneQueueTaskStarted", "/l/busybox_1.36.bb", "do_populate_sysroot",
            stats=self._stats(setscene_covered=3, setscene_notcovered=0,
                              setscene_total=450, skipped=0)))
        self.assertIsNone(bridge._state["sstate"])

    def test_every_runqueue_event_type_publishes_it(self):
        for name in ("runQueueTaskStarted", "runQueueTaskCompleted",
                      "runQueueTaskFailed", "runQueueTaskSkipped"):
            bridge._state["sstate"] = None
            bridge._observe(_task_event(
                name, "/l/a_1.0.bb", "do_compile",
                stats=self._stats(setscene_covered=7, setscene_notcovered=1,
                                  setscene_total=8, skipped=9)))
            self.assertEqual(bridge._state["sstate"]["covered"], 7, name)

    def test_a_later_event_refreshes_it(self):
        # Hash equivalence can reopen the scene queue mid-build, so this keeps
        # tracking rather than latching on the first value it sees.
        bridge._observe(_task_event(
            "runQueueTaskCompleted", "/l/a_1.0.bb", "do_compile",
            stats=self._stats(setscene_covered=10, setscene_total=20, skipped=5)))
        bridge._observe(_task_event(
            "runQueueTaskCompleted", "/l/b_2.0.bb", "do_compile",
            stats=self._stats(setscene_covered=14, setscene_total=20, skipped=9)))
        self.assertEqual(bridge._state["sstate"]["covered"], 14)
        self.assertEqual(bridge._state["sstate"]["skipped"], 9)

    def test_a_stats_object_without_the_coverage_fields_leaves_it_unknown(self):
        # Some other bitbake, or a schema surprise: all four fields or none,
        # since a partial tally reads as a real, terrible hit rate.
        stats = _event("Stats", completed=3, total=10)
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile", stats=stats))
        self.assertIsNone(bridge._state["sstate"])
        # ...and the build-wide counter it does understand still landed.
        self.assertEqual(bridge._state["progress"], {"done": 3, "total": 10})

    def test_a_partially_populated_stats_object_publishes_nothing(self):
        stats = _event("Stats", completed=0, total=10, setscene_covered=5,
                       setscene_total=10)
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile", stats=stats))
        self.assertIsNone(bridge._state["sstate"])

    def test_a_non_integer_coverage_value_publishes_nothing(self):
        for bad in (None, "12", 4.5, True):
            bridge._state["sstate"] = None
            bridge._observe(_task_event(
                "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile",
                stats=self._stats(setscene_covered=bad, setscene_total=10)))
            self.assertIsNone(bridge._state["sstate"], repr(bad))

    def test_coverage_never_enters_recent_events(self):
        # It is build-wide state, not a per-event fact; repeating it 50 times
        # over would crowd out the ring's actual contents.
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile",
            stats=self._stats(setscene_covered=1, setscene_total=2, skipped=3)))
        self.assertEqual(len(bridge._state["recent_events"]), 1)
        self.assertNotIn("sstate", bridge._state["recent_events"][0])

    def test_it_survives_the_end_of_the_build(self):
        # Unlike task_progress, this describes what already happened, so it
        # stays true (and useful) next to a terminal status.
        bridge._observe(_task_event(
            "runQueueTaskCompleted", "/l/a_1.0.bb", "do_compile",
            stats=self._stats(setscene_covered=412, setscene_total=450)))
        bridge._finish("success")
        self.assertEqual(bridge._state["sstate"]["covered"], 412)


class FinishTest(BridgeTestCase):
    def test_finish_sets_the_terminal_status(self):
        bridge._finish("success")
        self.assertEqual(bridge._state["status"], "success")
        bridge._finish("failed")
        self.assertEqual(bridge._state["status"], "failed")

    def test_finish_clears_any_task_still_claiming_to_be_running(self):
        # A build that died with workers up never fires their end events, and
        # the terminal payload is served for the whole linger window -- a
        # frozen "42%" next to "failed" would be a lie for all of it.
        bridge._observe(_event("TaskStarted", pid=77, taskfile="/l/a_1.0.bb",
                                taskname="do_compile"))
        bridge._observe(_event("TaskProgress", pid=77, progress=42, rate=None))
        self.assertEqual(len(bridge._state["task_progress"]), 1)
        bridge._finish("failed")
        self.assertEqual(bridge._state["task_progress"], [])


class TeeEventHandlerMachineFetchTest(BridgeTestCase):
    """_TeeEventHandler is the ONLY place _set_machine() may run (see its own
    docstring, and TODO.md item 32's full root-cause writeup): a getVariable
    round-trip issued before bb.ui.knotty.main() has run
    params.updateToServer() forces a premature, empty-environment cooker
    config parse, which crashes a real build via base.bbclass's
    setup_hosttools_dir() -- an otherwise 100%-successful build reported as
    FAILED. These tests pin the fix: the fetch happens on the first
    waitEvent() call, exactly once, regardless of what that call returns,
    and never before."""

    class _RealHandler:
        """Stand-in for the real eventHandler bb.ui.knotty.main() drives.
        waitEvent() returns items from a queue in order; an exhausted queue
        (or an explicit None entry) mirrors a poll that timed out without an
        event -- a normal, non-exceptional return from the real thing."""
        def __init__(self, events=()):
            self._events = list(events)
            self.calls = 0

        def waitEvent(self, delay):
            self.calls += 1
            return self._events.pop(0) if self._events else None

    def setUp(self):
        super().setUp()
        # An unrelated fix (TODO.md item 31) added this one-shot Event for
        # the terminal-status HTTP linger; reset it here purely for
        # isolation between tests -- nothing else in this class touches it.
        bridge._terminal_fetched.clear()

    def test_no_fetch_at_construction(self):
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        real = self._RealHandler([_task_event(
            "runQueueTaskStarted", "/l/busybox_1.36.bb", "do_compile")])
        bridge._TeeEventHandler(real, srv)
        self.assertEqual(srv.calls, [])

    def test_first_waitEvent_fetches_machine_and_distro_exactly_once(self):
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        real = self._RealHandler([_task_event(
            "runQueueTaskStarted", "/l/busybox_1.36.bb", "do_compile")])
        tee = bridge._TeeEventHandler(real, srv)
        tee.waitEvent(0)
        self.assertEqual(srv.calls,
                         [["getVariable", "MACHINE"], ["getVariable", "DISTRO"]])
        self.assertEqual(bridge._state["machine"], "beaglebone")
        self.assertEqual(bridge._state["distro"], "angstrom")

    def test_fetch_happens_once_not_per_event(self):
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        events = [_task_event("runQueueTaskStarted", f"/l/p{i}.bb", "do_compile")
                  for i in range(5)]
        real = self._RealHandler(events)
        tee = bridge._TeeEventHandler(real, srv)
        for _ in range(5):
            tee.waitEvent(0)
        self.assertEqual(len(srv.calls), 2)

    def test_a_None_event_still_consumes_the_one_shot_fetch(self):
        # The fix is deliberately unconditional: it fires on the first call
        # regardless of whether that call actually returns an event.
        # TODO.md item 32's "Fix" section notes gating it on a real event
        # first (as originally suggested) would be more cautious than
        # necessary, not wrong -- but the precisely-necessary invariant is
        # just "on or after the first waitEvent() call".
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        real = self._RealHandler([None, None])
        tee = bridge._TeeEventHandler(real, srv)
        self.assertIsNone(tee.waitEvent(0))
        self.assertEqual(len(srv.calls), 2)
        self.assertIsNone(tee.waitEvent(0))
        self.assertEqual(len(srv.calls), 2)

    def test_event_passes_through_unchanged_and_is_still_observed(self):
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        event = _task_event(
            "runQueueTaskStarted", "/l/busybox_1.36.bb", "do_compile", 3, 10)
        real = self._RealHandler([event])
        tee = bridge._TeeEventHandler(real, srv)
        result = tee.waitEvent(0)
        self.assertIs(result, event)  # not a copy/wrapper -- knotty sees the real thing.
        self.assertEqual(bridge._state["status"], "building")
        self.assertEqual(bridge._state["current"],
                         {"recipe": "busybox_1.36.bb", "task": "do_compile"})

    def test_main_performs_no_server_round_trip_before_knotty_main_is_entered(self):
        """The regression guard that matters most: this is the test that
        would fail if _set_machine() were ever moved back to the top of
        main(), which is exactly the bug TODO.md item 32 describes (a real
        build reported FAILED despite 100% of tasks succeeding)."""
        srv = MachineTest._Server({"MACHINE": "beaglebone", "DISTRO": "angstrom"})
        snapshot = []

        def fake_knotty_main(server, eventHandler, params):
            # This mirrors what the real bb.ui.knotty.main() does before its
            # event loop starts: nothing server-side has happened yet at
            # this point in the real code either (params.updateToServer()
            # talks to the server over its own command, never getVariable).
            snapshot.append(list(server.calls))
            eventHandler.waitEvent(0)
            # Skip the real item-31 terminal-status linger -- unrelated to
            # what this test checks, and would otherwise block for
            # TERMINAL_LINGER_SECONDS.
            bridge._terminal_fetched.set()
            return 0

        knotty = bridge.bb.ui.knotty
        had_main = hasattr(knotty, "main")
        old_main = getattr(knotty, "main", None)

        def _restore_main():
            if had_main:
                knotty.main = old_main
            else:
                del knotty.main
        self.addCleanup(_restore_main)
        knotty.main = fake_knotty_main

        old_port = bridge.PORT
        # Ephemeral port -- main() reads the module global PORT at call
        # time (there's no local rebinding in its body), so this override
        # takes effect without needing to touch the real default of 8801.
        bridge.PORT = 0
        self.addCleanup(setattr, bridge, "PORT", old_port)

        real = self._RealHandler([_task_event(
            "runQueueTaskStarted", "/l/busybox_1.36.bb", "do_compile")])
        params = types.SimpleNamespace(options=types.SimpleNamespace(pkgs_to_build=[]))

        rc = bridge.main(srv, real, params)

        self.assertEqual(rc, 0)
        # Nothing was asked of the cooker before knotty's own main() ran.
        self.assertEqual(snapshot, [[]])
        # ...and the ONE waitEvent() call inside it is what triggered the
        # fetch -- exactly those two calls, nothing more.
        self.assertEqual(srv.calls,
                         [["getVariable", "MACHINE"], ["getVariable", "DISTRO"]])


class _HandlerFixture:
    """A live bridge._Handler server on 127.0.0.1:0 -- the same real,
    in-process HTTP server idiom tests/test_mirrord.py's ServerFixture uses
    (bind ("127.0.0.1", 0), serve on a daemon thread, drive it with
    http.client). Loopback only, ephemeral port: never 0.0.0.0, so this
    fixture never triggers a macOS incoming-connections permission prompt."""

    def __init__(self):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), bridge._Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                        kwargs={"poll_interval": 0.05},
                                        daemon=True)
        self.thread.start()

    def get(self, path="/"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request("GET", path)
            resp = conn.getresponse()
            body = resp.read()
            return resp.status, body
        finally:
            conn.close()

    def head(self, path="/"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request("HEAD", path)
            resp = conn.getresponse()
            resp.read()
            return resp.status
        finally:
            conn.close()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


class ServedPayloadTest(BridgeTestCase):
    """What a poller actually receives, over real HTTP -- not just what
    _state holds."""

    def setUp(self):
        super().setUp()
        bridge._terminal_fetched.clear()
        self.fixture = _HandlerFixture()
        self.addCleanup(self.fixture.close)

    def _payload(self):
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        return json.loads(body)

    def test_a_task_is_re_aged_at_serve_time_not_at_its_last_report(self):
        # The whole point: a task that reports once and then goes quiet for
        # ten minutes must not serve a ten-minute-old "0s". TaskProgress
        # genuinely does go quiet (a fetch counting objects fires rarely).
        bridge._observe(_event("TaskStarted", pid=201,
                                taskfile="/l/systemd_257.bb", taskname="do_compile"))
        bridge._observe(_event("TaskProgress", pid=201, progress=42, rate=None))
        self.assertEqual(bridge._state["task_progress"][0]["elapsed"], 0)
        recipe, task, started = bridge._task_pids[201]
        bridge._task_pids[201] = (recipe, task, started - 600)
        self.assertEqual(self._payload()["task_progress"][0]["elapsed"], 600)

    def test_serving_does_not_resurrect_a_finished_task(self):
        # do_GET rebuilds task_progress; that rebuild must stay driven by
        # what is REPORTING, so a task that ended stays gone...
        bridge._observe(_event("TaskStarted", pid=202, taskfile="/l/a_1.0.bb",
                                taskname="do_compile"))
        bridge._observe(_event("TaskProgress", pid=202, progress=42, rate=None))
        bridge._observe(_event("TaskSucceeded", pid=202, taskfile="/l/a_1.0.bb",
                                taskname="do_compile"))
        self.assertEqual(self._payload()["task_progress"], [])

    def test_serving_does_not_list_a_task_that_never_reported(self):
        # ...and a running task with nothing to say about itself is still not
        # listed, which is what keeps the field meaningful on a build whose
        # recipes are all plain make-based.
        bridge._observe(_event("TaskStarted", pid=203, taskfile="/l/plain_1.0.bb",
                                taskname="do_compile"))
        self.assertEqual(self._payload()["task_progress"], [])

    def test_sstate_coverage_is_in_the_served_json(self):
        self.assertIsNone(self._payload()["sstate"])
        bridge._observe(_task_event(
            "runQueueTaskStarted", "/l/a_1.0.bb", "do_compile",
            stats=_Stats(completed=1, total=3170, setscene_covered=412,
                         setscene_notcovered=38, setscene_total=450,
                         skipped=1204)))
        self.assertEqual(self._payload()["sstate"], {
            "covered": 412, "notcovered": 38, "total": 450, "skipped": 1204,
        })


class TerminalStatusLingerTest(BridgeTestCase):
    """Pins TODO.md item 31's fix at the HTTP-handler level: do_GET() only
    flips _terminal_fetched after a client has actually received a
    terminal-status body -- never for "building", never for a 404 (or any
    other request this handler doesn't serve with a 200 JSON body).

    Every assertion here waits rather than sampling. do_GET sets the flag
    AFTER the body write, deliberately -- item 31's whole point is that a
    terminal status has actually REACHED a client -- so the client is often
    back from read() before the handler thread gets there, and an immediate
    is_set() is a coin flip. The negative direction needs the same treatment
    for the opposite reason: an instant check passes just as happily against
    a handler that sets the flag a millisecond late, which is the bug those
    tests exist to catch."""

    _FLAG_TIMEOUT = 5.0
    _NOT_SET_GRACE = 0.25

    def setUp(self):
        super().setUp()
        # Same reason TeeEventHandlerMachineFetchTest resets this: a
        # module-global one-shot Event must never leak between tests.
        bridge._terminal_fetched.clear()
        self.fixture = _HandlerFixture()
        self.addCleanup(self.fixture.close)

    def test_building_status_is_served_without_setting_the_flag(self):
        bridge._state["status"] = "building"
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "building")
        self.assertFalse(bridge._terminal_fetched.wait(self._NOT_SET_GRACE))

    def test_a_fetch_after_success_sets_the_flag(self):
        bridge._finish("success")
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "success")
        self.assertTrue(bridge._terminal_fetched.wait(self._FLAG_TIMEOUT))

    def test_a_fetch_after_failed_sets_the_flag(self):
        bridge._finish("failed")
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "failed")
        self.assertTrue(bridge._terminal_fetched.wait(self._FLAG_TIMEOUT))

    def test_a_404_never_sets_the_flag_even_when_status_is_terminal(self):
        bridge._finish("success")
        status, body = self.fixture.get("/nonexistent")
        self.assertEqual(status, 404)
        self.assertFalse(bridge._terminal_fetched.wait(self._NOT_SET_GRACE))

    def test_an_unserved_method_never_sets_the_flag_even_when_terminal(self):
        # _Handler.do_HEAD() is a fixed 405 -- it never reaches the
        # body-write that do_GET() gates the flag on.
        bridge._finish("success")
        status = self.fixture.head("/")
        self.assertEqual(status, 405)
        self.assertFalse(bridge._terminal_fetched.wait(self._NOT_SET_GRACE))


class MainTerminalLingerTest(BridgeTestCase):
    """Pins TODO.md item 31's fix at the main()-level: the finally block's
    _terminal_fetched.wait(TERMINAL_LINGER_SECONDS) call, and the
    KeyboardInterrupt/SystemExit fast-path that skips it entirely. Follows
    TeeEventHandlerMachineFetchTest.
    test_main_performs_no_server_round_trip_before_knotty_main_is_entered's
    own pattern for stubbing bb.ui.knotty.main and overriding bridge.PORT to
    an ephemeral port via addCleanup-restored monkeypatches."""

    def setUp(self):
        super().setUp()
        bridge._terminal_fetched.clear()

    def _patch_knotty_main(self, fn):
        knotty = bridge.bb.ui.knotty
        had_main = hasattr(knotty, "main")
        old_main = getattr(knotty, "main", None)

        def _restore():
            if had_main:
                knotty.main = old_main
            else:
                del knotty.main
        self.addCleanup(_restore)
        knotty.main = fn

    def _patch_port(self, port=0):
        # main() reads the module global PORT at call time (no local
        # rebinding in its body), so this override takes effect without
        # needing to touch the real default of 8801.
        old_port = bridge.PORT
        bridge.PORT = port
        self.addCleanup(setattr, bridge, "PORT", old_port)

    def _patch_linger(self, seconds):
        old = bridge.TERMINAL_LINGER_SECONDS
        bridge.TERMINAL_LINGER_SECONDS = seconds
        self.addCleanup(setattr, bridge, "TERMINAL_LINGER_SECONDS", old)

    @staticmethod
    def _params():
        return types.SimpleNamespace(options=types.SimpleNamespace(pkgs_to_build=[]))

    # main() binds a real ThreadingHTTPServer and its finally block always
    # runs httpd.shutdown() before returning/re-raising. shutdown() blocks
    # until serve_forever()'s loop notices the shutdown request, which (at
    # the default poll_interval of 0.5s that main() uses) measured ~0.5-0.52s
    # on this machine -- on top of whatever the linger itself contributes.
    # That fixed cost is present on EVERY call below, lingered or not, so the
    # linger durations and margins here are sized to stay clearly separated
    # from it in both directions rather than cutting it close.
    _SHORT_LINGER = 1.5  # a "linger happens" duration comfortably above ~0.5s
    _LONG_LINGER = 2.0   # Ctrl-C: prove the skip holds even with room to spare
    _FAST_PATH_CEILING = 1.0  # skip/cut-short paths must land under this

    def test_linger_happens_when_nobody_ever_fetches(self):
        # Knotty stub returns immediately; nothing ever calls back to set
        # _terminal_fetched -- main() must still wait out the full window.
        self._patch_port(0)
        self._patch_linger(self._SHORT_LINGER)
        self._patch_knotty_main(lambda server, eventHandler, params: 0)

        start = time.monotonic()
        rc = bridge.main(object(), object(), self._params())
        elapsed = time.monotonic() - start

        self.assertEqual(rc, 0)
        self.assertEqual(bridge._state["status"], "success")
        self.assertGreaterEqual(elapsed, self._SHORT_LINGER - 0.2)

    def test_linger_is_cut_short_by_an_early_fetch(self):
        # Stands in for a poller that already fetched the terminal state via
        # do_GET() -- see TerminalStatusLingerTest for that half of the
        # mechanism -- so main() must not wait out the rest of the window.
        self._patch_port(0)
        self._patch_linger(self._SHORT_LINGER)

        def fake_knotty_main(server, eventHandler, params):
            bridge._terminal_fetched.set()
            return 0
        self._patch_knotty_main(fake_knotty_main)

        start = time.monotonic()
        rc = bridge.main(object(), object(), self._params())
        elapsed = time.monotonic() - start

        self.assertEqual(rc, 0)
        self.assertEqual(bridge._state["status"], "success")
        self.assertLess(elapsed, self._FAST_PATH_CEILING)

    def test_ctrl_c_skips_the_linger_entirely(self):
        # A human hitting Ctrl-C wants their prompt back immediately -- a
        # more generous linger here (2.0s) than the other tests keeps this
        # assertion honest without inviting flakiness on a loaded machine.
        self._patch_port(0)
        self._patch_linger(self._LONG_LINGER)

        def fake_knotty_main(server, eventHandler, params):
            raise KeyboardInterrupt()
        self._patch_knotty_main(fake_knotty_main)

        start = time.monotonic()
        with self.assertRaises(KeyboardInterrupt):
            bridge.main(object(), object(), self._params())
        elapsed = time.monotonic() - start

        self.assertEqual(bridge._state["status"], "failed")
        self.assertLess(elapsed, self._FAST_PATH_CEILING)

    def test_a_non_ctrl_c_crash_still_lingers(self):
        # A plain crash (not Ctrl-C/SystemExit) must still give a poller the
        # linger window to observe the "failed" status.
        self._patch_port(0)
        self._patch_linger(self._SHORT_LINGER)

        def fake_knotty_main(server, eventHandler, params):
            raise RuntimeError("boom")
        self._patch_knotty_main(fake_knotty_main)

        start = time.monotonic()
        with self.assertRaises(RuntimeError):
            bridge.main(object(), object(), self._params())
        elapsed = time.monotonic() - start

        self.assertEqual(bridge._state["status"], "failed")
        self.assertGreaterEqual(elapsed, self._SHORT_LINGER - 0.2)


class TerminalLingerDefaultsTest(BridgeTestCase):
    def test_shipped_defaults(self):
        # A silent retune of either constant would quietly re-break the
        # notification this fix exists for (see TODO.md item 31) or widen
        # what counts as terminal -- catch it here, fast and unconditional.
        self.assertEqual(bridge.TERMINAL_LINGER_SECONDS, 5.0)
        self.assertEqual(bridge.TERMINAL_STATUSES, ("success", "failed"))


if __name__ == "__main__":
    unittest.main()
