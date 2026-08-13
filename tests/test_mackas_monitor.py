#!/usr/bin/env python3
#
# Tests for tools/mackas-monitor.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stdlib only (unittest), matching the tool's own no-dependencies rule and the
# rest of this suite. Covers the pieces that are pure-function-testable
# without a real HTTP server (tests/monitor.bats covers those, end to end):
#
#   * connection_error_message -- three genuinely different situations
#     (nothing listening, something listening but not answering, a real
#     timeout) used to collapse into one bare errno; this pins that each one
#     is told apart, from both the URLError-wrapped and bare-OSError forms
#     urllib is observed to raise depending on exactly where the failure
#     lands in the socket/HTTP stack.
#   * render/new_render_context -- the header line prints once, not every
#     poll; percent/elapsed/failed-count are appended AFTER the original
#     "[status] done/total  recipe:task" shape, never inserted into it, so
#     anything grepping for that substring still matches; idle gets words,
#     not "0/0  -:-"; a repeated identical line does not print twice on a
#     non-tty (the dedup half of the finding -- the \r-overwrite half needs
#     a real tty and is exercised only by hand).
#   * _format_elapsed -- the M:SS / H:MM:SS boundary.
#   * resolve_direct_endpoint and the poll loop's use of it -- the route
#     around Apple container's resetting port-forward (issue #49). No
#     `container` runs here: subprocess.run and shutil.which are
#     monkeypatched with canned output, the same way tests/test_overhead.py
#     fakes `ps`, and the inspect payload below is the real shape read off a
#     running kas build.
#   * --wait-for-start -- the poll loop tolerates the bridge not being up
#     yet, but only before the first successful fetch; a failure after that
#     is still immediate. time.monotonic/time.sleep are monkeypatched (a
#     deterministic counter and a no-op) so this is instant, not a real wait.

import contextlib
import importlib.machinery
import importlib.util
import io
import itertools
import json
import os
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
MONITOR = os.path.join(HERE, os.pardir, "tools", "mackas-monitor")


def _load():
    # No .py extension (it is an installed tool), so import by path via
    # SourceFileLoader. __name__ is "mackas_monitor", not "__main__", so
    # main() does not run on import.
    loader = importlib.machinery.SourceFileLoader("mackas_monitor", MONITOR)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


mon = _load()


class ConnectionErrorMessageTest(unittest.TestCase):
    def test_refused_bare(self):
        exc = ConnectionRefusedError(61, "Connection refused")
        msg = mon.connection_error_message(8801, exc)
        self.assertIn("nothing is listening on 127.0.0.1:8801", msg)
        self.assertIn("no monitored build is running", msg)

    def test_refused_wrapped_in_urlerror(self):
        # The form actually observed from urllib in practice for a refused
        # connection, depending on Python version/platform.
        exc = urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))
        msg = mon.connection_error_message(8801, exc)
        self.assertIn("nothing is listening", msg)

    def test_reset_bare(self):
        exc = ConnectionResetError(54, "Connection reset by peer")
        msg = mon.connection_error_message(8801, exc)
        self.assertIn("reset the connection", msg)
        self.assertIn("did not come up", msg)
        self.assertNotIn("nothing is listening", msg)

    def test_reset_wrapped_in_urlerror(self):
        exc = urllib.error.URLError(ConnectionResetError(54, "Connection reset by peer"))
        msg = mon.connection_error_message(8801, exc)
        self.assertIn("reset the connection", msg)

    def test_timeout(self):
        msg = mon.connection_error_message(8801, TimeoutError("timed out"))
        self.assertIn("did not respond within", msg)

    def test_unknown_falls_back_to_generic_message(self):
        # Anything not one of the three known shapes must still say SOMETHING
        # useful rather than raise -- the fallback is the old message.
        msg = mon.connection_error_message(8801, OSError(9, "Bad file descriptor"))
        self.assertIn("could not reach the bridge", msg)


class FormatElapsedTest(unittest.TestCase):
    def test_seconds_only(self):
        self.assertEqual(mon._format_elapsed(5), "0:05")

    def test_minutes_and_seconds(self):
        self.assertEqual(mon._format_elapsed(125), "2:05")

    def test_hours_boundary(self):
        self.assertEqual(mon._format_elapsed(3599), "59:59")
        self.assertEqual(mon._format_elapsed(3600), "1:00:00")

    def test_negative_clamped_to_zero(self):
        # ctx["started_at"] is set from time.monotonic() at first observation;
        # a clock oddity should never print a negative elapsed time.
        self.assertEqual(mon._format_elapsed(-1), "0:00")


class RenderTest(unittest.TestCase):
    def _render(self, state, ctx):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mon.render(state, ctx)
        return buf.getvalue()

    def _ctx(self, is_tty=False):
        ctx = mon.new_render_context()
        ctx["is_tty"] = is_tty
        return ctx

    def test_idle_prints_words_not_0_0_dashes(self):
        ctx = self._ctx()
        out = self._render({"status": "idle"}, ctx)
        self.assertIn("waiting for the build to start", out)
        self.assertNotIn("0/0", out)

    def test_core_substring_unchanged_for_existing_consumers(self):
        # The exact shape mackas's own bats suite (and anyone else parsing
        # this) greps for. New info must be appended, never inserted into it.
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
        }
        out = self._render(state, ctx)
        self.assertIn("[building] 3/10  busybox:do_compile", out)

    def test_percent_appended_after_the_core_shape(self):
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
        }
        out = self._render(state, ctx)
        self.assertIn("[building] 3/10  busybox:do_compile", out)
        idx_core = out.index("busybox:do_compile")
        idx_pct = out.index("30%")
        self.assertGreater(idx_pct, idx_core)

    def test_no_percent_when_total_is_zero(self):
        # The parse phase reports a done count with no total yet -- must not
        # divide by zero or print a bogus percentage.
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": None, "task": None},
            "progress": {"done": 12, "total": 0},
        }
        out = self._render(state, ctx)
        self.assertIn("12/0", out)
        self.assertNotIn("%", out)

    def test_elapsed_appears_once_a_build_has_started(self):
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 1, "total": 10},
        }
        out = self._render(state, ctx)
        self.assertIn("0:00", out)

    def test_failed_count_surfaces_while_still_building(self):
        # Finding 4: under -k, a failure used to be invisible until the very
        # end. failed_count is in every payload; show it as it happens.
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": "zlib", "task": "do_compile"},
            "progress": {"done": 5, "total": 10},
            "failed_count": 2,
        }
        out = self._render(state, ctx)
        self.assertIn("2 failed so far", out)

    def test_no_failed_note_when_nothing_has_failed(self):
        ctx = self._ctx()
        state = {
            "status": "building",
            "current": {"recipe": "zlib", "task": "do_compile"},
            "progress": {"done": 5, "total": 10},
            "failed_count": 0,
        }
        out = self._render(state, ctx)
        self.assertNotIn("failed", out)

    def test_header_prints_once_not_on_every_poll(self):
        ctx = self._ctx()
        state = {
            "status": "building",
            "targets": ["core-image-base"],
            "machine": "beaglebone",
            "distro": "angstrom",
            "current": {"recipe": "busybox", "task": "do_fetch"},
            "progress": {"done": 1, "total": 10},
        }
        first = self._render(state, ctx)
        state2 = dict(state, current={"recipe": "busybox", "task": "do_compile"},
                      progress={"done": 2, "total": 10})
        second = self._render(state2, ctx)
        self.assertIn("core-image-base", first)
        self.assertIn("beaglebone/angstrom", first)
        self.assertNotIn("core-image-base", second)

    def test_no_header_when_idle(self):
        ctx = self._ctx()
        state = {"status": "idle", "targets": ["core-image-base"]}
        out = self._render(state, ctx)
        self.assertNotIn("core-image-base", out)

    def test_non_tty_dedups_an_unchanged_line(self):
        # A ~2s poll over a long build repeats the same payload far more
        # often than it changes; printing every poll is the scroll-blur
        # finding 4 exists to fix, on redirected output as much as a tty.
        ctx = self._ctx(is_tty=False)
        state = {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
        }
        first = self._render(state, ctx)
        second = self._render(dict(state), ctx)
        self.assertNotEqual(first, "")
        self.assertEqual(second, "")

    def test_non_tty_prints_a_genuinely_changed_line(self):
        ctx = self._ctx(is_tty=False)
        state = {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
        }
        self._render(state, ctx)
        state2 = dict(state, progress={"done": 4, "total": 10})
        second = self._render(state2, ctx)
        self.assertIn("4/10", second)


class TaskProgressRenderTest(unittest.TestCase):
    """The `task_progress` field -- progress from INSIDE a running task,
    which the build-wide counter structurally cannot show (a task is
    indivisible to it, so one large do_compile holds it still for tens of
    minutes). Same appended-never-inserted rule as percent/elapsed."""

    def _render(self, state, ctx):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mon.render(state, ctx)
        return buf.getvalue()

    def _ctx(self):
        ctx = mon.new_render_context()
        ctx["is_tty"] = False
        return ctx

    @staticmethod
    def _state(entries):
        return {
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
            "task_progress": entries,
        }

    def test_nothing_rendered_when_no_task_reports_progress(self):
        self.assertEqual(mon.describe_task_progress({"task_progress": []}), "")
        self.assertEqual(mon.describe_task_progress({}), "")

    def test_a_reporting_task_names_itself_and_its_percent(self):
        got = mon.describe_task_progress({"task_progress": [
            {"recipe": "systemd_257.bb", "task": "do_compile",
             "percent": 42, "rate": None},
        ]})
        self.assertEqual(got, "systemd_257.bb:do_compile 42%")

    def test_a_rate_is_shown_when_the_producer_has_one(self):
        got = mon.describe_task_progress({"task_progress": [
            {"recipe": "zlib_1.3.bb", "task": "do_fetch",
             "percent": 30, "rate": "1.2M/s"},
        ]})
        self.assertEqual(got, "zlib_1.3.bb:do_fetch 30% at 1.2M/s")

    def test_an_unknown_percent_reads_as_busy_not_as_a_number(self):
        # bitbake's negative progress ("happening, amount unknown") reaches
        # the bridge as null. Printing "0%" for it would read as stalled.
        got = mon.describe_task_progress({"task_progress": [
            {"recipe": "linux-yocto_6.6.bb", "task": "do_fetch",
             "percent": None, "rate": None},
        ]})
        self.assertEqual(got, "linux-yocto_6.6.bb:do_fetch busy")

    def test_a_boolean_percent_is_not_rendered_as_a_number(self):
        # bool is an int subclass; a schema surprise must not print "1%".
        got = mon.describe_task_progress({"task_progress": [
            {"recipe": "a_1.0.bb", "task": "do_compile", "percent": True},
        ]})
        self.assertEqual(got, "a_1.0.bb:do_compile busy")

    def test_a_missing_recipe_or_task_is_marked_not_dropped(self):
        got = mon.describe_task_progress({"task_progress": [
            {"percent": 5},
        ]})
        self.assertEqual(got, "?:? 5%")

    def test_two_tasks_are_both_named(self):
        got = mon.describe_task_progress({"task_progress": [
            {"recipe": "a_1.0.bb", "task": "do_compile", "percent": 10},
            {"recipe": "b_2.0.bb", "task": "do_compile", "percent": 90},
        ]})
        self.assertEqual(got, "a_1.0.bb:do_compile 10%, b_2.0.bb:do_compile 90%")

    def test_more_than_the_cap_collapses_into_a_count(self):
        entries = [{"recipe": f"p{i}.bb", "task": "do_compile", "percent": i}
                   for i in range(5)]
        got = mon.describe_task_progress({"task_progress": entries})
        self.assertTrue(got.endswith("+3 more"), got)
        self.assertIn("p0.bb:do_compile 0%", got)
        self.assertNotIn("p4.bb", got)

    def test_a_non_dict_entry_is_skipped_not_fatal(self):
        got = mon.describe_task_progress({"task_progress": [
            "nonsense",
            {"recipe": "a_1.0.bb", "task": "do_compile", "percent": 7},
        ]})
        self.assertEqual(got, "a_1.0.bb:do_compile 7%")

    def test_it_is_appended_after_the_fixed_core_shape(self):
        ctx = self._ctx()
        out = self._render(self._state([
            {"recipe": "systemd_257.bb", "task": "do_compile", "percent": 42},
        ]), ctx)
        self.assertIn("[building] 3/10  busybox:do_compile", out)
        self.assertGreater(out.index("systemd_257.bb:do_compile 42%"),
                            out.index("busybox:do_compile"))

    def test_the_line_is_unchanged_when_the_field_is_absent(self):
        # Additive: a bridge that does not serve task_progress (an older one,
        # or a build where nothing reports) renders exactly as before.
        ctx = self._ctx()
        without = self._render({
            "status": "building",
            "current": {"recipe": "busybox", "task": "do_compile"},
            "progress": {"done": 3, "total": 10},
        }, ctx)
        empty = self._render(self._state([]), self._ctx())
        self.assertEqual(without.strip(), empty.strip())
        # Not even an empty pair of brackets: nothing to say means say
        # nothing, the same rule the notification bodies follow.
        self.assertNotIn("()", without)

    def test_it_precedes_the_failed_count(self):
        ctx = self._ctx()
        state = dict(self._state([
            {"recipe": "systemd_257.bb", "task": "do_compile", "percent": 42},
        ]), failed_count=2)
        out = self._render(state, ctx)
        self.assertLess(out.index("systemd_257.bb"), out.index("2 failed so far"))


# ---------------------------------------------------------------------------
# Routing around Apple container's resetting port-forward (issue #49)
# ---------------------------------------------------------------------------

# `container ls`, verbatim in shape: a header line the ID walk must drop, then
# one running container per line with the ID first.
LS_OUTPUT = (
    "ID                                    IMAGE                        "
    "OS     ARCH   STATE    IP                CPUS  MEMORY    STARTED\n"
    "4aa8f7c0-b73a-4d45-9326-f643a122cd0b  ghcr.io/siemens/kas/kas:5.4  "
    "linux  arm64  running  192.168.64.76/24  18    43008 MB  "
    "2026-08-12T07:31:56Z\n"
)

BRIDGE_JSON = json.dumps({
    "status": "building",
    "targets": ["trmnl-image"],
    "machine": "qemuarm64",
    "distro": "angstrom",
    "current": {"recipe": "busybox", "task": "do_compile"},
    "progress": {"done": 3, "total": 10},
    "failed_tasks": [],
    "recent_events": [],
})


def inspect_payload(host_port=8801, container_port=8801, ip="192.168.64.76/24",
                    state="running", proto="tcp"):
    """One `container inspect` entry, in the real shape: a LIST of objects,
    publishedPorts under "configuration", the address under "status" and
    carrying its prefix length."""
    return json.dumps([{
        "configuration": {
            "id": "4aa8f7c0-b73a-4d45-9326-f643a122cd0b",
            "image": {"reference": "ghcr.io/siemens/kas/kas:5.4"},
            "publishedPorts": [{
                "containerPort": container_port,
                "count": 1,
                "hostAddress": "0.0.0.0",
                "hostPort": host_port,
                "proto": proto,
            }],
            "publishedSockets": [],
        },
        "id": "4aa8f7c0-b73a-4d45-9326-f643a122cd0b",
        "status": {
            "networks": [{
                "hostname": "4aa8f7c0-b73a-4d45-9326-f643a122cd0b",
                "ipv4Address": ip,
                "ipv4Gateway": "192.168.64.1",
                "ipv6Address": "fd6f:7b4a:6b24:14ee:fc58:8ff:fea8:aa1/64",
                "network": "default",
            }],
            "state": state,
        },
    }])


class _FakeProc:
    def __init__(self, stdout=b"", returncode=0):
        self.stdout = stdout
        self.returncode = returncode


def fake_container(ls=LS_OUTPUT, inspect=None, ls_rc=0, inspect_rc=0):
    """A subprocess.run stand-in answering the two calls the resolver makes.
    Anything else is a bug in the resolver, not something to answer."""
    def run(argv, **kwargs):
        if argv[1] == "ls":
            return _FakeProc(ls.encode(), ls_rc)
        if argv[1] == "inspect":
            body = inspect if inspect is not None else inspect_payload()
            return _FakeProc(body.encode(), inspect_rc)
        raise AssertionError("unexpected container call: %r" % (argv,))
    return run


class _FakeResponse:
    def __init__(self, body):
        self._body = body.encode()

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class DirectEndpointTest(unittest.TestCase):
    """The shape questions, answered against the real inspect payload."""

    def _entry(self, **kw):
        return json.loads(inspect_payload(**kw))[0]

    def test_ipv4_address_prefix_length_is_stripped(self):
        # "192.168.64.76/24" is not something urlopen can be handed.
        self.assertEqual(mon._ipv4_of(self._entry()), "192.168.64.76")

    def test_matching_published_port_gives_ip_and_port(self):
        self.assertEqual(
            mon._direct_endpoint(self._entry(), 8801), ("192.168.64.76", 8801)
        )

    def test_a_different_published_port_does_not_match(self):
        self.assertIsNone(mon._direct_endpoint(self._entry(host_port=9999), 8801))

    def test_host_port_maps_to_the_container_port(self):
        # Going direct bypasses the forward, so -p 9999:8801 must be polled
        # on 8801, not on the host port the user named.
        self.assertEqual(
            mon._direct_endpoint(self._entry(host_port=9999, container_port=8801), 9999),
            ("192.168.64.76", 8801),
        )

    def test_non_tcp_publication_is_ignored(self):
        self.assertIsNone(mon._direct_endpoint(self._entry(proto="udp"), 8801))

    def test_a_container_that_is_not_running_is_skipped(self):
        self.assertIsNone(mon._direct_endpoint(self._entry(state="stopped"), 8801))

    def test_no_address_yet_is_not_an_endpoint(self):
        self.assertIsNone(mon._direct_endpoint(self._entry(ip=""), 8801))

    def test_ids_come_from_the_first_column_without_the_header(self):
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run", side_effect=fake_container()):
            self.assertEqual(
                mon._running_container_ids(),
                ["4aa8f7c0-b73a-4d45-9326-f643a122cd0b"],
            )

    def test_missing_container_cli_resolves_to_nothing(self):
        with mock.patch.object(mon.shutil, "which", return_value=None), \
                mock.patch.object(mon.subprocess, "run") as run:
            self.assertIsNone(mon.resolve_direct_endpoint(8801))
        run.assert_not_called()

    def test_a_failing_container_ls_resolves_to_nothing(self):
        # Daemon down: `container ls` exits non-zero, which is an absence of
        # an answer, not something to crash or report on its own.
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run",
                                  side_effect=fake_container(ls_rc=1)):
            self.assertIsNone(mon.resolve_direct_endpoint(8801))

    def test_unparseable_inspect_output_resolves_to_nothing(self):
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run",
                                  side_effect=fake_container(inspect="not json")):
            self.assertIsNone(mon.resolve_direct_endpoint(8801))

    def test_a_container_that_exits_mid_walk_resolves_to_nothing(self):
        # `container inspect` on an ID that has since gone away exits non-zero.
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run",
                                  side_effect=fake_container(inspect_rc=1)):
            self.assertIsNone(mon.resolve_direct_endpoint(8801))

    def test_a_container_query_that_hangs_resolves_to_nothing(self):
        boom = mon.subprocess.TimeoutExpired(cmd="container", timeout=5.0)
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run", side_effect=boom):
            self.assertIsNone(mon.resolve_direct_endpoint(8801))


class PollLoopFallbackTest(unittest.TestCase):
    """main()'s use of it: only a reset asks the runtime, only once, and a
    resolution that fails leaves the existing message exactly as it was."""

    def _main(self, urlopen, run=None, which="/usr/bin/container", port=8801):
        out, err = io.StringIO(), io.StringIO()
        run = run if run is not None else mock.Mock(
            side_effect=AssertionError("the runtime must not be queried here")
        )
        with mock.patch.object(mon.urllib.request, "urlopen", urlopen), \
                mock.patch.object(mon.shutil, "which", return_value=which), \
                mock.patch.object(mon.subprocess, "run", run) as patched, \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mon.main(["--port", str(port), "--once"])
        return rc, out.getvalue(), err.getvalue(), patched

    def test_a_working_loopback_poll_never_queries_the_runtime(self):
        # The fast path: no extra subprocess, no extra latency, nothing new.
        urlopen = mock.Mock(return_value=_FakeResponse(BRIDGE_JSON))
        rc, out, err, run = self._main(urlopen)
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertIn("[building] 3/10  busybox:do_compile", out)
        run.assert_not_called()
        self.assertEqual(urlopen.call_args[0][0], "http://127.0.0.1:8801/")
        self.assertEqual(err, "")

    def test_a_reset_is_retried_against_the_container_address(self):
        urlopen = mock.Mock(side_effect=[
            ConnectionResetError(54, "Connection reset by peer"),
            _FakeResponse(BRIDGE_JSON),
        ])
        rc, out, err, _ = self._main(urlopen, run=mock.Mock(side_effect=fake_container()))
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertEqual(
            urlopen.call_args_list[1][0][0], "http://192.168.64.76:8801/"
        )
        self.assertIn("[building] 3/10  busybox:do_compile", out)
        # The switch is announced, on stderr, so it never lands in the
        # progress output a script may be parsing.
        self.assertIn("192.168.64.76:8801", err)
        self.assertNotIn("192.168.64.76", out)

    def test_a_reset_with_no_matching_container_keeps_todays_message(self):
        # Nothing publishes this port: the fourth path cannot help, so the
        # reset message is what the user gets, unchanged.
        urlopen = mock.Mock(side_effect=ConnectionResetError(54, "reset"))
        rc, _, err, _ = self._main(
            urlopen, run=mock.Mock(side_effect=fake_container(
                inspect=inspect_payload(host_port=9999))))
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("something is publishing 127.0.0.1:8801", err)
        self.assertIn("reset the connection", err)
        self.assertNotIn("polling the container directly", err)

    def test_a_reset_with_no_container_runtime_at_all_keeps_todays_message(self):
        urlopen = mock.Mock(side_effect=ConnectionResetError(54, "reset"))
        rc, _, err, run = self._main(urlopen, run=mock.Mock(), which=None)
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("reset the connection", err)
        run.assert_not_called()

    def test_refused_never_queries_the_runtime(self):
        # Nothing is listening at all -- an address the runtime cannot know
        # any better than the socket already does.
        urlopen = mock.Mock(side_effect=ConnectionRefusedError(61, "refused"))
        rc, _, err, run = self._main(urlopen)
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("nothing is listening on 127.0.0.1:8801", err)
        run.assert_not_called()

    def test_timeout_never_queries_the_runtime(self):
        urlopen = mock.Mock(side_effect=TimeoutError("timed out"))
        rc, _, err, run = self._main(urlopen)
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("did not respond within", err)
        run.assert_not_called()

    def test_a_reset_wrapped_in_urlerror_is_still_retried(self):
        # urllib raises the reset either bare or wrapped, depending on where
        # in the stack it lands; both must reach the fallback.
        urlopen = mock.Mock(side_effect=[
            urllib.error.URLError(ConnectionResetError(54, "reset")),
            _FakeResponse(BRIDGE_JSON),
        ])
        rc, _, err, _ = self._main(urlopen, run=mock.Mock(side_effect=fake_container()))
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertIn("192.168.64.76:8801", err)

    def test_the_container_address_is_reported_when_it_fails_too(self):
        # Once the poll has moved, the error names where it actually looked;
        # blaming 127.0.0.1 for a container-address failure would send the
        # reader back to the wrong place. Also pins that the runtime is asked
        # at most once, so a bridge resetting on both addresses terminates.
        urlopen = mock.Mock(side_effect=[
            ConnectionResetError(54, "reset"),
            ConnectionResetError(54, "reset"),
        ])
        run = mock.Mock(side_effect=fake_container())
        rc, _, err, _ = self._main(urlopen, run=run)
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("something is publishing 192.168.64.76:8801", err)
        ls_calls = [c for c in run.call_args_list if c[0][0][1] == "ls"]
        self.assertEqual(len(ls_calls), 1)

    def test_the_original_host_port_is_what_gets_resolved(self):
        # --port names the HOST port; the lookup must match on that, and then
        # poll the container port behind it.
        urlopen = mock.Mock(side_effect=[
            ConnectionResetError(54, "reset"),
            _FakeResponse(BRIDGE_JSON),
        ])
        run = mock.Mock(side_effect=fake_container(
            inspect=inspect_payload(host_port=9999, container_port=8801)))
        rc, _, _, _ = self._main(urlopen, run=run, port=9999)
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertEqual(
            urlopen.call_args_list[1][0][0], "http://192.168.64.76:8801/"
        )


class WaitForStartTest(unittest.TestCase):
    """--wait-for-start: tolerate the bridge not being up yet, but only
    before the first successful fetch -- issue R1 from the monitor UX
    review. time.monotonic is a deterministic counter (each call advances
    by 1) and time.sleep is a no-op, so a "wait N seconds" test costs
    nothing real."""

    def _main(self, urlopen, argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(mon.urllib.request, "urlopen", urlopen), \
                mock.patch.object(mon.time, "monotonic", side_effect=itertools.count()), \
                mock.patch.object(mon.time, "sleep"), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mon.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_default_is_unchanged_fail_on_the_first_poll(self):
        # No --wait-for-start at all: today's behavior, byte for byte.
        urlopen = mock.Mock(side_effect=ConnectionRefusedError(61, "refused"))
        rc, _, err = self._main(urlopen, ["--port", "8801", "--once"])
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertEqual(urlopen.call_count, 1)
        self.assertNotIn("waiting up to", err)

    def test_retries_until_the_bridge_answers_within_the_grace(self):
        urlopen = mock.Mock(side_effect=[
            ConnectionRefusedError(61, "refused"),
            ConnectionRefusedError(61, "refused"),
            _FakeResponse(BRIDGE_JSON),
        ])
        rc, out, err = self._main(
            urlopen, ["--port", "8801", "--once", "--wait-for-start", "10"]
        )
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertEqual(urlopen.call_count, 3)
        self.assertIn("[building] 3/10  busybox:do_compile", out)
        # The "still waiting" notice prints, but once, not per retry.
        self.assertEqual(err.count("waiting up to 10s"), 1)

    def test_gives_up_once_the_grace_deadline_passes(self):
        urlopen = mock.Mock(side_effect=ConnectionRefusedError(61, "refused"))
        rc, _, err = self._main(
            urlopen, ["--port", "8801", "--once", "--wait-for-start", "3"]
        )
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertIn("nothing is listening on 127.0.0.1:8801", err)
        # It genuinely retried (more than the single bare-default attempt)
        # before giving up -- the grace was not simply ignored.
        self.assertGreater(urlopen.call_count, 1)

    def test_grace_does_not_apply_after_a_successful_connection(self):
        # A bridge that answers once and then goes away mid-build is a real
        # failure, not a startup race -- must not be retried under the same
        # grace, even with plenty of it left.
        urlopen = mock.Mock(side_effect=[
            _FakeResponse(BRIDGE_JSON),  # first poll: a real, non-terminal read
            ConnectionRefusedError(61, "refused"),  # then it's gone
        ])
        rc, _, err = self._main(
            urlopen, ["--port", "8801", "--wait-for-start", "60"]
        )
        self.assertEqual(rc, mon.EXIT_UNREACHABLE)
        self.assertEqual(urlopen.call_count, 2)
        self.assertIn("nothing is listening", err)

    def test_a_reset_still_tries_the_container_address_before_waiting(self):
        # The existing reset-resolution fallback stays the first thing
        # tried; the startup grace is what happens when THAT can't help
        # either, not a replacement for it.
        urlopen = mock.Mock(side_effect=[
            ConnectionResetError(54, "reset"),
            _FakeResponse(BRIDGE_JSON),
        ])
        run = mock.Mock(side_effect=fake_container())
        with mock.patch.object(mon.shutil, "which", return_value="/usr/bin/container"), \
                mock.patch.object(mon.subprocess, "run", run):
            rc, _, err = self._main(
                urlopen, ["--port", "8801", "--once", "--wait-for-start", "10"]
            )
        self.assertEqual(rc, mon.EXIT_OK)
        self.assertIn("192.168.64.76:8801", err)
        self.assertNotIn("waiting up to", err)


if __name__ == "__main__":
    unittest.main()
