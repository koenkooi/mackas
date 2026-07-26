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

import importlib.machinery
import importlib.util
import os
import sys
import types
import unittest

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
    def __init__(self, completed=0, total=0):
        self.completed = completed
        self.total = total


def _event(cls_name, **attrs):
    """An event object whose CLASS NAME is what bb.event.getName returns."""
    return type(cls_name, (), attrs)()


def _task_event(cls_name, taskfile, taskname, done=0, total=0):
    return _event(
        cls_name,
        taskfile=taskfile,
        taskname=taskname,
        taskstring=f"{taskfile}:{taskname}",
        stats=_Stats(done, total),
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
            "failed_tasks": [],
            "failed_count": 0,
            "recent_events": [],
        })


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


class FinishTest(BridgeTestCase):
    def test_finish_sets_the_terminal_status(self):
        bridge._finish("success")
        self.assertEqual(bridge._state["status"], "success")
        bridge._finish("failed")
        self.assertEqual(bridge._state["status"], "failed")


if __name__ == "__main__":
    unittest.main()
