#!/usr/bin/env python3
#
# Tests for tools/mackas-overhead.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stdlib only (unittest), to match the sampler's own no-dependencies rule and
# the rest of the Python suite. tools/mackas-overhead is a 400-line script with
# no tests; the four things below are the ones a naive rewrite gets wrong:
#
#   * parse_cputime  -- the ONLY honest CPU signal on macOS (ps -o time), and
#     it has four wire formats. Get the day/hour arithmetic wrong and every
#     host figure is silently off.
#   * Sampler.summary -- docs/testing.md promises the sampler prints
#     "UNAVAILABLE rather than a fabricated number" when the host window did
#     not cover a real build. That promise is a mismatch guard; pin it.
#   * snapshot       -- self-exclusion (the sampler must not count its own
#     grep-y match), the KiB->bytes conversion, and the friendly_label order
#     (the VM's XPC label must win over its container-runtime-linux parent).
#   * main's exit status -- a run that matched no host process, and a
#     --buildstats comparison that could not be made, both print zeros that
#     read exactly like a real measurement; only the exit code tells them
#     apart.
#
# None of this runs `ps` or `container`: subprocess.run is monkeypatched with
# canned output, and the Sampler is built by hand.

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
OVERHEAD = os.path.join(HERE, os.pardir, "tools", "mackas-overhead")


def load_overhead():
    # The sampler has no .py extension (it is an installed tool), so import it
    # by path via SourceFileLoader. __name__ is "mackas_overhead", not
    # "__main__", so main() does not run on import.
    loader = importlib.machinery.SourceFileLoader("mackas_overhead", OVERHEAD)
    spec = importlib.util.spec_from_loader("mackas_overhead", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


oh = load_overhead()


class ParseCputimeTest(unittest.TestCase):
    """ps -o time= comes in four shapes; the arithmetic between them is the
    whole point of the function."""

    def test_seconds_only(self):
        self.assertAlmostEqual(oh.parse_cputime("5.10"), 5.10)

    def test_minutes_and_seconds(self):
        self.assertAlmostEqual(oh.parse_cputime("1:02.5"), 62.5)

    def test_hours_minutes_seconds(self):
        self.assertAlmostEqual(oh.parse_cputime("1:02:03"), 3723.0)

    def test_days_hours_minutes_seconds(self):
        # 2 days + 1 h + 3 s = 172800 + 3600 + 3 = 176403.
        self.assertAlmostEqual(oh.parse_cputime("2-01:00:03"), 176403.0)

    def test_a_full_day_alone(self):
        self.assertAlmostEqual(oh.parse_cputime("1-00:00:00"), 86400.0)

    def test_surrounding_whitespace_is_tolerated(self):
        self.assertAlmostEqual(oh.parse_cputime("  1:02:03 "), 3723.0)


# One canned `ps -axo pid=,rss=,time=,comm=,args=` block. Columns are:
#   pid  rss(KiB)  time  comm  args...
_PS_OUTPUT = "\n".join([
    # The VM: its args carry BOTH its container-runtime-linux parent's job
    # label AND the Virtualization.framework XPC label. The VM label must win.
    "  501 1048576 01:02.5 com.apple.Virtua "
    "/usr/libexec/xpcproxy "
    "com.apple.container.container-runtime-linux.ABC-123 "
    "com.apple.Virtualization.VirtualMachine",
    # The per-run supervisor: only the runtime-linux needle.
    "  601    2048 00:10.0 launchd "
    "/usr/libexec/launchd com.apple.container.container-runtime-linux.XYZ-9",
    # The sampler's OWN process. It matches the pattern (its argv names the
    # pattern) but must be excluded: it is a grep-y match on this very script.
    "  701     512 00:05.0 python3.9 "
    "/usr/bin/python3 /opt/mackas/tools/mackas-overhead "
    "--pattern container-runtime-linux --interval 5",
    # An unrelated process that does not match the pattern at all.
    "  999     128 00:01.0 Finder /System/Library/CoreServices/Finder.app/Finder",
]) + "\n"


class _FakeRun:
    def __init__(self, stdout):
        self.stdout = stdout


class SnapshotTest(unittest.TestCase):
    def _snapshot(self):
        with mock.patch.object(oh.subprocess, "run",
                               return_value=_FakeRun(_PS_OUTPUT)) as run:
            procs = oh.snapshot(oh.DEFAULT_PATTERN)
        # It must ask ps for cumulative time, never %cpu (a lifetime average).
        argv = run.call_args[0][0]
        self.assertIn("ps", argv[0])
        self.assertTrue(any("time=" in a for a in argv),
                        "snapshot must read ps -o time= (cumulative), not %cpu")
        return procs

    def test_self_is_excluded(self):
        procs = self._snapshot()
        self.assertNotIn(701, procs,
                         "the sampler must not count its own process")

    def test_non_matching_process_is_skipped(self):
        procs = self._snapshot()
        self.assertNotIn(999, procs)

    def test_matched_process_set(self):
        procs = self._snapshot()
        self.assertEqual({501, 601}, set(procs))

    def test_rss_is_converted_from_kib_to_bytes(self):
        procs = self._snapshot()
        # 1048576 KiB * 1024 = 1073741824 bytes, NOT the raw KiB figure.
        self.assertEqual(procs[501]["rss"], 1048576 * 1024)
        self.assertEqual(procs[601]["rss"], 2048 * 1024)

    def test_cpu_time_is_parsed(self):
        procs = self._snapshot()
        self.assertAlmostEqual(procs[501]["cpu"], 62.5)   # 01:02.5
        self.assertAlmostEqual(procs[601]["cpu"], 10.0)   # 00:10.0

    def test_vm_label_wins_over_its_runtime_linux_parent(self):
        # The 501 line contains both needles. _LABELS lists the VM first, so
        # friendly_label must return the VM label, not the parent's.
        procs = self._snapshot()
        self.assertEqual(procs[501]["comm"], "VM (Virtualization.framework)")

    def test_runtime_linux_label(self):
        procs = self._snapshot()
        self.assertEqual(procs[601]["comm"], "container-runtime-linux")


class FriendlyLabelTest(unittest.TestCase):
    def test_vm_needle_in_args_beats_runtime_linux(self):
        # Ordering is stated in the source: VM first so it wins over its
        # runtime-linux parent's args.
        label = oh.friendly_label(
            "launchd",
            "com.apple.container.container-runtime-linux.X "
            "com.apple.Virtualization.VirtualMachine")
        self.assertEqual(label, "VM (Virtualization.framework)")

    def test_falls_back_to_basename_when_nothing_matches(self):
        self.assertEqual(oh.friendly_label("/usr/bin/Finder", "Finder"),
                         "Finder")


def make_sampler(first_cpu, last_cpu, t0, t1, comm=None):
    """Build a Sampler with a window already 'sampled', without touching ps."""
    s = oh.Sampler(pattern="x", interval=5)
    s.first_cpu = dict(first_cpu)
    s.last_cpu = dict(last_cpu)
    s.comm = comm or {p: "VM (Virtualization.framework)" for p in last_cpu}
    s.t0 = t0
    s.t1 = t1
    s.rss_series = [(t0, 2 * 2 ** 20)]
    s.n_samples = 2
    return s


class SummaryMismatchGuardTest(unittest.TestCase):
    """docs/testing.md: 'the sampler prints UNAVAILABLE rather than a fabricated
    number when a guest comparison is asked for but the host window did not
    cover a real build.' That promise lives in Sampler.summary; pin it."""

    GUEST = {"cpu_s": 60.0, "wall_s": 100.0, "write_gb": 0.0, "read_gb": 0.0,
             "n_tasks": 5}

    def test_host_saw_no_cpu_is_unavailable(self):
        # host_cpu_s = 0.4 < 1: no VM ran during the window.
        s = make_sampler({1: 5.0}, {1: 5.4}, t0=0.0, t1=300.0)
        out = s.summary(self.GUEST)
        self.assertIn("unavailable", out["overhead"])
        self.assertNotIn("host_cpu_minus_guest_cpu_s", out["overhead"])
        self.assertIn("~0 CPU-seconds", out["overhead"]["unavailable"])

    def test_host_window_far_shorter_than_guest_is_unavailable(self):
        # host_cpu_s = 50 (>=1), but wall 10s < 0.5 * 100s guest wall.
        s = make_sampler({1: 0.0}, {1: 50.0}, t0=1000.0, t1=1010.0)
        out = s.summary(self.GUEST)
        self.assertIn("unavailable", out["overhead"])
        self.assertNotIn("host_cpu_minus_guest_cpu_s", out["overhead"])
        self.assertIn("do not match", out["overhead"]["unavailable"])

    def test_matched_window_reports_the_difference(self):
        # host_cpu_s = 100, wall 300s >= 0.5*100s, guest cpu 60 -> overhead 40.
        s = make_sampler({1: 0.0}, {1: 100.0}, t0=1000.0, t1=1300.0)
        out = s.summary(self.GUEST)
        self.assertNotIn("unavailable", out["overhead"])
        self.assertAlmostEqual(
            out["overhead"]["host_cpu_minus_guest_cpu_s"], 40.0)
        self.assertAlmostEqual(out["overhead"]["ratio_host_over_guest"],
                               round(100.0 / 60.0, 3))
        self.assertAlmostEqual(out["overhead"]["pct_of_guest"],
                               round(100 * 40.0 / 60.0, 1))

    def test_host_cpu_seconds_is_a_sum_of_per_pid_deltas(self):
        # Two pids, each contributing a delta; the headline is their sum.
        s = make_sampler({1: 0.0, 2: 10.0}, {1: 30.0, 2: 40.0},
                         t0=0.0, t1=200.0,
                         comm={1: "VM (Virtualization.framework)",
                               2: "container-runtime-linux"})
        out = s.summary()
        # (30-0) + (40-10) = 60.
        self.assertAlmostEqual(out["host"]["cpu_s"], 60.0)
        self.assertNotIn("overhead", out)  # no guest -> no comparison

    def test_no_guest_means_no_overhead_key(self):
        s = make_sampler({1: 0.0}, {1: 100.0}, t0=0.0, t1=200.0)
        out = s.summary(None)
        self.assertNotIn("overhead", out)
        self.assertNotIn("guest", out)


_PS_NO_MATCH = (
    "  999     128 00:01.0 Finder /System/Library/CoreServices/Finder.app/Finder\n")


class MainExitStatusTest(unittest.TestCase):
    """A zeroed report is indistinguishable from a real measurement of an idle
    machine, so 'nothing matched' and 'the guest comparison you asked for could
    not be made' have to be exit codes, not just absent sections."""

    def _main(self, argv, ps=_PS_OUTPUT):
        out, err = io.StringIO(), io.StringIO()
        # Sampler.run() replaced by one sample: no sleeping, no signal timer.
        with mock.patch.object(oh.subprocess, "run",
                               return_value=_FakeRun(ps)), \
                mock.patch.object(oh.signal, "signal"), \
                mock.patch.object(oh.Sampler, "run",
                                  lambda self: self.sample_once()), \
                mock.patch.object(sys, "argv", ["mackas-overhead"] + argv), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = oh.main()
        return rc, out.getvalue(), err.getvalue()

    def test_dry_run_with_no_matching_processes_is_not_success(self):
        rc, out, _ = self._main(["--dry-run"], ps=_PS_NO_MATCH)
        self.assertEqual(rc, 2)
        self.assertIn("NO matching host processes", out)

    def test_dry_run_with_matches_reports_the_count(self):
        rc, out, _ = self._main(["--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("dry-run: 2 matching host processes", out)

    def test_a_window_that_matched_nothing_is_not_success(self):
        rc, _, err = self._main([], ps=_PS_NO_MATCH)
        self.assertEqual(rc, 2)
        self.assertIn("nothing was measured", err)

    def test_a_real_sample_set_succeeds_and_names_the_pid_count(self):
        rc, out, err = self._main([])
        self.assertEqual(rc, 0)
        self.assertIn("matched pids=2", out)
        self.assertEqual(err, "")

    def test_an_unusable_buildstats_dir_is_not_success(self):
        rc, _, err = self._main(["--buildstats", os.path.join(HERE, "nope")])
        self.assertEqual(rc, 2)
        self.assertIn("no guest comparison was made", err)


if __name__ == "__main__":
    unittest.main()
