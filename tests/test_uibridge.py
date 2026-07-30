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


class TerminalStatusLingerTest(BridgeTestCase):
    """Pins TODO.md item 31's fix at the HTTP-handler level: do_GET() only
    flips _terminal_fetched after a client has actually received a
    terminal-status body -- never for "building", never for a 404 (or any
    other request this handler doesn't serve with a 200 JSON body)."""

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
        self.assertFalse(bridge._terminal_fetched.is_set())

    def test_a_fetch_after_success_sets_the_flag(self):
        bridge._finish("success")
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "success")
        self.assertTrue(bridge._terminal_fetched.is_set())

    def test_a_fetch_after_failed_sets_the_flag(self):
        bridge._finish("failed")
        status, body = self.fixture.get("/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "failed")
        self.assertTrue(bridge._terminal_fetched.is_set())

    def test_a_404_never_sets_the_flag_even_when_status_is_terminal(self):
        bridge._finish("success")
        status, body = self.fixture.get("/nonexistent")
        self.assertEqual(status, 404)
        self.assertFalse(bridge._terminal_fetched.is_set())

    def test_an_unserved_method_never_sets_the_flag_even_when_terminal(self):
        # _Handler.do_HEAD() is a fixed 405 -- it never reaches the
        # body-write that do_GET() gates the flag on.
        bridge._finish("success")
        status = self.fixture.head("/")
        self.assertEqual(status, 405)
        self.assertFalse(bridge._terminal_fetched.is_set())


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
