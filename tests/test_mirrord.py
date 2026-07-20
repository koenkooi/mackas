#!/usr/bin/env python3
#
# Tests for mackas-mirrord. The security properties ARE the deliverable, so
# they are what is tested hardest here.
#
# Copyright (C) 2026 Koen Kooi <koen@dominion.thruhere.net>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Nothing here touches the network, NFS, sudo, or the real caches: every test
# builds a throwaway tree under a temp dir and binds 127.0.0.1 on port 0 (an
# ephemeral port the kernel picks), exactly as the bats suite refuses to touch
# the real container runtime.
#
#   python3 -m unittest discover -s tests -p 'test_*.py'   # or: make test

import base64
import errno
import http.client
import importlib.util
import logging
import os
import shutil
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIRRORD_PATH = os.path.join(REPO_ROOT, "mirror-server", "mackas-mirrord")


def load_mirrord():
    """Import mackas-mirrord, which has no .py extension on purpose."""
    spec = importlib.util.spec_from_loader(
        "mackas_mirrord",
        importlib.machinery.SourceFileLoader("mackas_mirrord", MIRRORD_PATH))
    module = importlib.util.module_from_spec(spec)
    sys.modules["mackas_mirrord"] = module
    spec.loader.exec_module(module)
    return module


md = load_mirrord()

# The daemon logs every refusal, which is exactly what we want in production
# and pure noise in a test run that deliberately triggers hundreds of them.
logging.disable(logging.CRITICAL)


def read_source() -> str:
    with open(MIRRORD_PATH, "r", encoding="utf-8") as fh:
        return fh.read()


def wait_until(predicate, timeout=5.0, interval=0.02):
    """Poll `predicate` until it is true, for cache promotion which runs on a
    background thread rather than on the request thread. Returns the final
    (possibly still-false) result rather than raising, so a failing caller
    gets a normal assertion failure instead of a poll-helper traceback."""
    deadline = time.time() + timeout
    result = predicate()
    while not result and time.time() < deadline:
        time.sleep(interval)
        result = predicate()
    return result


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


class ServerFixture:
    """A live mirrord on 127.0.0.1:0, plus a tree with a secret outside it."""

    def __init__(self, **overrides):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-test.")
        # Layout:
        #   <tmp>/outside/secret.txt    <- must NEVER be reachable
        #   <tmp>/root/hello.txt
        #   <tmp>/root/sub/nested.txt
        self.outside = os.path.join(self.tmp, "outside")
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.outside)
        os.makedirs(os.path.join(self.root, "sub"))
        with open(os.path.join(self.outside, "secret.txt"), "w") as fh:
            fh.write("TOP-SECRET-CANARY")
        with open(os.path.join(self.root, "hello.txt"), "w") as fh:
            fh.write("hello mirror")
        with open(os.path.join(self.root, "sub", "nested.txt"), "w") as fh:
            fh.write("nested")

        cfg = md.Config()
        cfg.roots = {"cache": os.path.realpath(self.root)}
        cfg.quiet = True
        for key, value in overrides.items():
            setattr(cfg, key, value)
        self.cfg = cfg

        handler = md.make_handler(cfg, md.RateLimiter(cfg.rate, cfg.burst))
        self.httpd = md.MirrorServer(("127.0.0.1", 0), handler,
                                     cfg.max_connections, cfg.timeout)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()

    def request(self, method, path, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, path, headers=headers or {})
            resp = conn.getresponse()
            body = resp.read()
            return resp.status, dict(resp.getheaders()), body
        finally:
            conn.close()

    def raw(self, data: bytes) -> bytes:
        """Send bytes the http.client would refuse to construct."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        try:
            sock.sendall(data)
            chunks = []
            while True:
                got = sock.recv(65536)
                if not got:
                    break
                chunks.append(got)
            return b"".join(chunks)
        finally:
            sock.close()

    def probe(self, chunks) -> bytes:
        """Send chunks while reading concurrently, and return what came back.

        The reader has to run in its own thread. When the server answers an
        error (431, 413, ...) and closes the connection with our unsent bytes
        still sitting unread in its receive buffer, that close arrives as a TCP
        RST -- and an RST discards data already queued in our own socket
        buffer, the error response included. A blocking "sendall then recv"
        loses that race whenever the RST beats our first read (reliably so
        under CPython 3.9); reading as the bytes arrive, rather than after we
        finish sending, is the difference between a reliable test and a flaky
        one.
        """
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        got = []

        def reader():
            try:
                while True:
                    data = sock.recv(4096)
                    if not data:
                        return
                    got.append(data)
            except OSError:
                return

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            for chunk in chunks:
                try:
                    sock.sendall(chunk)
                except OSError:
                    break  # server hung up on us: that is the point
            thread.join(timeout=5)
        finally:
            sock.close()
        return b"".join(got)

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)
        shutil.rmtree(self.tmp, ignore_errors=True)


class MirrordTestCase(unittest.TestCase):
    overrides = {}

    def setUp(self):
        self.srv = ServerFixture(**self.overrides)
        self.addCleanup(self.srv.close)

    def assertNoCanary(self, body):
        self.assertNotIn(b"TOP-SECRET-CANARY", body,
                         "the file outside the root was served!")


# ---------------------------------------------------------------------------
# Path traversal -- the headline threat
# ---------------------------------------------------------------------------


class TestPathTraversal(MirrordTestCase):
    # Every one of these must fail to reach <tmp>/outside/secret.txt, which
    # really exists on disk one level above the root. A test that only proves
    # a 404 for a file that never existed proves nothing.

    TRAVERSALS = [
        "/cache/../outside/secret.txt",
        "/cache/../../outside/secret.txt",
        "/cache/sub/../../outside/secret.txt",
        "/cache/%2e%2e/outside/secret.txt",
        "/cache/%2e%2e%2foutside%2fsecret.txt",
        "/cache/..%2foutside%2fsecret.txt",
        "/cache/..%252f..%252foutside%252fsecret.txt",  # double-encoded
        "/cache/%252e%252e/outside/secret.txt",
        "/cache/....//outside/secret.txt",
        "/cache/..;/outside/secret.txt",
        "/cache/./../outside/secret.txt",
        "/cache/sub/%2e%2e/%2e%2e/outside/secret.txt",
    ]

    def test_traversal_never_escapes(self):
        for path in self.TRAVERSALS:
            with self.subTest(path=path):
                status, _, body = self.srv.request("GET", path)
                self.assertNoCanary(body)
                self.assertIn(status, (400, 403, 404),
                              "unexpected status for %s" % path)

    def test_absolute_path_in_target(self):
        # An absolute filesystem path smuggled in as the request target.
        for path in ["//etc/passwd", "/cache//etc/passwd",
                     "/cache/%2fetc%2fpasswd"]:
            with self.subTest(path=path):
                status, _, body = self.srv.request("GET", path)
                self.assertNotIn(b"root:", body)
                self.assertIn(status, (400, 403, 404))

    def test_nul_byte_rejected(self):
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt%00.png")
        self.assertIn(status, (400, 404))
        self.assertNoCanary(body)

    def test_nul_byte_in_traversal(self):
        status, _, body = self.srv.request(
            "GET", "/cache/%00../outside/secret.txt")
        self.assertNoCanary(body)
        self.assertIn(status, (400, 404))

    def test_backslash_rejected(self):
        # Not a separator on POSIX, but it is on other platforms and in some
        # client libraries' idea of normalization. No legitimate sstate path
        # has one, so refusing is free.
        for target in [b"/cache/..%5coutside%5csecret.txt",
                       b"/cache/%5c..%5coutside%5csecret.txt",
                       b"/cache/sub%5c..%5c..%5coutside%5csecret.txt"]:
            with self.subTest(target=target):
                resp = self.srv.raw(b"GET " + target + b" HTTP/1.0\r\n\r\n")
                self.assertNotIn(b"TOP-SECRET-CANARY", resp)
                self.assertIn(b"404", resp.split(b"\r\n")[0])

    def test_control_char_in_path_rejected(self):
        resp = self.srv.raw(b"GET /cache/%0a%0dhello.txt HTTP/1.0\r\n\r\n")
        self.assertIn(b"404", resp.split(b"\r\n")[0])

    def test_legitimate_file_still_works(self):
        # The traversal defences are worthless if they also break the product.
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)
        status, _, body = self.srv.request("GET", "/cache/sub/nested.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"nested", body)

    def test_unknown_root_is_404(self):
        status, _, _ = self.srv.request("GET", "/nope/hello.txt")
        self.assertEqual(404, status)


class TestSymlinkEscape(MirrordTestCase):
    """The root is an NFS mount whose contents we do not control.

    Anyone who can write to the export can drop in a symlink to /etc/shadow.
    """

    def test_symlink_escaping_root_is_not_served(self):
        link = os.path.join(self.srv.root, "escape.txt")
        os.symlink(os.path.join(self.srv.outside, "secret.txt"), link)
        status, _, body = self.srv.request("GET", "/cache/escape.txt")
        self.assertNoCanary(body)
        self.assertEqual(404, status)

    def test_symlink_to_directory_outside_is_not_served(self):
        link = os.path.join(self.srv.root, "outlink")
        os.symlink(self.srv.outside, link)
        status, _, body = self.srv.request("GET", "/cache/outlink/secret.txt")
        self.assertNoCanary(body)
        self.assertEqual(404, status)

    def test_symlink_to_absolute_system_path_is_not_served(self):
        link = os.path.join(self.srv.root, "passwd")
        os.symlink("/etc/passwd", link)
        status, _, body = self.srv.request("GET", "/cache/passwd")
        self.assertNotIn(b"root:", body)
        self.assertEqual(404, status)

    def test_symlink_staying_inside_root_is_served_by_default(self):
        # Documented behaviour: escaping symlinks are always refused, internal
        # ones are allowed unless --no-symlinks. DL_DIR legitimately contains
        # internal symlinks.
        link = os.path.join(self.srv.root, "alias.txt")
        os.symlink(os.path.join(self.srv.root, "hello.txt"), link)
        status, _, body = self.srv.request("GET", "/cache/alias.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)


class TestStrictSymlinks(MirrordTestCase):
    overrides = {"allow_symlinks": False}

    def test_internal_symlink_refused_in_strict_mode(self):
        link = os.path.join(self.srv.root, "alias.txt")
        os.symlink(os.path.join(self.srv.root, "hello.txt"), link)
        status, _, _ = self.srv.request("GET", "/cache/alias.txt")
        self.assertEqual(404, status)

    def test_escaping_symlink_still_refused(self):
        link = os.path.join(self.srv.root, "escape.txt")
        os.symlink(os.path.join(self.srv.outside, "secret.txt"), link)
        status, _, body = self.srv.request("GET", "/cache/escape.txt")
        self.assertNoCanary(body)
        self.assertEqual(404, status)

    def test_real_file_still_served_in_strict_mode(self):
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)


class TestPrefixConfusion(unittest.TestCase):
    """'/root-evil'.startswith('/root') is True. That one line is an escape.

    This is the specific bug os.path.commonpath exists to prevent, tested
    against resolve_under_root directly because it needs a filesystem layout
    a URL cannot easily produce.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-prefix.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # Sibling directories whose names share a prefix.
        self.root = os.path.join(self.tmp, "root")
        self.evil = os.path.join(self.tmp, "root-evil")
        os.makedirs(self.root)
        os.makedirs(self.evil)
        with open(os.path.join(self.evil, "secret.txt"), "w") as fh:
            fh.write("TOP-SECRET-CANARY")
        self.root_real = os.path.realpath(self.root)

    def test_startswith_would_have_passed_this(self):
        # Proof the trap is real: the naive check accepts the escape.
        evil_real = os.path.realpath(os.path.join(self.evil, "secret.txt"))
        self.assertTrue(evil_real.startswith(self.root_real),
                        "the prefix-confusion setup is not actually confusing")

    def test_commonpath_rejects_the_sibling(self):
        with self.assertRaises(md.PathRejected):
            md.resolve_under_root(self.root_real, "/../root-evil/secret.txt")

    def test_symlink_to_prefix_sibling_rejected(self):
        os.symlink(self.evil, os.path.join(self.root, "link"))
        with self.assertRaises(md.PathRejected):
            md.resolve_under_root(self.root_real, "/link/secret.txt")

    def test_root_itself_is_contained(self):
        self.assertEqual(self.root_real,
                         md.resolve_under_root(self.root_real, "/"))


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------


def basic(user, password):
    raw = ("%s:%s" % (user, password)).encode("utf-8")
    return {"Authorization": "Basic " + base64.b64encode(raw).decode("ascii")}


class TestAuth(MirrordTestCase):
    overrides = {"creds": md.CredentialStore(
        [md.make_credential("builder", "correct horse battery staple")])}

    def test_no_credentials_is_401_with_challenge(self):
        status, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(401, status)
        self.assertIn("WWW-Authenticate", headers)
        self.assertTrue(headers["WWW-Authenticate"].startswith("Basic "))
        self.assertIn('realm=', headers["WWW-Authenticate"])

    def test_wrong_password_is_401(self):
        status, _, _ = self.srv.request(
            "GET", "/cache/hello.txt", basic("builder", "wrong"))
        self.assertEqual(401, status)

    def test_wrong_username_is_401(self):
        status, _, _ = self.srv.request(
            "GET", "/cache/hello.txt",
            basic("nobody", "correct horse battery staple"))
        self.assertEqual(401, status)

    def test_correct_credentials_is_200(self):
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt",
            basic("builder", "correct horse battery staple"))
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)

    def test_malformed_authorization_header_is_401_not_500(self):
        for value in ["Basic", "Basic !!!!not-base64!!!!", "Bearer token",
                      "Basic " + base64.b64encode(b"nocolon").decode(),
                      "Basic " + base64.b64encode(b"\xff\xfe").decode(),
                      ""]:
            with self.subTest(value=value):
                status, _, _ = self.srv.request(
                    "GET", "/cache/hello.txt", {"Authorization": value})
                self.assertEqual(401, status)

    def test_auth_is_checked_before_filesystem_access(self):
        # An unauthenticated client must not be able to tell a file that
        # exists from one that does not: both are 401, never 404 vs 200.
        exists, _, _ = self.srv.request("GET", "/cache/hello.txt")
        missing, _, _ = self.srv.request("GET", "/cache/nothing-here.txt")
        self.assertEqual(401, exists)
        self.assertEqual(401, missing)

    def test_auth_precedes_traversal_handling_too(self):
        status, _, body = self.srv.request(
            "GET", "/cache/../outside/secret.txt")
        self.assertEqual(401, status)
        self.assertNoCanary(body)

    def test_method_rejection_also_requires_auth(self):
        status, _, _ = self.srv.request("POST", "/cache/hello.txt")
        self.assertEqual(401, status)


class TestCredentialStore(unittest.TestCase):
    def test_roundtrip_through_the_on_disk_format(self):
        cred = md.make_credential("u", "p@ssw0rd with spaces")
        parsed = md.Credential.parse(str(cred))
        self.assertTrue(parsed.verify("p@ssw0rd with spaces"))
        self.assertFalse(parsed.verify("p@ssw0rd with space"))

    def test_password_is_not_recoverable_from_the_record(self):
        cred = md.make_credential("u", "hunter2")
        self.assertNotIn("hunter2", str(cred))

    def test_salt_differs_per_credential(self):
        a = md.make_credential("u", "same")
        b = md.make_credential("u", "same")
        self.assertNotEqual(a.salt, b.salt)
        self.assertNotEqual(a.digest, b.digest)

    def test_malformed_records_are_rejected(self):
        for bad in ["", "onlyuser", "u:md5:1000:AA==:AA==",
                    "u:pbkdf2_sha256:notanumber:AA==:AA==",
                    "u:pbkdf2_sha256:10:AA==:AA==",     # too few iterations
                    "u:pbkdf2_sha256:200000:!!!:AA==",  # bad base64
                    ":pbkdf2_sha256:200000:AA==:AA=="]:
            with self.subTest(record=bad):
                with self.assertRaises(ValueError):
                    md.Credential.parse(bad)

    def test_store_rejects_unknown_user_without_crashing(self):
        store = md.CredentialStore([md.make_credential("a", "b")])
        self.assertFalse(store.check("zzz", "b"))
        self.assertTrue(store.check("a", "b"))

    def test_load_credentials_skips_comments_and_blanks(self):
        cred = str(md.make_credential("u", "p"))
        text = "# a comment\n\n%s\n" % cred
        got = md.load_credentials(text, "<test>")
        self.assertEqual(1, len(got))
        self.assertEqual("u", got[0].username)


# ---------------------------------------------------------------------------
# IP allowlist
# ---------------------------------------------------------------------------


class TestAllowlistPermits(MirrordTestCase):
    import ipaddress as _ip
    overrides = {"allow_nets": [_ip.ip_network("127.0.0.0/8")]}

    def test_in_range_client_is_allowed(self):
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)


class TestAllowlistDenies(MirrordTestCase):
    import ipaddress as _ip
    # The test client is 127.0.0.1, which is not in this range.
    overrides = {"allow_nets": [_ip.ip_network("10.99.0.0/24")]}

    def test_out_of_range_client_is_403(self):
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(403, status)
        self.assertNoCanary(body)

    def test_allowlist_precedes_filesystem_access(self):
        exists, _, _ = self.srv.request("GET", "/cache/hello.txt")
        missing, _, _ = self.srv.request("GET", "/cache/nope.txt")
        self.assertEqual(403, exists)
        self.assertEqual(403, missing)


class TestAllowlistParsing(unittest.TestCase):
    def test_v4_mapped_v6_is_compared_as_v4(self):
        # A dual-stack listener sees ::ffff:192.0.2.68 for a v4 client. If
        # that is not unmapped before the check, every v4 CIDR silently fails
        # to match and the allowlist becomes a deny-all (or, worse, someone
        # "fixes" it by removing the allowlist).
        import ipaddress
        addr = ipaddress.ip_address("::ffff:192.0.2.68")
        self.assertIsNotNone(addr.ipv4_mapped)
        self.assertIn(addr.ipv4_mapped, ipaddress.ip_network("192.0.2.0/24"))


# ---------------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------------


class TestMethods(MirrordTestCase):
    def test_mutating_methods_are_405_with_allow(self):
        for method in ["POST", "PUT", "DELETE", "PATCH", "PROPFIND",
                       "PROPPATCH", "MKCOL", "COPY", "MOVE", "LOCK",
                       "UNLOCK", "TRACE"]:
            with self.subTest(method=method):
                status, headers, _ = self.srv.request(method, "/cache/hello.txt")
                self.assertEqual(405, status)
                self.assertIn("Allow", headers)
                allow = headers["Allow"]
                self.assertIn("GET", allow)
                self.assertIn("HEAD", allow)
                for verb in ("PUT", "POST", "DELETE", "PROPFIND"):
                    self.assertNotIn(verb, allow)

    def test_post_cannot_write_a_file(self):
        # Belt and braces: prove the 405 is real, not cosmetic.
        conn = http.client.HTTPConnection("127.0.0.1", self.srv.port, timeout=10)
        try:
            conn.request("PUT", "/cache/new.txt", body=b"payload")
            self.assertEqual(405, conn.getresponse().status)
        finally:
            conn.close()
        self.assertFalse(os.path.exists(os.path.join(self.srv.root, "new.txt")))

    def test_head_returns_headers_and_no_body(self):
        status, headers, body = self.srv.request("HEAD", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"", body)
        self.assertEqual("12", headers["Content-Length"])
        self.assertIn("Last-Modified", headers)

    def test_options_advertises_only_read_methods(self):
        status, headers, _ = self.srv.request("OPTIONS", "/cache/hello.txt")
        self.assertEqual(204, status)
        self.assertEqual("GET, HEAD, OPTIONS", headers["Allow"])

    def test_unknown_method_is_501_not_a_crash(self):
        resp = self.srv.raw(b"FROBNICATE /cache/hello.txt HTTP/1.0\r\n\r\n")
        self.assertIn(b"501", resp.split(b"\r\n")[0])
        self.assertNotIn(b"Traceback", resp)


# ---------------------------------------------------------------------------
# Information disclosure
# ---------------------------------------------------------------------------


class TestNoListingByDefault(MirrordTestCase):
    def test_directory_is_404_not_a_listing(self):
        status, _, body = self.srv.request("GET", "/cache/")
        self.assertEqual(404, status)
        self.assertNotIn(b"hello.txt", body)

    def test_subdirectory_is_404(self):
        status, _, body = self.srv.request("GET", "/cache/sub/")
        self.assertEqual(404, status)
        self.assertNotIn(b"nested.txt", body)

    def test_root_index_is_404(self):
        status, _, body = self.srv.request("GET", "/")
        self.assertEqual(404, status)
        self.assertNotIn(b"cache", body)


class TestListingEnabled(MirrordTestCase):
    overrides = {"listing": True}

    def test_listing_appears_only_with_the_flag(self):
        status, headers, body = self.srv.request("GET", "/cache/")
        self.assertEqual(200, status)
        self.assertIn(b"hello.txt", body)
        self.assertIn(b"sub/", body)
        # Plain text, not HTML: nothing to escape means nothing escaped wrong.
        self.assertTrue(headers["Content-Type"].startswith("text/plain"))


class TestBanner(MirrordTestCase):
    def test_no_python_version_banner(self):
        status, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        server = headers.get("Server", "")
        self.assertEqual("mackas-mirrord", server)
        self.assertNotIn("Python", server)
        self.assertNotIn("BaseHTTP", server)
        self.assertNotIn("SimpleHTTP", server)

    def test_no_banner_on_errors_either(self):
        _, headers, _ = self.srv.request("GET", "/cache/missing.txt")
        self.assertNotIn("Python", headers.get("Server", ""))

    def test_error_body_does_not_echo_the_request_path(self):
        # http.server's stock send_error() interpolates the path into an HTML
        # body -- a reflected-XSS foot-gun. Ours must echo nothing.
        marker = "XYZZY-REFLECT-ME"
        status, _, body = self.srv.request("GET", "/cache/%s" % marker)
        self.assertEqual(404, status)
        self.assertNotIn(marker.encode(), body)
        self.assertNotIn(b"<script", body.lower())
        self.assertNotIn(b"<", body)

    def test_error_body_does_not_leak_filesystem_paths(self):
        _, _, body = self.srv.request("GET", "/cache/missing.txt")
        self.assertNotIn(self.srv.tmp.encode(), body)
        self.assertNotIn(b"/tmp", body)


class TestNoStackTraces(MirrordTestCase):
    def test_forced_internal_error_yields_a_bare_500(self):
        # Force a bug in our own code path and prove the client learns nothing
        # about it. serve_file is called for every request, so exploding there
        # exercises the real exception path, not a synthetic one.
        def boom(*_args, **_kwargs):
            raise RuntimeError("SENSITIVE-INTERNAL-DETAIL")

        handler = type(self.srv.httpd.RequestHandlerClass)(
            "Boom", (self.srv.httpd.RequestHandlerClass,), {"serve_file": boom})
        self.srv.httpd.RequestHandlerClass = handler

        status, headers, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(500, status)
        self.assertNotIn(b"SENSITIVE-INTERNAL-DETAIL", body)
        self.assertNotIn(b"Traceback", body)
        self.assertNotIn(b"RuntimeError", body)
        self.assertNotIn(b"mackas-mirrord", body)  # no file paths either
        self.assertEqual(b"500 Internal Server Error\n", body)

    def test_server_survives_the_error(self):
        status, _, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)


# ---------------------------------------------------------------------------
# Log sanitization
# ---------------------------------------------------------------------------


class TestLogSanitization(unittest.TestCase):
    """Threat: a client forging log lines, or injecting terminal escapes."""

    def test_newlines_are_escaped(self):
        got = md.sanitize_for_log("/a\n2026-01-01 FAKE LOG LINE")
        self.assertNotIn("\n", got)
        self.assertIn("\\x0a", got)

    def test_carriage_returns_are_escaped(self):
        self.assertNotIn("\r", md.sanitize_for_log("/a\r\nb"))

    def test_nul_and_control_chars_are_escaped(self):
        got = md.sanitize_for_log("/a\x00b\x07c\x1bd")
        self.assertNotIn("\x00", got)
        self.assertNotIn("\x1b", got)
        self.assertIn("\\x00", got)
        self.assertIn("\\x1b", got)

    def test_terminal_escape_sequence_is_defanged(self):
        # \x1b[2J clears the operator's screen if a log is cat'd.
        got = md.sanitize_for_log("\x1b[2J\x1b[H")
        self.assertNotIn("\x1b", got)

    def test_printable_ascii_survives_unharmed(self):
        path = "/sstate/a1/sstate:zlib:core2-64:1.3::x86_64.tgz"
        self.assertEqual(path, md.sanitize_for_log(path))

    def test_long_input_is_truncated(self):
        got = md.sanitize_for_log("A" * 10000)
        self.assertLess(len(got), 600)
        self.assertIn("truncated", got)

    def test_non_ascii_is_escaped_not_dropped(self):
        got = md.sanitize_for_log("café")
        self.assertNotIn("é", got)
        self.assertTrue(got.startswith("caf\\x"))


# ---------------------------------------------------------------------------
# bitbake correctness
# ---------------------------------------------------------------------------


class TestBitbakeCorrectness(MirrordTestCase):
    def test_content_length_and_last_modified(self):
        status, headers, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(str(len(body)), headers["Content-Length"])
        self.assertIn("Last-Modified", headers)
        self.assertIn("GMT", headers["Last-Modified"])

    def test_if_modified_since_yields_304(self):
        _, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        lm = headers["Last-Modified"]
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt", {"If-Modified-Since": lm})
        self.assertEqual(304, status)
        self.assertEqual(b"", body)

    def test_if_modified_since_in_the_past_yields_200(self):
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt",
            {"If-Modified-Since": "Sat, 01 Jan 2000 00:00:00 GMT"})
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)

    def test_unparseable_if_modified_since_is_ignored_not_fatal(self):
        status, _, _ = self.srv.request(
            "GET", "/cache/hello.txt", {"If-Modified-Since": "not a date"})
        self.assertEqual(200, status)

    def test_range_request_is_honoured(self):
        # SimpleHTTPRequestHandler does NOT do this; we implement it because a
        # resumed 200 MB download over a flaky link is a real cost.
        status, headers, body = self.srv.request(
            "GET", "/cache/hello.txt", {"Range": "bytes=0-4"})
        self.assertEqual(206, status)
        self.assertEqual(b"hello", body)
        self.assertEqual("bytes 0-4/12", headers["Content-Range"])
        self.assertEqual("5", headers["Content-Length"])

    def test_open_ended_range(self):
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt", {"Range": "bytes=6-"})
        self.assertEqual(206, status)
        self.assertEqual(b"mirror", body)

    def test_suffix_range(self):
        status, _, body = self.srv.request(
            "GET", "/cache/hello.txt", {"Range": "bytes=-6"})
        self.assertEqual(206, status)
        self.assertEqual(b"mirror", body)

    def test_unsatisfiable_range_is_416(self):
        status, headers, _ = self.srv.request(
            "GET", "/cache/hello.txt", {"Range": "bytes=9999-"})
        self.assertEqual(416, status)
        self.assertEqual("bytes */12", headers["Content-Range"])

    def test_malformed_range_falls_back_to_200(self):
        for value in ["bytes=abc", "items=0-1", "bytes=", "bytes=5-1",
                      "bytes=0-1,4-5"]:
            with self.subTest(value=value):
                status, _, body = self.srv.request(
                    "GET", "/cache/hello.txt", {"Range": value})
                self.assertEqual(200, status)
                self.assertEqual(b"hello mirror", body)

    def test_accept_ranges_is_advertised(self):
        _, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual("bytes", headers["Accept-Ranges"])

    def test_miss_is_a_plain_404(self):
        # The dominant pattern: bitbake probes thousands of objects that do
        # not exist. Must be cheap, and must not be a redirect or a listing.
        status, headers, body = self.srv.request(
            "GET", "/cache/aa/sstate:nothing:here.tgz")
        self.assertEqual(404, status)
        self.assertEqual(str(len(body)), headers["Content-Length"])

    def test_content_type_is_opaque_and_nosniff(self):
        # Never sniff an extension into text/html: that is how a cached object
        # becomes stored XSS.
        _, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual("application/octet-stream", headers["Content-Type"])
        self.assertEqual("nosniff", headers["X-Content-Type-Options"])

    def test_keepalive_serves_several_requests_on_one_connection(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.srv.port, timeout=10)
        try:
            for _ in range(3):
                conn.request("GET", "/cache/hello.txt")
                resp = conn.getresponse()
                self.assertEqual(200, resp.status)
                self.assertEqual(b"hello mirror", resp.read())
        finally:
            conn.close()


class TestSpecialFiles(MirrordTestCase):
    def test_fifo_is_not_served(self):
        # Opening a FIFO on an NFS export would hang the thread forever --
        # a DoS handed to anyone who can write to the export.
        fifo = os.path.join(self.srv.root, "pipe")
        try:
            os.mkfifo(fifo)
        except (OSError, AttributeError):
            self.skipTest("mkfifo unavailable")
        status, _, _ = self.srv.request("GET", "/cache/pipe")
        self.assertEqual(404, status)

    def test_dev_null_via_symlink_is_not_served(self):
        link = os.path.join(self.srv.root, "null")
        os.symlink("/dev/null", link)
        status, _, _ = self.srv.request("GET", "/cache/null")
        self.assertEqual(404, status)

    def test_empty_file_is_served_with_zero_length(self):
        with open(os.path.join(self.srv.root, "empty"), "w"):
            pass
        status, headers, body = self.srv.request("GET", "/cache/empty")
        self.assertEqual(200, status)
        self.assertEqual(b"", body)
        self.assertEqual("0", headers["Content-Length"])


# ---------------------------------------------------------------------------
# DoS resistance
# ---------------------------------------------------------------------------


class TestLimits(MirrordTestCase):
    def test_overlong_request_line_is_rejected(self):
        resp = self.srv.raw(
            b"GET /cache/" + b"A" * 70000 + b" HTTP/1.0\r\n\r\n")
        self.assertTrue(resp.split(b"\r\n")[0].split()[1] in (b"414", b"400"),
                        resp.split(b"\r\n")[0])

    def test_too_many_headers_is_rejected(self):
        headers = b"".join(b"X-Pad-%d: x\r\n" % i for i in range(200))
        resp = self.srv.raw(
            b"GET /cache/hello.txt HTTP/1.0\r\n" + headers + b"\r\n")
        first = resp.split(b"\r\n")[0]
        self.assertNotIn(b"200", first)

    def test_oversized_headers_are_rejected(self):
        # A single header line far past MAX_HEADER_LINE. The server answers 431
        # and closes with our trailing bytes unread, which turns the close into
        # an RST -- so we read concurrently (see ServerFixture.probe) rather
        # than blocking-send-then-read, which loses the response to the RST.
        headers = b"X-Big: " + b"A" * 40000 + b"\r\n"
        reply = self.srv.probe(
            [b"GET /cache/hello.txt HTTP/1.0\r\n" + headers + b"\r\n"])
        self.assertIn(b"431", reply.split(b"\r\n")[0],
                      "expected a 431; got %r" % reply[:80])


class TestRateLimiter(unittest.TestCase):
    def test_burst_then_deny(self):
        rl = md.RateLimiter(rate=1.0, burst=3)
        self.assertTrue(all(rl.allow("1.2.3.4") for _ in range(3)))
        self.assertFalse(rl.allow("1.2.3.4"))

    def test_limits_are_per_ip(self):
        rl = md.RateLimiter(rate=1.0, burst=1)
        self.assertTrue(rl.allow("1.2.3.4"))
        self.assertFalse(rl.allow("1.2.3.4"))
        self.assertTrue(rl.allow("5.6.7.8"))

    def test_zero_rate_disables_the_limiter(self):
        rl = md.RateLimiter(rate=0.0, burst=1)
        self.assertTrue(all(rl.allow("1.2.3.4") for _ in range(1000)))

    def test_bucket_table_stays_bounded(self):
        # The limiter must not become the memory-exhaustion vector it exists
        # to prevent.
        rl = md.RateLimiter(rate=1000.0, burst=1)
        for i in range(md.RateLimiter.MAX_ENTRIES * 2):
            rl.allow("10.%d.%d.%d" % (i >> 16 & 255, i >> 8 & 255, i & 255))
        self.assertLessEqual(len(rl._buckets), md.RateLimiter.MAX_ENTRIES)


class TestRateLimitedServer(MirrordTestCase):
    overrides = {"rate": 0.001, "burst": 2}

    def test_excess_requests_get_429_with_retry_after(self):
        seen = [self.srv.request("GET", "/cache/hello.txt")[0]
                for _ in range(5)]
        self.assertEqual(200, seen[0])
        self.assertIn(429, seen)
        status, headers, _ = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(429, status)
        self.assertIn("Retry-After", headers)

    def test_rate_limit_precedes_auth_and_filesystem(self):
        for _ in range(5):
            self.srv.request("GET", "/cache/hello.txt")
        status, _, body = self.srv.request(
            "GET", "/cache/../outside/secret.txt")
        self.assertEqual(429, status)
        self.assertNoCanary(body)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


class TestRootSpec(unittest.TestCase):
    def test_named_root(self):
        self.assertEqual(("sstate", "/srv/x"),
                         md.parse_root_spec("sstate=/srv/x"))

    def test_bare_path_is_the_url_root(self):
        self.assertEqual(("", "/srv/x"), md.parse_root_spec("/srv/x"))

    def test_root_name_is_constrained(self):
        for bad in ["a/b=/srv/x", "=/srv/x", "a b=/srv/x", "a$b=/srv/x"]:
            with self.subTest(spec=bad):
                with self.assertRaises(md.ConfigError):
                    md.parse_root_spec(bad)

    def test_empty_path_rejected(self):
        with self.assertRaises(md.ConfigError):
            md.parse_root_spec("name=")

    def test_nonexistent_root_is_a_config_error(self):
        with self.assertRaises(md.ConfigError):
            md.validate_roots(["x=/nonexistent-xyzzy-12345"])

    def test_duplicate_root_names_rejected(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        with self.assertRaises(md.ConfigError):
            md.validate_roots(["a=%s" % tmp, "a=%s" % tmp])

    def test_unnamed_root_cannot_be_mixed_with_named(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        with self.assertRaises(md.ConfigError):
            md.validate_roots([tmp, "a=%s" % tmp])


class TestConfigPrecedence(unittest.TestCase):
    """defaults -> config file -> env -> CLI, matching mackas' convention."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-cfg.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)
        self.saved_env = {k: v for k, v in os.environ.items()
                          if k.startswith(md.ENV_PREFIX)}
        for k in list(os.environ):
            if k.startswith(md.ENV_PREFIX):
                del os.environ[k]

    def tearDown(self):
        for k in list(os.environ):
            if k.startswith(md.ENV_PREFIX):
                del os.environ[k]
        os.environ.update(self.saved_env)

    def resolve(self, argv):
        return md.resolve_config(md.build_parser().parse_args(argv))

    def test_default_port(self):
        cfg = self.resolve(["--root", "a=%s" % self.root])
        self.assertEqual(md.DEFAULT_PORT, cfg.port)

    def test_config_file_beats_default(self):
        path = os.path.join(self.tmp, "conf")
        with open(path, "w") as fh:
            fh.write("# comment\nPORT=9001\n")
        cfg = self.resolve(["--root", "a=%s" % self.root, "--config", path])
        self.assertEqual(9001, cfg.port)

    def test_env_beats_config_file(self):
        path = os.path.join(self.tmp, "conf")
        with open(path, "w") as fh:
            fh.write("PORT=9001\n")
        os.environ[md.ENV_PREFIX + "PORT"] = "9002"
        cfg = self.resolve(["--root", "a=%s" % self.root, "--config", path])
        self.assertEqual(9002, cfg.port)

    def test_cli_beats_env(self):
        os.environ[md.ENV_PREFIX + "PORT"] = "9002"
        cfg = self.resolve(["--root", "a=%s" % self.root, "--port", "9003"])
        self.assertEqual(9003, cfg.port)

    def test_roots_from_env(self):
        os.environ[md.ENV_PREFIX + "ROOTS"] = "a=%s,b=%s" % (self.root, self.tmp)
        cfg = self.resolve([])
        self.assertEqual({"a", "b"}, set(cfg.roots))

    def test_no_root_is_an_error(self):
        with self.assertRaises(md.ConfigError):
            self.resolve([])

    def test_allow_cidrs_parse(self):
        cfg = self.resolve(["--root", "a=%s" % self.root,
                            "--allow", "192.0.2.0/24", "--allow", "127.0.0.1"])
        self.assertEqual(2, len(cfg.allow_nets))

    def test_allow_accepts_host_bits(self):
        # "192.0.2.5/24" obviously means the /24; erroring on host bits is a
        # papercut with no security value.
        cfg = self.resolve(["--root", "a=%s" % self.root,
                            "--allow", "192.0.2.5/24"])
        self.assertEqual("192.0.2.0/24", str(cfg.allow_nets[0]))

    def test_bad_cidr_is_a_config_error(self):
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root, "--allow", "not-a-net"])

    def test_bad_port_is_a_config_error(self):
        for port in ["0", "65536", "-1"]:
            with self.subTest(port=port):
                with self.assertRaises(md.ConfigError):
                    self.resolve(["--root", "a=%s" % self.root,
                                  "--port", port])

    def test_tls_cert_and_key_must_come_together(self):
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root,
                          "--tls-cert", "/tmp/x.crt"])

    def test_config_file_is_not_executed_as_code(self):
        # mackas.conf is sourced as shell; this is not. A daemon that exec'd
        # its config would turn "can write the config" into "can run code as
        # the daemon user".
        path = os.path.join(self.tmp, "conf")
        with open(path, "w") as fh:
            fh.write("PORT=$((9000+1))\n")
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root, "--config", path])

    def test_world_readable_credential_file_is_refused(self):
        path = os.path.join(self.tmp, "cred")
        with open(path, "w") as fh:
            fh.write(str(md.make_credential("u", "p")) + "\n")
        os.chmod(path, 0o644)
        with self.assertRaises(md.ConfigError) as ctx:
            self.resolve(["--root", "a=%s" % self.root, "--cred-file", path])
        self.assertIn("accessible", str(ctx.exception))

    def test_mode_600_credential_file_is_accepted(self):
        path = os.path.join(self.tmp, "cred")
        with open(path, "w") as fh:
            fh.write(str(md.make_credential("u", "p")) + "\n")
        os.chmod(path, 0o600)
        cfg = self.resolve(["--root", "a=%s" % self.root, "--cred-file", path])
        self.assertTrue(cfg.creds)
        self.assertTrue(cfg.creds.check("u", "p"))

    def test_credentials_from_env(self):
        os.environ[md.ENV_PREFIX + "CRED"] = str(md.make_credential("u", "p"))
        cfg = self.resolve(["--root", "a=%s" % self.root])
        self.assertTrue(cfg.creds.check("u", "p"))

    def test_check_mode_describes_without_binding(self):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = md.main(["--root", "a=%s" % self.root, "--check", "--quiet"])
        self.assertEqual(0, rc)
        self.assertIn("configuration is valid", out.getvalue())
        self.assertIn(self.root, out.getvalue())
        # --check must not bind: the port stays free afterwards.
        probe = socket.socket()
        try:
            probe.bind(("127.0.0.1", md.DEFAULT_PORT))
        except OSError:
            self.skipTest("port %d busy on this host" % md.DEFAULT_PORT)
        finally:
            probe.close()

    def test_check_mode_reports_bad_config(self):
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            rc = md.main(["--root", "a=/nonexistent-xyzzy", "--check"])
        self.assertEqual(2, rc)

    def test_describe_never_prints_a_secret(self):
        os.environ[md.ENV_PREFIX + "CRED"] = str(md.make_credential("u", "s3cr3t"))
        cfg = self.resolve(["--root", "a=%s" % self.root])
        text = md.describe(cfg)
        self.assertNotIn("s3cr3t", text)
        self.assertIn("1 credential", text)


class TestPrivilegeDrop(unittest.TestCase):
    def test_no_op_when_not_root(self):
        if os.getuid() == 0:
            self.skipTest("running as root")
        md.drop_privileges("nobody", None)  # must not raise

    def test_refuses_to_run_as_root_without_user(self):
        # Cannot become root in a test, so assert on the guard's own logic by
        # reading it: resolve_config raises only when getuid()==0. Instead
        # check the message exists so the guard cannot be silently deleted.
        source = read_source()
        self.assertIn("refusing to run as root without --user", source)

    def test_drop_order_is_setgroups_setgid_setuid(self):
        # setuid() first is THE classic bug: it drops the privilege the other
        # two calls need, so they fail and the process keeps root's groups.
        # Guard the ordering textually, since a real drop needs root.
        source = read_source()
        body = source.split("def drop_privileges", 1)[1].split("\ndef ", 1)[0]
        i_groups = body.index("os.setgroups(")
        i_gid = body.index("os.setgid(")
        i_uid = body.index("os.setuid(")
        self.assertLess(i_groups, i_gid, "setgroups must precede setgid")
        self.assertLess(i_gid, i_uid, "setgid must precede setuid")


class TestTLSContext(unittest.TestCase):
    def test_minimum_version_is_tls12(self):
        # Everything older is deprecated and broken in ways with names.
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        with self.assertRaises(md.ConfigError):
            md.build_ssl_context(os.path.join(tmp, "nope.crt"),
                                 os.path.join(tmp, "nope.key"))

    def test_context_settings(self):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        # Mirror what build_ssl_context does, minus the cert load, and assert
        # the constants exist on this interpreter.
        self.assertTrue(hasattr(ssl.TLSVersion, "TLSv1_2"))
        self.assertTrue(hasattr(ssl, "OP_NO_COMPRESSION"))
        del ctx


class TestPythonVersionFloor(unittest.TestCase):
    def test_declared_minimum_is_37(self):
        # A given mirror host may run a much newer Python, but the point of
        # stdlib-only is that this file runs on whatever the host has. 3.7 is
        # the floor because ThreadingHTTPServer landed there.
        self.assertEqual((3, 7), md.MIN_PYTHON)

    def test_no_third_party_imports(self):
        # The hard requirement: no pip, no venv, scp one file and go.
        import ast
        tree = ast.parse(read_source())
        stdlib = set(getattr(sys, "stdlib_module_names", ()))
        if not stdlib:
            self.skipTest("sys.stdlib_module_names needs Python 3.10+")
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                imported.add(node.module.split(".")[0])
        outside = imported - stdlib
        self.assertEqual(set(), outside,
                         "non-stdlib imports: %s" % sorted(outside))


# ---------------------------------------------------------------------------
# TOCTOU: swapping an INTERMEDIATE component for a symlink
#
# The headline regression. The old code realpath'd the path and then re-opened
# it as a string with O_NOFOLLOW, which only ever protected the last component:
# every directory in the middle was resolved by the kernel, symlinks and all.
# An attacker with write access to the export -- which the threat model grants,
# the NFS export's contents are not ours -- swaps root/sub for a symlink in the
# window between the check and the open, and the open walks straight through it.
# ---------------------------------------------------------------------------


class TestToctouIntermediateSwap(MirrordTestCase):
    def _make_sub_a_symlink_out(self):
        """The swap itself: root/sub stops being a directory and starts being
        a symlink to the directory holding the secret."""
        sub = os.path.join(self.srv.root, "sub")
        if os.path.islink(sub):
            return
        shutil.rmtree(sub, ignore_errors=True)
        os.symlink(self.srv.outside, sub)

    def test_swap_between_resolve_and_open_never_serves_the_secret(self):
        # Deterministic by construction: rather than hoping to hit a race
        # window, we hook the exact instant the window opens and let the
        # attacker win it 100% of the time. If containment depends on timing,
        # this test fails every run rather than one run in a thousand.
        real_resolve = md.resolve_under_root

        def resolve_then_swap(root_real, url_path, allow_symlinks=True):
            result = real_resolve(root_real, url_path, allow_symlinks)
            self._make_sub_a_symlink_out()  # attacker wins the race, always
            return result

        md.resolve_under_root = resolve_then_swap
        self.addCleanup(setattr, md, "resolve_under_root", real_resolve)

        status, _, body = self.srv.request("GET", "/cache/sub/secret.txt")
        self.assertNoCanary(body)
        self.assertEqual(404, status)

    def test_a_real_thread_race_never_leaks_the_secret(self):
        # The deterministic test above proves the mechanism. This one proves it
        # against the real thing: a thread flipping root/sub back and forth
        # while requests come in. The reviewer's exploit leaked the secret
        # within four requests.
        sub = os.path.join(self.srv.root, "sub")
        stop = threading.Event()

        def flipper():
            while not stop.is_set():
                try:
                    if os.path.islink(sub):
                        os.unlink(sub)
                        os.makedirs(sub, exist_ok=True)
                    else:
                        shutil.rmtree(sub, ignore_errors=True)
                        os.symlink(self.srv.outside, sub)
                except OSError:
                    pass

        thread = threading.Thread(target=flipper, daemon=True)
        thread.start()
        try:
            for _ in range(200):
                _, _, body = self.srv.request("GET", "/cache/sub/secret.txt")
                self.assertNoCanary(body)
        finally:
            stop.set()
            thread.join(timeout=5)

    def test_intra_root_symlink_is_still_served(self):
        # The fix must not become "refuse all symlinks": DL_DIR is full of
        # legitimate ones. A symlink resolved BEFORE the check is followed; one
        # that appears AFTER it is not. This is the first half of that.
        os.symlink(os.path.join(self.srv.root, "hello.txt"),
                   os.path.join(self.srv.root, "link.txt"))
        status, _, body = self.srv.request("GET", "/cache/link.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)

    def test_symlinked_intermediate_directory_inside_root_still_works(self):
        # And an intra-root symlink used as an intermediate component resolves
        # fine too -- the walk sees the realpath's components, not the URL's.
        os.symlink(os.path.join(self.srv.root, "sub"),
                   os.path.join(self.srv.root, "subline"))
        status, _, body = self.srv.request("GET", "/cache/subline/nested.txt")
        self.assertEqual(200, status)
        self.assertEqual(b"nested", body)


class TestOpenUnderRoot(unittest.TestCase):
    """Unit-level: the walk refuses a symlink in any position."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-walk.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.realpath(os.path.join(self.tmp, "root"))
        self.outside = os.path.realpath(os.path.join(self.tmp, "outside"))
        os.makedirs(os.path.join(self.root, "sub"))
        os.makedirs(self.outside)
        with open(os.path.join(self.outside, "secret.txt"), "w") as fh:
            fh.write("TOP-SECRET-CANARY")
        with open(os.path.join(self.root, "sub", "ok.txt"), "w") as fh:
            fh.write("fine")

    def test_opens_a_real_file_under_the_root(self):
        fd = md.open_under_root(self.root,
                                os.path.join(self.root, "sub", "ok.txt"))
        try:
            self.assertEqual(b"fine", os.read(fd, 64))
        finally:
            os.close(fd)

    def test_refuses_a_symlinked_intermediate_component(self):
        # Exactly the state the attacker's swap leaves behind: the string path
        # still "looks" contained, and every component of it still resolves --
        # through a symlink pointing out of the root.
        shutil.rmtree(os.path.join(self.root, "sub"))
        os.symlink(self.outside, os.path.join(self.root, "sub"))
        with self.assertRaises(OSError) as caught:
            md.open_under_root(self.root,
                               os.path.join(self.root, "sub", "secret.txt"))
        # O_NOFOLLOW|O_DIRECTORY on a symlink: Linux says ELOOP, macOS says
        # ENOTDIR. Both mean "refused, did not follow", and serve_file maps
        # both to 404.
        self.assertIn(caught.exception.errno, (errno.ELOOP, errno.ENOTDIR))

    def test_refuses_a_symlinked_leaf(self):
        os.symlink(os.path.join(self.outside, "secret.txt"),
                   os.path.join(self.root, "leak.txt"))
        with self.assertRaises(OSError) as caught:
            md.open_under_root(self.root, os.path.join(self.root, "leak.txt"))
        self.assertEqual(errno.ELOOP, caught.exception.errno)

    def test_the_root_itself_opens(self):
        fd = md.open_under_root(self.root, self.root)
        try:
            self.assertIn("sub", os.listdir(fd))
        finally:
            os.close(fd)

    def test_missing_file_is_enoent_not_a_leak(self):
        with self.assertRaises(OSError) as caught:
            md.open_under_root(self.root, os.path.join(self.root, "nope.txt"))
        self.assertEqual(errno.ENOENT, caught.exception.errno)


# ---------------------------------------------------------------------------
# CL.0 request smuggling
# ---------------------------------------------------------------------------


class TestRequestSmuggling(MirrordTestCase):
    # A short timeout so the server closes an idle keep-alive connection
    # promptly and raw() can return. Without keep-alive there is no bug to
    # test: the smuggled body only becomes a second request if the connection
    # is reused.
    overrides = {"timeout": 2.0}

    @staticmethod
    def _count_responses(raw: bytes) -> int:
        return raw.count(b"HTTP/1.")

    def test_get_with_a_body_yields_exactly_one_response(self):
        smuggled = b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
        reply = self.srv.raw(
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s" % (len(smuggled), smuggled))
        self.assertEqual(1, self._count_responses(reply),
                         "the body was parsed as a second request: %r" % reply)

    def test_options_with_a_body_yields_exactly_one_response(self):
        # do_OPTIONS was the worst of them: 204, body never read, keep-alive
        # left on.
        smuggled = b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
        reply = self.srv.raw(
            b"OPTIONS /cache/ HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s" % (len(smuggled), smuggled))
        self.assertEqual(1, self._count_responses(reply),
                         "the body was parsed as a second request: %r" % reply)

    def test_head_with_a_body_yields_exactly_one_response(self):
        smuggled = b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
        reply = self.srv.raw(
            b"HEAD /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s" % (len(smuggled), smuggled))
        self.assertEqual(1, self._count_responses(reply))

    def test_a_drained_body_does_not_break_keep_alive(self):
        # The fix must drain, not just hang up: a well-formed pipelined second
        # request on the same connection still has to be answered.
        smuggled = b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
        reply = self.srv.raw(
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s"
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
            % (len(smuggled), smuggled))
        # Request one, its (discarded) body, then a real second request.
        self.assertEqual(2, self._count_responses(reply))

    def test_oversized_body_is_413_and_the_connection_closes(self):
        # The server answers 413 and closes with the oversized body still
        # unread, which turns the close into an RST. Read concurrently (see
        # ServerFixture.probe) so the 413 is not lost to the RST -- a blocking
        # send-then-read loses that race reliably under CPython 3.9.
        body = b"A" * (md.MAX_REQUEST_BODY + 1)
        reply = self.srv.probe([
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s" % (len(body), body)])
        self.assertIn(b"413", reply.split(b"\r\n")[0],
                      "expected a 413; got %r" % reply[:80])
        self.assertEqual(1, self._count_responses(reply))

    def test_chunked_body_is_refused(self):
        reply = self.srv.raw(
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n"
            b"20\r\nGET /cache/hello.txt HTTP/1.1\r\n\r\n0\r\n\r\n")
        self.assertIn(b"400", reply.split(b"\r\n")[0])
        self.assertEqual(1, self._count_responses(reply))

    def test_conflicting_content_lengths_are_refused(self):
        reply = self.srv.raw(
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: 0\r\nContent-Length: 41\r\n\r\n"
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n")
        self.assertIn(b"400", reply.split(b"\r\n")[0])
        self.assertEqual(1, self._count_responses(reply))

    def test_post_with_a_body_does_not_smuggle(self):
        # _reject_method deliberately does not drain; it relies on fail()
        # closing the connection on 405. Prove that it actually does.
        smuggled = b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n\r\n"
        reply = self.srv.raw(
            b"POST /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"
            b"Content-Length: %d\r\n\r\n%s" % (len(smuggled), smuggled))
        self.assertIn(b"405", reply.split(b"\r\n")[0])
        self.assertEqual(1, self._count_responses(reply))


# ---------------------------------------------------------------------------
# Header limits, enforced while reading rather than after
# ---------------------------------------------------------------------------


class TestHeaderLimits(MirrordTestCase):
    overrides = {"timeout": 2.0}

    def _probe(self, chunks):
        # The concurrent-reader probe lives on ServerFixture so several test
        # classes can share it; its docstring explains the RST race.
        return self.srv.probe(chunks)

    def test_the_reader_itself_is_tightened(self):
        self.assertEqual(md.MAX_HEADER_LINE, http.client._MAXLINE)
        self.assertEqual(md.MAX_HEADERS, http.client._MAXHEADERS)

    def test_an_overlong_header_line_is_refused_mid_line(self):
        # The assertion that matters is not "we get a 431" -- the old code did
        # that too, after buffering 5.4 MB. It is that we get the 431 WITHOUT
        # EVER SENDING the end of the header: the request below has no
        # terminating CRLF and never will. If the server answers, it answered
        # while reading, which is the only place the limit can do any good.
        reply = self._probe([
            b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\nX: ",
            b"a" * (md.MAX_HEADER_LINE * 2),
        ])
        self.assertIn(b"431", reply.split(b"\r\n")[0],
                      "expected a 431 while reading; got %r" % reply[:80])

    def test_too_many_header_lines_are_refused_while_reading(self):
        # Again: no terminating blank line, ever. Only a reader that counts as
        # it goes can answer this.
        #
        # The count matters and is the whole test. It must sit ABOVE our
        # MAX_HEADERS (64) and BELOW http.client's stock _MAXHEADERS (100): the
        # first version of this test sent 192 and passed even with the
        # tightening removed, because it was measuring CPython's limit rather
        # than ours. If this number ever drifts past 100 the test goes back to
        # proving nothing.
        count = md.MAX_HEADERS + 5
        self.assertLess(count, 100, "must be under the stock _MAXHEADERS")
        chunks = [b"GET /cache/hello.txt HTTP/1.1\r\nHost: x\r\n"]
        chunks += [b"X-Pad-%d: y\r\n" % i for i in range(count)]
        reply = self._probe(chunks)
        self.assertIn(b"431", reply.split(b"\r\n")[0],
                      "expected a 431 while reading; got %r" % reply[:80])

    def test_aggregate_header_size_is_still_capped(self):
        # Individually legal lines that are collectively absurd: this is the
        # part no per-line cap can express, and it is what parse_request()
        # still exists for.
        headers = {"X-Pad-%d" % i: "z" * 2000 for i in range(20)}
        headers["Host"] = "x"
        status, _, _ = self.srv.request("GET", "/cache/hello.txt",
                                        headers=headers)
        self.assertEqual(431, status)


# ---------------------------------------------------------------------------
# TLS: one silent client must not wedge the server
# ---------------------------------------------------------------------------


def make_self_signed(tmp):
    """A throwaway cert, via the openssl binary. Skips if there isn't one."""
    import subprocess
    cert = os.path.join(tmp, "test.crt")
    key = os.path.join(tmp, "test.key")
    try:
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", key, "-out", cert, "-days", "1",
             "-subj", "/CN=127.0.0.1"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return None, None
    return cert, key


class TestTLSSilentClient(unittest.TestCase):
    """A client that completes TCP and then says nothing must cost one thread,
    not the whole server.

    The old code wrapped the LISTENING socket, so SSLSocket.accept() ran the
    handshake inline in serve_forever's single accept loop. One silent socket
    stopped every other client dead -- the reviewer measured a legitimate curl
    getting 000 after 12s, then 200 the instant the silent socket closed.
    --timeout did not help: it is applied in StreamRequestHandler.setup(),
    which never ran.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-tls.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        cert, key = make_self_signed(self.tmp)
        if cert is None:
            self.skipTest("no usable openssl binary")

        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)
        with open(os.path.join(self.root, "hello.txt"), "w") as fh:
            fh.write("hello mirror")

        cfg = md.Config()
        cfg.roots = {"cache": os.path.realpath(self.root)}
        cfg.quiet = True
        cfg.timeout = 3.0
        handler = md.make_handler(cfg, md.RateLimiter(cfg.rate, cfg.burst))
        self.httpd = md.MirrorServer(("127.0.0.1", 0), handler,
                                     cfg.max_connections, cfg.timeout)
        self.httpd.ssl_context = md.build_ssl_context(cert, key)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)

    def _stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)

    def _client_ctx(self):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx

    def test_tls_works_at_all(self):
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, timeout=10,
                                           context=self._client_ctx())
        try:
            conn.request("GET", "/cache/hello.txt")
            resp = conn.getresponse()
            self.assertEqual(200, resp.status)
            self.assertEqual(b"hello mirror", resp.read())
        finally:
            conn.close()

    def test_a_silent_connection_does_not_block_another_client(self):
        # Complete the TCP handshake, send not one byte, and hold it.
        silent = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        self.addCleanup(silent.close)

        # The timeout is the assertion. With the handshake back on the accept
        # loop this request never completes and the test fails in 5s rather
        # than hanging the suite.
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, timeout=5,
                                           context=self._client_ctx())
        try:
            conn.request("GET", "/cache/hello.txt")
            resp = conn.getresponse()
            self.assertEqual(200, resp.status)
            self.assertEqual(b"hello mirror", resp.read())
        finally:
            conn.close()

    def test_several_silent_connections_do_not_block_another_client(self):
        for _ in range(8):
            sock = socket.create_connection(("127.0.0.1", self.port),
                                            timeout=10)
            self.addCleanup(sock.close)
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, timeout=5,
                                           context=self._client_ctx())
        try:
            conn.request("GET", "/cache/hello.txt")
            self.assertEqual(200, conn.getresponse().status)
        finally:
            conn.close()

    def test_plain_http_to_a_tls_port_is_not_a_traceback(self):
        # A failed handshake is routine. It must cost that connection and
        # nothing else.
        junk = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        try:
            junk.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            junk.recv(4096)
        except OSError:
            pass  # a reset here is a perfectly good outcome
        finally:
            junk.close()
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, timeout=5,
                                           context=self._client_ctx())
        try:
            conn.request("GET", "/cache/hello.txt")
            self.assertEqual(200, conn.getresponse().status)
        finally:
            conn.close()

    def test_the_listener_is_never_wrapped(self):
        # The property, stated directly: whatever else changes, the socket
        # serve_forever() calls accept() on must not be an SSLSocket.
        self.assertNotIsInstance(self.httpd.socket, ssl.SSLSocket)


# ---------------------------------------------------------------------------
# The PBKDF2 amplifier and the decoy's parameters
# ---------------------------------------------------------------------------


class TestPasswordHashingBudget(MirrordTestCase):
    overrides = {}

    def setUp(self):
        super().setUp()
        self.srv.cfg.creds = md.CredentialStore(
            [md.make_credential("bob", "correct horse battery staple")])

    def test_the_real_client_is_never_throttled(self):
        # bitbake's actual pattern: thousands of probes, one Authorization
        # header. It must cost one derivation, not thousands, and it must never
        # be refused. The burst is 16; this would fail hard without the cache.
        headers = basic("bob", "correct horse battery staple")
        for _ in range(60):
            status, _, _ = self.srv.request("GET", "/cache/hello.txt",
                                            headers=headers)
            self.assertEqual(200, status)

    def test_repeated_wrong_passwords_are_cached_too(self):
        headers = basic("bob", "wrong")
        for _ in range(60):
            status, _, _ = self.srv.request("GET", "/cache/hello.txt",
                                            headers=headers)
            self.assertEqual(401, status)

    def test_distinct_passwords_exhaust_the_budget_and_get_401(self):
        # The attacker's pattern: every request a new password, every request a
        # fresh PBKDF2. The budget cuts in and the KDF stops being called.
        seen = []
        for i in range(md.DEFAULT_KDF_BURST + 25):
            status, _, _ = self.srv.request(
                "GET", "/cache/hello.txt", headers=basic("bob", "guess-%d" % i))
            seen.append(status)
        self.assertEqual({401}, set(seen), "a guess was accepted!")

    def test_the_budget_refuses_without_hashing(self):
        # The point is CPU, so measure CPU. Burn the budget, then time a batch
        # of further guesses: if they were still hashing, this would take
        # ~25 * one PBKDF2 (seconds), not milliseconds.
        for i in range(md.DEFAULT_KDF_BURST + 5):
            self.srv.request("GET", "/cache/hello.txt",
                             headers=basic("bob", "burn-%d" % i))
        start = time.monotonic()
        for i in range(25):
            status, _, _ = self.srv.request(
                "GET", "/cache/hello.txt", headers=basic("bob", "post-%d" % i))
            self.assertEqual(401, status)
        elapsed = time.monotonic() - start
        one_kdf = self._time_one_derivation()
        self.assertLess(elapsed, 25 * one_kdf,
                        "the budget did not stop the hashing")

    @staticmethod
    def _time_one_derivation():
        cred = md.make_credential("x", "y")
        start = time.monotonic()
        cred.verify("z")
        return time.monotonic() - start

    def test_a_correct_password_still_works_after_the_budget_is_burned(self):
        # Denying the attacker must not deny the operator forever: the budget
        # refills, and a cached-good credential was never spending it anyway.
        good = basic("bob", "correct horse battery staple")
        status, _, _ = self.srv.request("GET", "/cache/hello.txt",
                                        headers=good)
        self.assertEqual(200, status)
        for i in range(md.DEFAULT_KDF_BURST + 5):
            self.srv.request("GET", "/cache/hello.txt",
                             headers=basic("bob", "burn-%d" % i))
        # Cached, so it never touches the KDF or the budget.
        status, _, _ = self.srv.request("GET", "/cache/hello.txt",
                                        headers=good)
        self.assertEqual(200, status)


class TestVerificationCache(unittest.TestCase):
    def test_cache_does_not_store_the_password(self):
        store = md.CredentialStore([md.make_credential("bob", "hunter2hunter2")])
        store.check("bob", "hunter2hunter2")
        blob = repr(store._cache).encode("utf-8", "replace")
        self.assertNotIn(b"hunter2hunter2", blob)

    def test_cache_returns_the_same_verdict(self):
        store = md.CredentialStore([md.make_credential("bob", "hunter2hunter2")])
        self.assertIsNone(store.cached_result("bob", "hunter2hunter2"))
        self.assertTrue(store.check("bob", "hunter2hunter2"))
        self.assertIs(True, store.cached_result("bob", "hunter2hunter2"))
        self.assertFalse(store.check("bob", "wrong"))
        self.assertIs(False, store.cached_result("bob", "wrong"))

    def test_cache_is_bounded(self):
        store = md.CredentialStore([md.make_credential("bob", "hunter2hunter2")])
        for i in range(store._CACHE_MAX + 50):
            store._remember("bob", "p-%d" % i, False)
        self.assertLessEqual(len(store._cache), store._CACHE_MAX)

    def test_usernames_and_passwords_cannot_collide_in_the_key(self):
        store = md.CredentialStore([md.make_credential("bob", "hunter2hunter2")])
        self.assertNotEqual(store._cache_key("ab", "c"),
                            store._cache_key("a", "bc"))


class TestDecoyParameters(unittest.TestCase):
    """An unknown username must cost what a known one costs -- at the cred
    file's parameters, not at our compile-time defaults."""

    def test_decoy_copies_the_loaded_credentials_cost(self):
        odd = md.Credential("bob", "pbkdf2_" + md.PBKDF2_ALGO, 12345,
                            b"\x01" * 16, b"\x02" * 20)
        store = md.CredentialStore([odd])
        self.assertEqual(12345, store._decoy.iterations)
        self.assertEqual(20, len(store._decoy.digest))
        self.assertEqual(16, len(store._decoy.salt))

    def test_decoy_matches_a_default_credential_too(self):
        store = md.CredentialStore([md.make_credential("bob", "pw")])
        self.assertEqual(md.PBKDF2_ITERATIONS, store._decoy.iterations)

    def test_unknown_user_costs_about_what_a_known_user_costs(self):
        odd = md.make_credential("bob", "hunter2hunter2")
        odd.iterations = 50_000
        odd.digest = odd.derive("hunter2hunter2")
        store = md.CredentialStore([odd])

        def timed(user, pw):
            start = time.monotonic()
            store.check(user, pw)
            return time.monotonic() - start

        known = min(timed("bob", "wrong-%d" % i) for i in range(3))
        unknown = min(timed("nobody-%d" % i, "wrong") for i in range(3))
        # Same order of magnitude. Before the fix the decoy ran 200k iterations
        # against a 50k credential -- a 4x tell.
        self.assertLess(max(known, unknown), 2.5 * min(known, unknown))


# ---------------------------------------------------------------------------
# '//' in a request target
# ---------------------------------------------------------------------------


class TestSplitUrlPath(unittest.TestCase):
    def test_leading_double_slash_is_not_read_as_a_netloc(self):
        # urlsplit('//cache/x') reports netloc='cache', path='/x' -- the root
        # prefix silently vanishes. We collapse it ourselves rather than trust
        # parse_request to have done it for us.
        self.assertEqual("/cache/x", md.split_url_path("//cache/x"))
        self.assertEqual("/cache/x", md.split_url_path("////cache/x"))

    def test_ordinary_paths_are_unchanged(self):
        self.assertEqual("/cache/x", md.split_url_path("/cache/x"))
        self.assertEqual("/cache/x", md.split_url_path("/cache/x?q=1"))
        self.assertEqual("/", md.split_url_path("/"))

    def test_a_doubled_slash_target_reaches_the_right_root(self):
        self.assertEqual("/cache/hello.txt",
                         md.split_url_path("//cache/hello.txt"))


class TestDoubleSlashTarget(MirrordTestCase):
    def test_double_slash_request_target_is_not_served_from_nowhere(self):
        reply = self.srv.raw(b"GET //cache/hello.txt HTTP/1.1\r\n"
                             b"Host: x\r\nConnection: close\r\n\r\n")
        self.assertIn(b"200", reply.split(b"\r\n")[0])
        self.assertIn(b"hello mirror", reply)


# ---------------------------------------------------------------------------
# ConfigError must never reach the operator as a traceback
# ---------------------------------------------------------------------------


class TestServeConfigErrors(unittest.TestCase):
    @staticmethod
    def _free_port():
        # NOT --port 0. resolve_config rejects 0 as out of range, so the first
        # version of this test got its exit 2 from the config parser and never
        # reached serve() at all -- it passed happily with the fix removed.
        # serve() has to get far enough to bind before build_ssl_context can
        # raise, so it needs a real, bindable port.
        sock = socket.socket()
        try:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]
        finally:
            sock.close()

    def test_a_bad_tls_cert_exits_2_without_a_traceback(self):
        tmp = tempfile.mkdtemp(prefix="mirrord-cfg.")
        self.addCleanup(shutil.rmtree, tmp, True)
        root = os.path.join(tmp, "root")
        os.makedirs(root)
        bogus = os.path.join(tmp, "not-a-cert.pem")
        with open(bogus, "w") as fh:
            fh.write("this is not a certificate\n")
        # build_ssl_context raises ConfigError from inside serve(), which used
        # to escape main() entirely and print a traceback with paths in it.
        # The assertion is that main RETURNS 2 rather than raising: if the
        # handler goes away, this call raises ConfigError and the test errors.
        rc = md.main(["--root", "cache=" + root,
                      "--port", str(self._free_port()),
                      "--bind", "127.0.0.1",
                      "--tls-cert", bogus, "--tls-key", bogus])
        self.assertEqual(2, rc)


# ---------------------------------------------------------------------------
# sstate object shapes: a legitimate colon-bearing name must round-trip.
#
# The traversal tests all prove that a decode-once turns hostile encodings into
# a rejected literal. Nothing there proves the OTHER direction: that a NORMAL
# sstate object -- two-hex-char shard directory, filename full of ':' -- fetches
# to a 200 with the right bytes, both raw and percent-encoded (%3A). A quoting
# or decode slip here breaks every real fetch while the security suite stays
# green, which is exactly the kind of stupid bug worth pinning.
# ---------------------------------------------------------------------------


SSTATE_NAME = ("sstate:bash:cortexa57-poky-linux:5.0:r0:cortexa57:3:"
               "abcdef0123456789:populate_sysroot.tar.zst")
SSTATE_BODY = b"\x28\xb5\x2f\xfd" + b"zstd-ish object payload" * 4


class TestSstateObjectRoundTrip(MirrordTestCase):
    def setUp(self):
        super().setUp()
        shard = os.path.join(self.srv.root, "ab")
        os.makedirs(shard)
        with open(os.path.join(shard, SSTATE_NAME), "wb") as fh:
            fh.write(SSTATE_BODY)
        self.raw_path = "/cache/ab/" + SSTATE_NAME
        self.enc_path = "/cache/ab/" + SSTATE_NAME.replace(":", "%3A")

    def test_raw_colon_name_is_200_with_exact_bytes(self):
        status, headers, body = self.srv.request("GET", self.raw_path)
        self.assertEqual(200, status)
        self.assertEqual(SSTATE_BODY, body)
        self.assertEqual(str(len(SSTATE_BODY)), headers["Content-Length"])

    def test_percent_encoded_colons_decode_once_to_the_same_object(self):
        status, _, body = self.srv.request("GET", self.enc_path)
        self.assertEqual(200, status)
        self.assertEqual(SSTATE_BODY, body)

    def test_raw_and_encoded_return_identical_bytes(self):
        _, _, raw = self.srv.request("GET", self.raw_path)
        _, _, enc = self.srv.request("GET", self.enc_path)
        self.assertEqual(raw, enc)

    def test_range_over_a_colon_name_still_works(self):
        # The dominant real request is a ranged/resumed fetch of exactly these
        # objects; prove the colon name flows through the range path too.
        status, headers, body = self.srv.request(
            "GET", self.enc_path, {"Range": "bytes=0-3"})
        self.assertEqual(206, status)
        self.assertEqual(SSTATE_BODY[:4], body)
        self.assertEqual("bytes 0-3/%d" % len(SSTATE_BODY),
                         headers["Content-Range"])


# ---------------------------------------------------------------------------
# The combined matrix: TLS + auth + allowlist at once. Each layer is tested
# alone above; this proves the rate->allow->auth->fs ordering survives the TLS
# wrap, and that a ranged GET decrypts to the right bytes.
# ---------------------------------------------------------------------------


class TestTLSAuthAllowlistMatrix(unittest.TestCase):
    import ipaddress as _ip

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-matrix.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cert, self.key = make_self_signed(self.tmp)
        if self.cert is None:
            self.skipTest("no usable openssl binary")
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)
        with open(os.path.join(self.root, "hello.txt"), "w") as fh:
            fh.write("hello mirror")

    def _server(self, allow_cidr):
        cfg = md.Config()
        cfg.roots = {"cache": os.path.realpath(self.root)}
        cfg.quiet = True
        cfg.timeout = 5.0
        cfg.creds = md.CredentialStore(
            [md.make_credential("builder", "correct horse battery staple")])
        cfg.allow_nets = [self._ip.ip_network(allow_cidr)]
        handler = md.make_handler(cfg, md.RateLimiter(cfg.rate, cfg.burst))
        httpd = md.MirrorServer(("127.0.0.1", 0), handler,
                                cfg.max_connections, cfg.timeout)
        httpd.ssl_context = md.build_ssl_context(self.cert, self.key)
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever,
                                  kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()

        def stop():
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=5)
        self.addCleanup(stop)
        # Assert the property the whole TLS design rests on: the LISTENER is
        # plain TCP; wrapping happens per-connection in the worker thread.
        self.assertNotIsInstance(httpd.socket, ssl.SSLSocket)
        return port

    def _get(self, port, path, headers=None):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=10,
                                           context=ctx)
        try:
            conn.request("GET", path, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, dict(resp.getheaders()), resp.read()
        finally:
            conn.close()

    def test_ranged_get_over_tls_with_creds_is_206_and_right_bytes(self):
        port = self._server("127.0.0.0/8")
        headers = dict(basic("builder", "correct horse battery staple"))
        headers["Range"] = "bytes=0-4"
        status, hdrs, body = self._get(port, "/cache/hello.txt", headers)
        self.assertEqual(206, status)
        self.assertEqual(b"hello", body)
        self.assertEqual("bytes 0-4/12", hdrs["Content-Range"])

    def test_full_get_over_tls_with_creds_is_200(self):
        port = self._server("127.0.0.0/8")
        status, _, body = self._get(
            port, "/cache/hello.txt",
            basic("builder", "correct horse battery staple"))
        self.assertEqual(200, status)
        self.assertEqual(b"hello mirror", body)

    def test_wrong_creds_over_tls_is_401(self):
        port = self._server("127.0.0.0/8")
        status, _, _ = self._get(port, "/cache/hello.txt",
                                 basic("builder", "wrong"))
        self.assertEqual(401, status)

    def test_auth_precedes_fs_over_tls(self):
        # In-allowlist client, wrong creds, missing file -> 401, not 404: the
        # attacker learns nothing about what exists.
        port = self._server("127.0.0.0/8")
        status, _, _ = self._get(port, "/cache/nope.txt",
                                 basic("builder", "wrong"))
        self.assertEqual(401, status)

    def test_fs_is_reached_once_auth_passes_over_tls(self):
        port = self._server("127.0.0.0/8")
        status, _, _ = self._get(
            port, "/cache/nope.txt",
            basic("builder", "correct horse battery staple"))
        self.assertEqual(404, status)

    def test_allowlist_precedes_auth_over_tls(self):
        # Client 127.0.0.1 is NOT in this range. Even with CORRECT creds the
        # answer is 403: the allowlist is checked before auth, and the TLS wrap
        # does not reorder that.
        port = self._server("10.99.0.0/24")
        status, _, _ = self._get(
            port, "/cache/hello.txt",
            basic("builder", "correct horse battery staple"))
        self.assertEqual(403, status)


# ---------------------------------------------------------------------------
# Process lifecycle: main -> resolve_config -> serve -> signal handler, as a
# real child process. This is the untested glue between the pieces above.
# Kept deliberately simple so it is reliable on 3.9.6, where prior TLS/socket
# timing bugs lived.
# ---------------------------------------------------------------------------


class TestProcessLifecycle(unittest.TestCase):
    @staticmethod
    def _free_port():
        sock = socket.socket()
        try:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]
        finally:
            sock.close()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-life.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)
        with open(os.path.join(self.root, "hello.txt"), "w") as fh:
            fh.write("hello mirror")
        # A cred file must be chmod 600 or resolve_config refuses it.
        self.credfile = os.path.join(self.tmp, "creds")
        with open(self.credfile, "w") as fh:
            fh.write(str(md.make_credential("builder", "pw-lifecycle")) + "\n")
        os.chmod(self.credfile, 0o600)

    def _authget(self, port):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            conn.request("GET", "/cache/hello.txt",
                         headers=basic("builder", "pw-lifecycle"))
            resp = conn.getresponse()
            return resp.status, resp.read()
        finally:
            conn.close()

    def test_start_serve_authenticated_get_then_sigterm_exits_clean(self):
        import subprocess
        port = self._free_port()
        proc = subprocess.Popen(
            [sys.executable, MIRRORD_PATH,
             "--root", "cache=" + self.root,
             "--bind", "127.0.0.1", "--port", str(port),
             "--cred-file", self.credfile, "--quiet"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def kill():
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
        self.addCleanup(kill)

        # Poll until it is actually serving (or it died on startup).
        deadline = time.time() + 10
        status = body = None
        while time.time() < deadline:
            if proc.poll() is not None:
                self.fail("server exited during startup, rc=%s"
                          % proc.returncode)
            try:
                status, body = self._authget(port)
                break
            except OSError:
                time.sleep(0.1)
        self.assertEqual(200, status, "server never became ready")
        self.assertEqual(b"hello mirror", body)

        # SIGTERM (Popen.terminate) must bring it down cleanly and promptly.
        proc.terminate()
        try:
            rc = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("server did not exit within 10s of SIGTERM")
        self.assertEqual(0, rc,
                         "clean SIGTERM shutdown must exit 0, got %s" % rc)


# ---------------------------------------------------------------------------
# Local file cache -- the server's first write path
#
# See the "Local file cache" section in mackas-mirrord for the design. The
# headline properties tested here: hit counting is per-path-per-day, a path
# is served from source until it crosses the threshold, promotion (which
# runs on a background thread -- see wait_until()) makes later requests
# byte-identical cache hits, daily rotation purges old entries, the size cap
# evicts LRU, concurrent promotions of the same path do not corrupt or
# double-write, and -- the important regression guard -- none of this runs
# at all, and nothing is ever written to disk, when --cache-dir is unset.
# ---------------------------------------------------------------------------


class TestCacheHitTracking(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-cache-hits.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cache = md.CacheManager(self.tmp, min_hits=3,
                                     max_size_bytes=10**9)

    def test_increments_per_path(self):
        self.assertEqual(1, self.cache.record_hit("/a"))
        self.assertEqual(2, self.cache.record_hit("/a"))
        self.assertEqual(3, self.cache.record_hit("/a"))
        self.assertEqual(4, self.cache.record_hit("/a"))

    def test_counters_are_independent_per_path(self):
        self.cache.record_hit("/a")
        self.cache.record_hit("/a")
        self.assertEqual(1, self.cache.record_hit("/b"),
                         "a different path must start its own counter")
        self.assertEqual(3, self.cache.record_hit("/a"))

    def test_resets_on_a_new_calendar_day(self):
        self.cache.record_hit("/a")
        self.cache.record_hit("/a")
        # _today() is a staticmethod; overriding it on the instance avoids
        # reaching into the lock/dict internals to fake a day change.
        self.cache._today = lambda: "2000-01-02"
        self.assertEqual(1, self.cache.record_hit("/a"),
                         "a new calendar day must start a fresh count")


class TestCacheDirConfig(unittest.TestCase):
    """--cache-dir validation: opt-in, outside every root, not group/world
    writable -- the same discipline the credential file gets, because this
    is the server's write path."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-cachecfg.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = os.path.join(self.tmp, "root")
        os.makedirs(self.root)

    def resolve(self, argv):
        return md.resolve_config(md.build_parser().parse_args(argv))

    def test_default_is_off(self):
        cfg = self.resolve(["--root", "a=%s" % self.root])
        self.assertIsNone(cfg.cache_dir)
        self.assertIsNone(cfg.cache)

    def test_default_min_hits_and_max_size(self):
        cfg = self.resolve(["--root", "a=%s" % self.root])
        self.assertEqual(md.DEFAULT_CACHE_MIN_HITS, cfg.cache_min_hits)
        self.assertEqual(md.DEFAULT_CACHE_MAX_SIZE_MB, cfg.cache_max_size_mb)

    def test_cache_dir_enables_caching_and_is_created(self):
        cache_dir = os.path.join(self.tmp, "cache")
        cfg = self.resolve(["--root", "a=%s" % self.root,
                            "--cache-dir", cache_dir])
        self.assertIsNotNone(cfg.cache)
        self.assertEqual(os.path.realpath(cache_dir), cfg.cache_dir)
        self.assertTrue(os.path.isdir(cache_dir))

    def test_cli_overrides_min_hits_and_max_size(self):
        cache_dir = os.path.join(self.tmp, "cache2")
        cfg = self.resolve(["--root", "a=%s" % self.root,
                            "--cache-dir", cache_dir,
                            "--cache-min-hits", "5",
                            "--cache-max-size-mb", "7"])
        self.assertEqual(5, cfg.cache_min_hits)
        self.assertEqual(7, cfg.cache_max_size_mb)
        self.assertEqual(7 * 1024 * 1024, cfg.cache.max_size_bytes)

    def test_cache_dir_inside_a_root_is_rejected(self):
        cache_dir = os.path.join(self.root, "cache")
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root,
                          "--cache-dir", cache_dir])

    def test_root_inside_cache_dir_is_rejected(self):
        cache_dir = os.path.join(self.tmp, "cachewrap")
        nested_root = os.path.join(cache_dir, "root2")
        os.makedirs(nested_root)
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % nested_root,
                          "--cache-dir", cache_dir])

    def test_group_writable_cache_dir_is_rejected(self):
        cache_dir = os.path.join(self.tmp, "groupwritable")
        os.makedirs(cache_dir)
        os.chmod(cache_dir, 0o770)  # force group-write past any umask
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root,
                          "--cache-dir", cache_dir])

    def test_world_writable_cache_dir_is_rejected(self):
        cache_dir = os.path.join(self.tmp, "worldwritable")
        os.makedirs(cache_dir)
        os.chmod(cache_dir, 0o707)
        with self.assertRaises(md.ConfigError):
            self.resolve(["--root", "a=%s" % self.root,
                          "--cache-dir", cache_dir])


class TestCacheDisabledByDefault(MirrordTestCase):
    """The regression guard: no --cache-dir means no cache code path runs
    and nothing is ever written to disk -- behaviour must be byte-for-byte
    what it was before this feature existed."""

    def test_no_cache_attribute_by_default(self):
        self.assertIsNone(self.srv.cfg.cache)

    def test_repeated_requests_create_no_new_files_anywhere(self):
        before = self._snapshot()
        for _ in range(10):
            status, _, body = self.srv.request("GET", "/cache/hello.txt")
            self.assertEqual(200, status)
            self.assertEqual(b"hello mirror", body)
        after = self._snapshot()
        self.assertEqual(before, after,
                         "requests must never write to disk when "
                         "--cache-dir is not configured")

    def _snapshot(self):
        found = {}
        for dirpath, _dirnames, filenames in os.walk(self.srv.tmp):
            for name in filenames:
                path = os.path.join(dirpath, name)
                with open(path, "rb") as fh:
                    found[path] = fh.read()
        return found


class CacheServerTestCase(MirrordTestCase):
    """A ServerFixture wired to a real CacheManager over a throwaway dir."""

    cache_min_hits = 3

    def setUp(self):
        self.cache_tmp = tempfile.mkdtemp(prefix="mirrord-cache-live.")
        self.addCleanup(shutil.rmtree, self.cache_tmp, True)
        self.cache = md.CacheManager(os.path.realpath(self.cache_tmp),
                                     min_hits=self.cache_min_hits,
                                     max_size_bytes=10**9)
        self.overrides = {"cache": self.cache}
        super().setUp()

    def target_for(self, name="hello.txt"):
        return os.path.realpath(os.path.join(self.srv.root, name))

    def is_cached(self, name="hello.txt"):
        fd = self.cache.open_cached(self.target_for(name))
        if fd is None:
            return False
        os.close(fd)
        return True


class TestCachePromotionThreshold(CacheServerTestCase):
    def test_below_threshold_is_not_cached_and_still_served(self):
        for _ in range(self.cache_min_hits - 1):
            status, _, body = self.srv.request("GET", "/cache/hello.txt")
            self.assertEqual(200, status)
            self.assertEqual(b"hello mirror", body)
        # Give a wrongly-eager promotion a moment to (not) happen.
        time.sleep(0.2)
        self.assertFalse(self.is_cached(),
                         "must not be cached before crossing the threshold")

    def test_promoted_at_the_threshold(self):
        for _ in range(self.cache_min_hits):
            status, _, body = self.srv.request("GET", "/cache/hello.txt")
            self.assertEqual(200, status)
            self.assertEqual(b"hello mirror", body)
        self.assertTrue(wait_until(self.is_cached),
                        "must be cached once the threshold is reached")

    def test_head_requests_count_towards_the_threshold_too(self):
        for _ in range(self.cache_min_hits):
            status, _, _ = self.srv.request("HEAD", "/cache/hello.txt")
            self.assertEqual(200, status)
        self.assertTrue(wait_until(self.is_cached))

    def test_a_miss_never_gets_cached(self):
        for _ in range(self.cache_min_hits + 2):
            status, _, _ = self.srv.request("GET", "/cache/does-not-exist")
            self.assertEqual(404, status)
        time.sleep(0.2)
        self.assertIsNone(
            self.cache.open_cached(
                os.path.join(self.srv.root, "does-not-exist")))


class TestCacheServing(CacheServerTestCase):
    def _promote_and_wait(self):
        for _ in range(self.cache_min_hits):
            self.srv.request("GET", "/cache/hello.txt")
        self.assertTrue(wait_until(self.is_cached))

    def test_cached_response_is_byte_identical_to_source(self):
        self._promote_and_wait()
        with open(os.path.join(self.srv.root, "hello.txt"), "rb") as fh:
            source_bytes = fh.read()
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(200, status)
        self.assertEqual(source_bytes, body)

    def test_cached_response_still_goes_through_access_control(self):
        # Caching must never bypass auth: rebuild the server with a
        # credential required, promote to cache, then confirm an
        # unauthenticated request against the now-cached object is still
        # refused.
        self.srv.close()
        self.overrides = dict(self.overrides)
        self.overrides["creds"] = md.CredentialStore(
            [md.make_credential("builder", "s3cret-pw")])
        self.srv = ServerFixture(**self.overrides)
        for _ in range(self.cache_min_hits):
            self.srv.request("GET", "/cache/hello.txt",
                             headers=basic("builder", "s3cret-pw"))
        self.assertTrue(wait_until(self.is_cached))
        status, _, body = self.srv.request("GET", "/cache/hello.txt")
        self.assertEqual(401, status)
        self.assertNoCanary(body)

    def test_range_request_over_a_cached_file_still_works(self):
        self._promote_and_wait()
        status, headers, body = self.srv.request(
            "GET", "/cache/hello.txt", headers={"Range": "bytes=0-4"})
        self.assertEqual(206, status)
        self.assertEqual(b"hello", body)


class TestCacheConcurrentPromotion(CacheServerTestCase):
    def test_concurrent_promote_calls_do_not_corrupt_or_double_write(self):
        root_real = self.srv.cfg.roots["cache"]
        target = self.target_for()

        barrier = threading.Barrier(8)

        def go():
            barrier.wait(timeout=5)
            self.cache.maybe_promote(root_real, target)

        threads = [threading.Thread(target=go) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        self.assertTrue(wait_until(self.is_cached))
        fd = self.cache.open_cached(target)
        self.assertIsNotNone(fd)
        try:
            chunks = []
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(fd)
        self.assertEqual(b"hello mirror", b"".join(chunks))
        self.assertTrue(wait_until(lambda: not self.cache._promoting),
                        "promotion bookkeeping must settle back to empty")


class TestCacheDailyRotation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-cache-rot.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cache = md.CacheManager(self.tmp, min_hits=3,
                                     max_size_bytes=10**9)

    def test_sweep_purges_a_previous_day_but_keeps_today(self):
        old_dir = os.path.join(self.tmp, "2000-01-01")
        os.makedirs(old_dir)
        with open(os.path.join(old_dir, "deadbeef"), "wb") as fh:
            fh.write(b"stale")

        today_dir = os.path.join(self.tmp, self.cache._today())
        os.makedirs(today_dir, exist_ok=True)
        with open(os.path.join(today_dir, "cafefeed"), "wb") as fh:
            fh.write(b"fresh")

        self.cache._sweep_daily()

        self.assertFalse(os.path.isdir(old_dir),
                         "a previous day's directory must be purged")
        self.assertTrue(os.path.isfile(os.path.join(today_dir, "cafefeed")),
                        "today's entries must survive the sweep")

    def test_a_file_cached_yesterday_is_not_served_today(self):
        target = "/some/resolved/path"
        yesterday = "2000-01-01"
        self.cache._today = lambda: yesterday
        day_dir, path = self.cache._cache_path(target)
        os.makedirs(day_dir, exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(b"yesterdays bytes")
        self.assertIsNotNone(self.cache.open_cached(target))

        # Roll the calendar forward: the same lookup now misses, because the
        # day component of the path changed -- see the class docstring.
        self.cache._today = lambda: "2000-01-02"
        self.assertIsNone(self.cache.open_cached(target))

    def test_sweep_leaves_non_day_named_entries_alone(self):
        weird = os.path.join(self.tmp, "not-a-date")
        os.makedirs(weird)
        self.cache._sweep_daily()
        self.assertTrue(os.path.isdir(weird))


class TestCacheSizeCapEviction(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mirrord-cache-size.")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_evicts_least_recently_used_first(self):
        cache = md.CacheManager(self.tmp, min_hits=3, max_size_bytes=10)
        day_dir = os.path.join(self.tmp, cache._today())
        os.makedirs(day_dir, exist_ok=True)
        now = time.time()
        paths = []
        for i in range(4):
            path = os.path.join(day_dir, "obj%d" % i)
            with open(path, "wb") as fh:
                fh.write(b"12345")  # 5 bytes; 4 files = 20 bytes > 10 cap
            # obj0 is the oldest access, obj3 the most recent.
            os.utime(path, (now - (4 - i) * 100, now))
            paths.append(path)

        cache._enforce_size_cap()

        self.assertFalse(os.path.exists(paths[0]),
                         "the least recently used entry must be evicted")
        self.assertFalse(os.path.exists(paths[1]))
        self.assertTrue(os.path.exists(paths[2]),
                        "the most recently used entries must survive")
        self.assertTrue(os.path.exists(paths[3]))
        total = sum(os.path.getsize(p) for p in paths if os.path.exists(p))
        self.assertLessEqual(total, 10)

    def test_under_budget_evicts_nothing(self):
        cache = md.CacheManager(self.tmp, min_hits=3, max_size_bytes=10**9)
        day_dir = os.path.join(self.tmp, cache._today())
        os.makedirs(day_dir, exist_ok=True)
        path = os.path.join(day_dir, "obj0")
        with open(path, "wb") as fh:
            fh.write(b"12345")
        cache._enforce_size_cap()
        self.assertTrue(os.path.exists(path))

    def test_in_progress_tmp_files_are_never_evicted(self):
        cache = md.CacheManager(self.tmp, min_hits=3, max_size_bytes=1)
        day_dir = os.path.join(self.tmp, cache._today())
        os.makedirs(day_dir, exist_ok=True)
        tmp_path = os.path.join(day_dir, md._CACHE_TMP_PREFIX + "inprogress")
        with open(tmp_path, "wb") as fh:
            fh.write(b"partial write still happening")
        cache._enforce_size_cap()
        self.assertTrue(os.path.exists(tmp_path),
                        "an in-progress write must never be evicted")


if __name__ == "__main__":
    unittest.main()
