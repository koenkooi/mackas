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

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import unittest
import urllib.error

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


if __name__ == "__main__":
    unittest.main()
