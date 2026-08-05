#!/usr/bin/env python3
#
# Tests for tools/mackas-ext4-dirty-bit.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stdlib only (unittest), matching the rest of the Python suite. The tool's
# whole job is reading fixed byte offsets out of an ext4 superblock; these
# tests build minimal, synthetic superblock images by hand (a 1024-byte pad
# plus a crafted 1024-byte superblock with only the fields under test set),
# not real ext4 filesystems -- hermetic, and it pins the exact offsets the
# tool was written against (verified live against e2fsprogs' own
# lib/ext2fs/ext2_fs.h and cross-checked against a genuinely corrupted
# volume.img this session, see the tool's own module docstring).

import importlib.machinery
import importlib.util
import io
import os
import struct
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, os.pardir, "tools", "mackas-ext4-dirty-bit")


def load_tool():
    loader = importlib.machinery.SourceFileLoader("mackas_ext4_dirty_bit", TOOL)
    spec = importlib.util.spec_from_loader("mackas_ext4_dirty_bit", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


dirty_bit = load_tool()

EXT2_SUPER_MAGIC = 0xEF53
EXT2_VALID_FS = 0x0001
EXT2_ERROR_FS = 0x0002
EXT3_FEATURE_INCOMPAT_RECOVER = 0x0004


def make_image(path, state, feature_incompat=0, error_count=0,
               last_error_line=0, last_error_func=b"", last_error_errcode=0,
               magic=EXT2_SUPER_MAGIC, truncate_superblock=False):
    """Write a synthetic image: 1024 bytes of leading pad (block 0, unused by
    ext2/3/4) followed by a 1024-byte superblock with only the fields this
    tool reads set explicitly; everything else stays zero."""
    sb = bytearray(1024)
    struct.pack_into("<H", sb, 0x38, magic)
    struct.pack_into("<H", sb, 0x3A, state)
    struct.pack_into("<I", sb, 0x60, feature_incompat)
    struct.pack_into("<I", sb, 0x190, error_count)
    struct.pack_into("<I", sb, 0x1D4, last_error_line)
    sb[0x1E0:0x1E0 + len(last_error_func)] = last_error_func
    sb[0x27B] = last_error_errcode
    with open(path, "wb") as f:
        f.write(b"\x00" * 1024)
        f.write(bytes(sb[:512] if truncate_superblock else sb))


class ReadSuperblockTest(unittest.TestCase):

    def test_clean_volume_reads_not_dirty(self):
        path = self._tmp("clean.img")
        make_image(path, state=EXT2_VALID_FS)
        sb = dirty_bit.read_superblock(path)
        v = dirty_bit.verdict(sb)
        self.assertFalse(v["dirty"])
        self.assertTrue(v["clean_unmount"])

    def test_error_bit_set_reads_dirty(self):
        path = self._tmp("dirty.img")
        make_image(path, state=EXT2_ERROR_FS,
                   last_error_line=1312, last_error_func=b"ext4_mb_generate_buddy",
                   last_error_errcode=5)
        sb = dirty_bit.read_superblock(path)
        v = dirty_bit.verdict(sb)
        self.assertTrue(v["dirty"])
        self.assertEqual(v["last_error_line"], 1312)
        self.assertEqual(v["last_error_func"], "ext4_mb_generate_buddy")
        self.assertEqual(v["last_error_errcode"], 5)

    def test_state_zero_is_not_dirty_not_clean_unmount(self):
        # The state Apple's container runtime actually leaves healthy,
        # never-touched-since-repair volumes in, live-tested this session:
        # neither bit set. Must read as "not dirty" (no ERROR_FS), even
        # though it is also not a "clean unmount".
        path = self._tmp("neither.img")
        make_image(path, state=0x0000)
        v = dirty_bit.verdict(dirty_bit.read_superblock(path))
        self.assertFalse(v["dirty"])
        self.assertFalse(v["clean_unmount"])

    def test_error_count_zero_does_not_override_a_populated_last_error(self):
        # Live-tested finding: a real corrupted image had error_count==0
        # while last_error_func/line/errcode WERE populated. The verdict
        # must come from the state bit, never from error_count.
        path = self._tmp("zero_count_but_dirty.img")
        make_image(path, state=EXT2_ERROR_FS, error_count=0,
                   last_error_func=b"ext4_mb_generate_buddy")
        v = dirty_bit.verdict(dirty_bit.read_superblock(path))
        self.assertTrue(v["dirty"])
        self.assertEqual(v["error_count"], 0)
        self.assertEqual(v["last_error_func"], "ext4_mb_generate_buddy")

    def test_needs_journal_recovery_flag_is_read(self):
        path = self._tmp("recover.img")
        make_image(path, state=EXT2_VALID_FS,
                   feature_incompat=EXT3_FEATURE_INCOMPAT_RECOVER)
        v = dirty_bit.verdict(dirty_bit.read_superblock(path))
        self.assertTrue(v["needs_journal_recovery"])
        self.assertFalse(v["dirty"])

    def test_bad_magic_raises_unreadable(self):
        path = self._tmp("notext4.img")
        make_image(path, state=EXT2_VALID_FS, magic=0x0000)
        with self.assertRaises(dirty_bit.UnreadableImage):
            dirty_bit.read_superblock(path)

    def test_missing_file_raises_unreadable(self):
        with self.assertRaises(dirty_bit.UnreadableImage):
            dirty_bit.read_superblock("/nonexistent/path/volume.img")

    def test_truncated_superblock_raises_unreadable(self):
        path = self._tmp("short.img")
        make_image(path, state=EXT2_VALID_FS, truncate_superblock=True)
        with self.assertRaises(dirty_bit.UnreadableImage):
            dirty_bit.read_superblock(path)

    # --- helpers -------------------------------------------------------

    _tmpdir = None

    def setUp(self):
        import tempfile
        self._tmpdir = tempfile.mkdtemp(prefix="mackas-ext4-dirty-bit-test-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def _tmp(self, name):
        return os.path.join(self._tmpdir, name)


class MainCliTest(unittest.TestCase):
    """The CLI wrapper: exit codes and both output modes."""

    def setUp(self):
        import tempfile
        self.tmpdir = tempfile.mkdtemp(prefix="mackas-ext4-dirty-bit-cli-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _tmp(self, name):
        return os.path.join(self.tmpdir, name)

    def _run(self, argv):
        buf = io.StringIO()
        import contextlib
        with contextlib.redirect_stdout(buf):
            rc = dirty_bit.main(argv)
        return rc, buf.getvalue()

    def test_clean_exits_zero_and_prints_clean(self):
        path = self._tmp("clean.img")
        make_image(path, state=EXT2_VALID_FS)
        rc, out = self._run([path])
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("CLEAN "))

    def test_dirty_exits_one_and_prints_dirty_with_detail(self):
        path = self._tmp("dirty.img")
        make_image(path, state=EXT2_ERROR_FS, last_error_line=1312,
                   last_error_func=b"ext4_mb_generate_buddy", last_error_errcode=5)
        rc, out = self._run([path])
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("DIRTY "))
        self.assertIn("ext4_mb_generate_buddy", out)
        self.assertIn("line 1312", out)
        self.assertIn("errno 5", out)

    def test_unknown_exits_two_never_treated_as_dirty(self):
        rc, out = self._run(["/nonexistent/volume.img"])
        self.assertEqual(rc, 2)
        self.assertTrue(out.startswith("UNKNOWN "))

    def test_json_mode_emits_valid_json_with_status_field(self):
        import json
        path = self._tmp("dirty.img")
        make_image(path, state=EXT2_ERROR_FS)
        rc, out = self._run(["--json", path])
        self.assertEqual(rc, 1)
        obj = json.loads(out)
        self.assertEqual(obj["status"], "dirty")
        self.assertTrue(obj["dirty"])

    def test_json_mode_on_unknown_image(self):
        import json
        rc, out = self._run(["--json", "/nonexistent/volume.img"])
        self.assertEqual(rc, 2)
        obj = json.loads(out)
        self.assertEqual(obj["status"], "unknown")


if __name__ == "__main__":
    unittest.main()
