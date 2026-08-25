#!/usr/bin/env python3
#
# Tests for tools/mackas-buildhistory-analyze.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stdlib only (unittest), matching the analyzer's own no-dependencies rule.
# These build a real git repository per test (git plumbing is the whole
# point of the diff-mode reader) rather than mocking `git` -- the same
# convention tests/adopt.bats already uses for its own git fixtures.

import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYZER = os.path.join(HERE, os.pardir, "tools", "mackas-buildhistory-analyze")


def _load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


bha = _load("bhanalyze", ANALYZER)


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd] + list(args), check=True,
                    capture_output=True)


def write(path, rel, content):
    full = os.path.join(path, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as fh:
        fh.write(content)


class BuildHistoryFixture:
    """A tiny buildhistory git repo: 2 arches, a handful of recipes and
    packages, 1 image, committed twice with a build-minus-1 tag on the
    first commit -- the shape retrieve.bats now uses too."""

    def __init__(self, tmp):
        self.path = tmp
        git(self.path, "init", "-q")
        git(self.path, "config", "user.email", "test@example.com")
        git(self.path, "config", "user.name", "test")

    def commit(self, message, tag=None):
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", message, "--allow-empty")
        if tag:
            git(self.path, "tag", tag)

    def write_recipe(self, arch, recipe, pv, pr, packages):
        write(self.path, "packages/%s/%s/latest" % (arch, recipe),
              "PV = %s\nPR = %s\nDEPENDS = \nPACKAGES = %s\n"
              % (pv, pr, " ".join(packages)))

    def write_package(self, arch, recipe, pkg, pkgsize, pkgv=None, pkgr=None):
        lines = []
        if pkgv:
            lines.append("PKGV = %s" % pkgv)
        if pkgr:
            lines.append("PKGR = %s" % pkgr)
        lines.append("PKGSIZE = %d" % pkgsize)
        write(self.path, "packages/%s/%s/%s/latest" % (arch, recipe, pkg),
              "\n".join(lines) + "\n")

    def write_image(self, machine, libc, image, imagesize, installed,
                     files=None):
        write(self.path,
              "images/%s/%s/%s/image-info.txt" % (machine, libc, image),
              "DISTRO = nodistro\nIMAGESIZE = %d\n" % imagesize)
        write(self.path,
              "images/%s/%s/%s/installed-package-names.txt"
              % (machine, libc, image),
              "\n".join(installed) + "\n")
        if files is not None:
            write(self.path,
                  "images/%s/%s/%s/files-in-image.txt" % (machine, libc, image),
                  "\n".join(files) + "\n")

    def remove(self, rel):
        os.remove(os.path.join(self.path, rel))


class DiffModeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = BuildHistoryFixture(self._tmp.name)

    def test_pv_pr_bump_detected(self):
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.write_package("cortexa57", "busybox", "busybox", 1000000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_recipe("cortexa57", "busybox", "1.37.0", "r0", ["busybox"])
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(len(rep["recipes"]["changed"]), 1)
        ch = rep["recipes"]["changed"][0]
        self.assertEqual(ch["name"], "busybox")
        self.assertEqual(ch["pv"], ["1.36.1", "1.37.0"])
        self.assertEqual(ch["pr"], ["r0", "r0"])

    def test_recipe_added(self):
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_recipe("cortexa57", "libgpiod", "2.1.3", "r0",
                                ["libgpiod", "libgpiod-tools"])
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(len(rep["recipes"]["added"]), 1)
        a = rep["recipes"]["added"][0]
        self.assertEqual(a["name"], "libgpiod")
        self.assertEqual(a["n_packages"], 2)
        self.assertEqual(rep["recipes"]["removed"], [])

    def test_recipe_removed(self):
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.write_recipe("cortexa57", "old-recipe", "1.0", "r0", ["old-recipe"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.remove("packages/cortexa57/old-recipe/latest")
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(len(rep["recipes"]["removed"]), 1)
        self.assertEqual(rep["recipes"]["removed"][0]["name"], "old-recipe")
        self.assertEqual(rep["recipes"]["added"], [])

    def test_package_added_and_removed_within_a_recipe(self):
        self.repo.write_recipe("cortexa57", "openssl", "3.3.1", "r0", ["openssl-bin"])
        self.repo.write_package("cortexa57", "openssl", "openssl-bin", 400000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_recipe("cortexa57", "openssl", "3.3.1", "r0",
                                ["openssl-bin", "openssl-ossl-module-legacy"])
        self.repo.write_package("cortexa57", "openssl",
                                 "openssl-ossl-module-legacy", 190000)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        ch = rep["recipes"]["changed"][0]
        self.assertEqual(ch["packages_added"], ["openssl-ossl-module-legacy"])
        self.assertEqual(ch["packages_removed"], [])

    def test_pkgsize_delta_and_percentage(self):
        # PKGSIZE (buildhistory.bbclass, straight from oe-core's
        # oe/packagedata.py) is BYTES -- confirmed by reading that source
        # directly (a real os.stat().st_size sum, no /1024 anywhere). These
        # write_package() values are bytes; analyze_diff() must convert to
        # KiB (see the module's own comment) before it does anything else
        # with them, so the assertions below are in KiB.
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.write_package("cortexa57", "busybox", "busybox", 1000000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_package("cortexa57", "busybox", "busybox", 900000)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        pc = rep["packages"]["changed"][0]
        self.assertAlmostEqual(pc["pkgsize"][0], 1000000 / 1024.0, places=4)
        self.assertAlmostEqual(pc["pkgsize"][1], 900000 / 1024.0, places=4)
        self.assertAlmostEqual(pc["delta"], (900000 - 1000000) / 1024.0, places=4)
        self.assertAlmostEqual(pc["pct"], -10.0, places=1)
        self.assertAlmostEqual(rep["packages"]["size_delta_total"],
                                (900000 - 1000000) / 1024.0, places=4)

    def test_imagesize_delta(self):
        # IMAGESIZE is already in KiB (`du -ks`) -- these numbers are KiB.
        self.repo.write_image("qemuarm64", "glibc", "core-image-minimal",
                               50000000, ["busybox"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_image("qemuarm64", "glibc", "core-image-minimal",
                               52000000, ["busybox"])
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        im = rep["images"][0]
        self.assertEqual(im["imagesize"], [50000000, 52000000])
        self.assertEqual(im["delta"], 2000000)

    def test_installed_package_set_difference(self):
        self.repo.write_image("qemuarm64", "glibc", "core-image-minimal",
                               50000000, ["busybox", "openssl-bin"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_image("qemuarm64", "glibc", "core-image-minimal",
                               50000000, ["busybox", "libgpiod"])
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        im = rep["images"][0]
        self.assertEqual(im["packages_added"], ["libgpiod"])
        self.assertEqual(im["packages_removed"], ["openssl-bin"])

    def test_threshold_hides_small_changes_but_still_counts_them(self):
        # PKGSIZE is bytes (see test_pkgsize_delta_and_percentage); a 50-byte
        # bump is a tiny fraction of a KiB, so it misses the 64 KiB floor by
        # a wide margin regardless of the unit bug -- kept as a real bytes
        # value (not a suspiciously round KiB number) so this test would
        # have failed loudly if the /1024 conversion were ever removed
        # (50 bytes read as "50 KiB" would wrongly clear the 64 KiB floor).
        self.repo.write_recipe("cortexa57", "tiny", "1.0", "r0", ["tiny"])
        self.repo.write_package("cortexa57", "tiny", "tiny", 10000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_package("cortexa57", "tiny", "tiny", 10050)
        self.repo.commit("Build 2")

        expected_delta = (10050 - 10000) / 1024.0

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(rep["packages"]["changed"], [])
        self.assertEqual(rep["packages"]["n_hidden"], 1)
        self.assertAlmostEqual(rep["packages"]["hidden_delta_total"],
                                expected_delta, places=4)
        self.assertAlmostEqual(rep["packages"]["size_delta_total"],
                                expected_delta, places=4)

        rep_all = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, True)
        self.assertEqual(len(rep_all["packages"]["changed"]), 1)
        self.assertEqual(rep_all["packages"]["n_hidden"], 0)

    def test_pkgsize_bytes_just_over_the_kib_threshold_is_shown(self):
        # The inverse pin: a delta that is genuinely >= 64 KiB in real KiB
        # terms must clear the floor and be listed. 70000 bytes ~= 68.36
        # KiB of growth -- comfortably over 64 KiB only after the /1024
        # conversion; read as raw bytes it would also "clear" 64 (any
        # multi-thousand-byte number does), so this alone wouldn't catch a
        # regression, but combined with the hidden-small-change test above
        # (which WOULD catch a removed conversion) it pins both directions.
        self.repo.write_recipe("cortexa57", "grower", "1.0", "r0", ["grower"])
        self.repo.write_package("cortexa57", "grower", "grower", 1000000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_package("cortexa57", "grower", "grower", 1070000)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(len(rep["packages"]["changed"]), 1)
        pc = rep["packages"]["changed"][0]
        self.assertAlmostEqual(pc["delta"], 70000 / 1024.0, places=4)

    def test_size_movers_table_does_not_collapse_similarly_named_packages(self):
        # Real bug, reported live against a real build (a new recipe,
        # qemuarmv5/console-pico-image, whose base package name is exactly
        # 20 chars): the formatted table used to truncate every name to 20
        # chars, so "bluetooth-pan-client" and every one of its OE-default
        # sub-packages ("bluetooth-pan-client-dev", "...-dbg", "...-doc",
        # "...-staticdev", "...-src") printed as the SAME string, making the
        # table useless for telling which package actually moved.
        base = "bluetooth-pan-client"  # exactly 20 chars, the real trigger
        self.assertEqual(len(base), 20)
        suffixes = ["", "-dev", "-dbg", "-doc", "-staticdev", "-src"]
        self.repo.write_recipe("armv5e", base, "1.0", "r0",
                                [base + s for s in suffixes])
        self.repo.commit("Build 1", tag="build-minus-1")
        for s in suffixes:
            self.repo.write_package("armv5e", base, base + s, 12697)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        text = bha.format_summary_diff(rep)
        for s in suffixes:
            self.assertIn(base + s, text,
                          "%r must appear whole, not truncated into %r"
                          % (base + s, base))

    def test_size_movers_table_marks_real_truncation_visibly(self):
        # The inverse: a name that genuinely exceeds the column width is
        # still cut (an unbounded column would let one pathological name
        # blow out the whole table) -- but must say so with "...", never
        # silently, per this project's no-silent-truncation rule.
        long_name = "a" * 55
        self.repo.write_recipe("cortexa57", "longrecipe", "1.0", "r0", [long_name])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_package("cortexa57", "longrecipe", long_name, 12697)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        text = bha.format_summary_diff(rep)
        self.assertNotIn(long_name, text)
        self.assertIn("...", text)

    def test_top_n_truncates(self):
        for i in range(5):
            self.repo.write_recipe("cortexa57", "r%d" % i, "1.0", "r0", ["p%d" % i])
            self.repo.write_package("cortexa57", "r%d" % i, "p%d" % i, 1000000)
        self.repo.commit("Build 1", tag="build-minus-1")
        for i in range(5):
            # Distinct, all-significant deltas so ordering is deterministic.
            self.repo.write_package("cortexa57", "r%d" % i, "p%d" % i,
                                     1000000 + (i + 1) * 100000)
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 2, False)
        self.assertEqual(len(rep["packages"]["changed"]), 2)
        # Largest deltas first.
        self.assertEqual(rep["packages"]["changed"][0]["name"], "p4")
        self.assertEqual(rep["packages"]["changed"][1]["name"], "p3")
        self.assertEqual(rep["packages"]["n_total_changed"], 5)

    def test_no_changes_commit_detected(self):
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.commit("No changes: rebuild with no changes")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertTrue(rep["no_changes"])

    def test_arch_directory_change_is_not_a_mass_add_remove(self):
        # A recipe whose whole arch directory moves (a machine switch) is
        # detected by git's own rename detection (-M): same content, new
        # path. Must not show up as one recipe removed + one added.
        self.repo.write_recipe("cortexa53", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.remove("packages/cortexa53/busybox/latest")
        self.repo.write_recipe("cortexa72", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.commit("Build 2")

        rep = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(rep["recipes"]["added"], [])
        self.assertEqual(rep["recipes"]["removed"], [])
        self.assertEqual(rep["recipes"]["changed"], [])

    def test_json_schema_keys_are_stable(self):
        self.repo.write_recipe("cortexa57", "busybox", "1.36.1", "r0", ["busybox"])
        self.repo.write_package("cortexa57", "busybox", "busybox", 1000000)
        self.repo.commit("Build 1", tag="build-minus-1")
        self.repo.write_recipe("cortexa57", "busybox", "1.37.0", "r0", ["busybox"])
        self.repo.commit("Build 2")

        rep1 = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        rep2 = bha.analyze_diff(self.repo.path, "build-minus-1", "HEAD", 10, False)
        self.assertEqual(set(rep1.keys()), set(rep2.keys()))
        expected = {"path", "mode", "from", "to", "no_changes", "recipes",
                    "packages", "images", "sdk", "other_changed_paths",
                    "top", "all"}
        self.assertEqual(set(rep1.keys()), expected)


class SnapshotModeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = self._tmp.name

    def test_snapshot_over_a_non_git_tree(self):
        write(self.path, "packages/cortexa57/busybox/busybox/latest",
              "PKGSIZE = 1000000\n")
        write(self.path,
              "images/qemuarm64/glibc/core-image-minimal/image-info.txt",
              "IMAGESIZE = 50000000\n")
        write(self.path,
              "images/qemuarm64/glibc/core-image-minimal/installed-package-names.txt",
              "busybox\n")

        self.assertFalse(os.path.isdir(os.path.join(self.path, ".git")))
        rep = bha.analyze_snapshot(self.path, 10)
        self.assertEqual(rep["mode"], "snapshot")
        self.assertEqual(rep["packages"]["count"], 1)
        # PKGSIZE is bytes -- total_size is converted to KiB (IMAGESIZE is
        # already KiB via `du -ks` and is untouched).
        self.assertAlmostEqual(rep["packages"]["total_size"],
                                1000000 / 1024.0, places=4)
        self.assertEqual(len(rep["images"]), 1)
        self.assertEqual(rep["images"][0]["imagesize"], 50000000)
        self.assertEqual(rep["images"][0]["n_packages"], 1)

    def test_malformed_latest_file_is_tolerated(self):
        write(self.path, "packages/cortexa57/foo/foo/latest",
              "not a valid line at all\nPKGSIZE\n\xff\xfe garbage")
        # Must not raise.
        rep = bha.analyze_snapshot(self.path, 10)
        self.assertEqual(rep["packages"]["count"], 1)
        self.assertEqual(rep["packages"]["total_size"], 0)


class ParseHelperTests(unittest.TestCase):
    def test_parse_kv_ignores_malformed_lines(self):
        kv = bha.parse_kv("PV = 1.0\nnonsense\n = novalue\nPR=r0\n")
        self.assertEqual(kv["PV"], "1.0")
        self.assertNotIn("nonsense", kv)

    def test_parse_kv_handles_none(self):
        self.assertEqual(bha.parse_kv(None), {})

    def test_parse_wordset_empty(self):
        self.assertEqual(bha.parse_wordset(""), set())
        self.assertEqual(bha.parse_wordset(None), set())
        self.assertEqual(bha.parse_wordset("a b c"), {"a", "b", "c"})

    def test_parse_lineset_drops_blanks(self):
        self.assertEqual(bha.parse_lineset("a\n\nb\n \n"), {"a", "b"})


if __name__ == "__main__":
    unittest.main()
