#!/usr/bin/env python3
#
# Tests for tools/mackas-buildstats-analyze.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stdlib only (unittest), to match the analyzer's own no-dependencies rule and
# the mirror-server suite. The point of these is the ONE property the analyzer
# exists to get right and that a naive implementation gets wrong: a task's CPU
# time must include its *child* rusage. do_compile's real work happens in forked
# children (make, cc1, ld); counting the bitbake worker's own rusage alone makes
# every compile look free.

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZER = os.path.join(HERE, os.pardir, "tools", "mackas-buildstats-analyze")
OVERHEAD = os.path.join(HERE, os.pardir, "tools", "mackas-overhead")


def _load(name, path):
    # These tools have no .py extension (they are installed tools), so import
    # them by path via SourceFileLoader.
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def load_analyzer():
    return _load("bsanalyze", ANALYZER)


bs = load_analyzer()
# The overhead sampler carries a SECOND copy of the child-rusage CPU rule
# (guest_cpu_seconds); the drift guard below pins the two implementations
# against each other.
oh = _load("mackas_overhead", OVERHEAD)


TASK_WITH_CHILD = """\
Event: TaskStarted
Started: 1000.00
rusage ru_utime: 0.05
rusage ru_stime: 0.05
rusage ru_maxrss: 2048
Child rusage ru_utime: 120.00
Child rusage ru_stime: 30.00
Child rusage ru_maxrss: 500000
IO read_bytes: 1048576
IO write_bytes: 2097152
Ended: 1030.00
Status: PASSED
"""

TASK_NO_CHILD = """\
Event: TaskStarted
Started: 2000.00
rusage ru_utime: 1.00
rusage ru_stime: 0.50
Ended: 2002.00
Status: PASSED
"""


def write_buildstats(root, tasks):
    """tasks: {recipe: {taskname: contents}}. Returns the BUILDNAME dir."""
    bsdir = os.path.join(root, "buildstats", "20260717121723")
    os.makedirs(bsdir)
    with open(os.path.join(bsdir, "build_stats"), "w") as fh:
        fh.write("Build Started: 1000.00\n")
        fh.write("Elapsed time: 42.00 seconds\n")
        fh.write("CPU usage: 55.5%\n")
    for recipe, taskfiles in tasks.items():
        rdir = os.path.join(bsdir, recipe)
        os.makedirs(rdir)
        for name, contents in taskfiles.items():
            with open(os.path.join(rdir, name), "w") as fh:
                fh.write(contents)
    return bsdir


class ChildRusageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_parse_task_keeps_own_and_child_rusage_apart(self):
        with tempfile.NamedTemporaryFile("w", suffix=".task", delete=False) as fh:
            fh.write(TASK_WITH_CHILD)
            path = fh.name
        try:
            t = bs.parse_task(path)
        finally:
            os.unlink(path)
        # Own rusage under r_*, child rusage under c_*.
        self.assertAlmostEqual(t["r_ru_utime"], 0.05)
        self.assertAlmostEqual(t["r_ru_stime"], 0.05)
        self.assertAlmostEqual(t["c_ru_utime"], 120.00)
        self.assertAlmostEqual(t["c_ru_stime"], 30.00)

    def test_cpu_includes_child_rusage(self):
        bsdir = write_buildstats(self.tmp, {"busybox": {"do_compile": TASK_WITH_CHILD}})
        tasks = bs.collect_tasks(bsdir)
        self.assertEqual(len(tasks), 1)
        # 0.05 + 0.05 + 120.00 + 30.00 = 150.1, NOT 0.1 (own rusage only).
        self.assertAlmostEqual(tasks[0]["cpu"], 150.1, places=3)

    def test_child_rusage_dominates_a_real_build_total(self):
        bsdir = write_buildstats(self.tmp, {
            "busybox": {"do_compile": TASK_WITH_CHILD},
            "quilt-native": {"do_configure": TASK_NO_CHILD},
        })
        rep = bs.analyze(bsdir)
        # 150.1 (with child) + 1.5 (without) = 151.6.
        self.assertAlmostEqual(rep["build"]["cpu_s"], 151.6, places=1)
        # If child rusage were dropped, do_compile would contribute 0.1 and the
        # total would be 1.6 -- guard against exactly that regression.
        self.assertGreater(rep["build"]["cpu_s"], 100.0)

    def test_maxrss_takes_the_larger_of_own_and_child(self):
        bsdir = write_buildstats(self.tmp, {"busybox": {"do_compile": TASK_WITH_CHILD}})
        tasks = bs.collect_tasks(bsdir)
        # child ru_maxrss (500000) beats own (2048).
        self.assertEqual(tasks[0]["maxrss_kb"], 500000)

    def test_truncated_task_file_does_not_sink_the_report(self):
        # A build killed mid-task leaves a file with no Ended: line. It must be
        # skipped, not crash the parse.
        truncated = "Event: TaskStarted\nStarted: 3000.00\nrusage ru_utime: 5.0\n"
        bsdir = write_buildstats(self.tmp, {
            "busybox": {"do_compile": TASK_WITH_CHILD},
            "halfbaked": {"do_compile": truncated},
        })
        rep = bs.analyze(bsdir)
        self.assertEqual(rep["build"]["n_tasks"], 1)
        self.assertAlmostEqual(rep["build"]["cpu_s"], 150.1, places=1)


def task(started, ended, utime=0.0, stime=0.0, c_utime=0.0, c_stime=0.0,
         rbytes=0, wbytes=0, status="PASSED"):
    """A buildstats task file with fully-controlled fields."""
    lines = [
        "Event: TaskStarted",
        "Started: %.2f" % started,
        "rusage ru_utime: %s" % utime,
        "rusage ru_stime: %s" % stime,
    ]
    if c_utime or c_stime:
        lines += ["Child rusage ru_utime: %s" % c_utime,
                  "Child rusage ru_stime: %s" % c_stime]
    if rbytes:
        lines.append("IO read_bytes: %d" % rbytes)
    if wbytes:
        lines.append("IO write_bytes: %d" % wbytes)
    lines += ["Ended: %.2f" % ended, "Status: %s" % status]
    return "\n".join(lines) + "\n"


def write_named_build(root, buildname, tasks):
    """Write buildstats/<buildname>/ with a build_stats and the given tasks.
    Returns the buildstats parent dir (the one holding BUILDNAME dirs)."""
    parent = os.path.join(root, "buildstats")
    bsdir = os.path.join(parent, buildname)
    os.makedirs(bsdir)
    with open(os.path.join(bsdir, "build_stats"), "w") as fh:
        fh.write("Build Started: 1000.00\nElapsed time: 42.00 seconds\n")
    for recipe, taskfiles in tasks.items():
        rdir = os.path.join(bsdir, recipe)
        os.makedirs(rdir)
        for name, contents in taskfiles.items():
            with open(os.path.join(rdir, name), "w") as fh:
                fh.write(contents)
    return parent


class TmpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)


class ResolveBuildstatsDirTest(TmpTest):
    def test_newest_buildname_wins_lexically(self):
        # BUILDNAME is a timestamp, so lexical order is chronological and the
        # last one is the newest -- no stat() calls.
        one = task(1000, 1002, utime=1.0)
        parent = write_named_build(self.tmp, "20260101000000",
                                   {"old": {"do_compile": one}})
        write_named_build(self.tmp, "20260717121723",
                          {"new": {"do_compile": one}})
        got = bs.resolve_buildstats_dir(parent)
        self.assertEqual(got, os.path.join(parent, "20260717121723"))

    def test_buildname_dir_passed_directly_is_returned_as_is(self):
        parent = write_named_build(self.tmp, "20260717121723",
                                   {"r": {"do_compile": task(1000, 1002)}})
        bsdir = os.path.join(parent, "20260717121723")
        self.assertEqual(bs.resolve_buildstats_dir(bsdir), bsdir)

    def test_empty_dir_analyze_raises_valueerror(self):
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        resolved = bs.resolve_buildstats_dir(empty)
        # Pin the specific "no tasks" guard, not the min()-of-empty backstop
        # that would raise a different ValueError further down.
        with self.assertRaisesRegex(ValueError, "no parsable task"):
            bs.analyze(resolved)

    def test_empty_dir_via_main_exits_1_with_a_message(self):
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = bs.main([empty])
        self.assertEqual(rc, 1)
        # The guard's own words -- "buildstats" alone would match the tool's
        # name in the "mackas-buildstats-analyze: error:" prefix.
        self.assertIn("no parsable task", err.getvalue())


class ConcurrencyTest(TmpTest):
    def test_two_overlapping_tasks_give_peak_2(self):
        # A: [1000,1010]  B: [1005,1015]  -> overlap [1005,1010] -> peak 2.
        bsdir = write_buildstats(self.tmp, {
            "a": {"do_compile": task(1000, 1010, utime=1.0)},
            "b": {"do_compile": task(1005, 1015, utime=1.0)},
        })
        rep = bs.analyze(bsdir)
        self.assertEqual(rep["build"]["concurrency_peak"], 2)

    def test_two_disjoint_tasks_give_peak_1(self):
        # A: [1000,1002]  B: [1010,1012]  -> never overlap -> peak 1.
        bsdir = write_buildstats(self.tmp, {
            "a": {"do_compile": task(1000, 1002, utime=1.0)},
            "b": {"do_compile": task(1010, 1012, utime=1.0)},
        })
        rep = bs.analyze(bsdir)
        self.assertEqual(rep["build"]["concurrency_peak"], 1)


class IoBoundHeuristicTest(TmpTest):
    # io_bound: wall > 1  AND  cpu/wall < 0.3  AND  rbytes+wbytes > (1<<20).
    MB = 1 << 20

    def _count(self, t):
        bsdir = write_buildstats(self.tmp, {"r": {"do_unpack": t}})
        return bs.analyze(bsdir)["io_bound_count"]

    def test_just_over_the_threshold_counts(self):
        # wall 10, cpu 2.9 -> ratio 0.29 < 0.3; bytes 1 over 1 MiB.
        t = task(1000, 1010, utime=2.9, wbytes=self.MB + 1)
        self.assertEqual(self._count(t), 1)

    def test_ratio_exactly_at_threshold_does_not_count(self):
        # cpu 3.0 / wall 10 = 0.30, which is NOT < 0.3.
        t = task(1000, 1010, utime=3.0, wbytes=self.MB + 1)
        self.assertEqual(self._count(t), 0)

    def test_bytes_exactly_at_threshold_does_not_count(self):
        # rbytes+wbytes == 1 MiB exactly, which is NOT > 1 MiB.
        t = task(1000, 1010, utime=1.0, wbytes=self.MB)
        self.assertEqual(self._count(t), 0)

    def test_wall_at_or_below_1s_does_not_count(self):
        # wall == 1 is NOT > 1, so a fast task never qualifies however idle.
        t = task(1000, 1001, utime=0.0, wbytes=self.MB * 4)
        self.assertEqual(self._count(t), 0)


class ChildRusageDriftGuardTest(TmpTest):
    """tools/mackas-overhead's guest_cpu_seconds and mackas-buildstats-analyze
    both implement the child-rusage CPU rule ('else every compile looks free').
    Feed ONE fixture to both and pin them equal, so the two copies cannot drift
    apart silently."""

    def test_both_tools_agree_on_cpu_seconds(self):
        bsdir = write_buildstats(self.tmp, {
            "busybox": {"do_compile": TASK_WITH_CHILD},
            "quilt-native": {"do_configure": TASK_NO_CHILD},
        })
        analyzer_cpu = bs.analyze(bsdir)["build"]["cpu_s"]
        guest = oh.guest_cpu_seconds(bsdir)
        self.assertIsNotNone(guest)
        # 150.1 (own+child) + 1.5 = 151.6 from both, independently computed.
        self.assertAlmostEqual(analyzer_cpu, 151.6, places=1)
        self.assertAlmostEqual(guest["cpu_s"], analyzer_cpu, delta=0.05)

    def test_agreement_holds_with_only_child_rusage(self):
        # The case the naive implementation gets wrong: work entirely in the
        # forked child. Both must count it.
        bsdir = write_buildstats(self.tmp,
                                 {"busybox": {"do_compile": TASK_WITH_CHILD}})
        analyzer_cpu = bs.analyze(bsdir)["build"]["cpu_s"]
        guest = oh.guest_cpu_seconds(bsdir)
        self.assertAlmostEqual(guest["cpu_s"], analyzer_cpu, delta=0.05)
        self.assertGreater(guest["cpu_s"], 100.0)  # not 0.1 (own rusage only)


if __name__ == "__main__":
    unittest.main()
