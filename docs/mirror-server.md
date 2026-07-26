# The mirror server's threat model

How to run `mackas-mirrord` and configure bitbake against it is in
[storage.md](storage.md#http-mirrors--optional-and-not-just-an-nfs-bridge).
This page is about what it defends against, and why it is built the way it is.

`http.server`'s own documentation says it is "not recommended for production
use ... only implements basic security checks". `mackas-mirrord` is a
deliberate hardening of it.

**What it is:** a read-only file server, exposed to a LAN, whose document root
is an **NFS mount whose contents we do not control**. That last point drives
most of the design — anyone who can write to the export is, in effect, a
partial attacker.

**What it protects:** the rest of the mirror host's filesystem, and (weakly)
the cache contents, which are build artefacts rather than secrets.

Where a defence replaced a plausible-but-wrong design that review caught,
this page records both — the wrong reasoning was plausible enough to ship
once, and writing it down is what keeps it from shipping twice.

## Design choices

**Built on `BaseHTTPRequestHandler`, never `SimpleHTTPRequestHandler`.**
Inheriting `SimpleHTTPRequestHandler` would drag in `translate_path()` (whose
path handling this server does not trust), the directory-listing generator
(which leaks the cache's shape), and a `send_head()` whose behaviour would
have to be audited anyway. `BaseHTTPRequestHandler` does request parsing and
nothing else; every filesystem decision is made by code in this file that can
be defended line by line.

**One process, one port, many roots.** The obvious layout is two servers on
two ports (sstate on 8100, downloads on 8101). Instead one process serves
both caches under distinct path prefixes —
`http://host:8100/sstate/...` and `http://host:8100/downloads/...` — because:

- One process means one privilege drop, one TLS context, one credential
  store, one rate limiter, one systemd unit to harden. Two processes means
  two of each, and two chances to get one of them wrong.
- The security-critical code (path resolution) is per-root anyway — it takes
  the root as an argument — so serving N roots costs no extra attack surface,
  just a dict lookup.
- One port is one firewall rule and one TLS certificate.
- bitbake does not care: `SSTATE_MIRRORS` and `SOURCE_MIRROR_URL` are
  independent URLs, and a path prefix distinguishes them as well as a port
  does.

**Privilege drop, in the only correct order.** When started as root with
`--user`, the drop is `setgroups()` → `setgid()` → `setuid()`, and the order
is the whole point. `setuid()` first is the classic bug: it discards the root
privilege that `setgid()` and `setgroups()` require, so the later calls fail
(silently, if unchecked) and the process keeps root's group memberships —
including the supplementary groups — while looking unprivileged; anything
readable by group root stays readable. `setgroups()` must precede `setgid()`
for the same reason: it needs `CAP_SETGID`, which `setgid()` to a non-root
group gives away. The result is verified afterwards rather than trusted — a
partial drop is worse than none, because it looks safe in `ps` and is not —
and the drop is irreversible (`setuid`, not `seteuid`): a post-drop
`setuid(0)` must fail, and that too is checked.

**Standard library only, Python 3.7+.** The server must run on a host with no
pip, no venv, no network install step — scp one file and go.
(`ThreadingHTTPServer` landed in 3.7.)

## Filesystem containment

| Threat | Defence |
|---|---|
| Path traversal (`../`, `%2e%2e%2f`, double-encoded, absolute, NUL, backslash) | The URL is decoded **once** (decoding twice is what makes double-encoding work), `..` segments are **refused** rather than normalized, and the result is `realpath`'d. This is a cheap first gate, not the containment mechanism — see the TOCTOU row. |
| Prefix confusion (`/root-evil` vs `/root`) | Containment is checked with `os.path.commonpath`, never `str.startswith` — `'/root-evil/x'.startswith('/root')` is `True`, and that one line is a complete escape. |
| Symlink escape from the NFS export | `realpath` resolves every component before the containment check, so a link to `/etc/shadow` fails it. **Escaping symlinks are always refused**; symlinks that stay inside the root are allowed by default because `DL_DIR` legitimately has them, and `--no-symlinks` refuses those too. |
| TOCTOU between the check and the open | `open_under_root()` walks from a descriptor on the root, one component at a time (`O_NOFOLLOW\|O_DIRECTORY`, `dir_fd=parent`), closing each parent as it descends, then opens the leaf `O_NOFOLLOW\|O_NONBLOCK` and `fstat`s the descriptor. **The resolved path is never re-opened by string.** |
| A FIFO or device dropped in the export | `S_ISREG` on the fstat; `O_NONBLOCK` on the leaf open so a FIFO cannot hang the thread. |

### Why `O_NOFOLLOW` on a resolved path is not containment

The plausible design — `realpath()` the URL, check containment, then open the
already-resolved path with `O_NOFOLLOW` (which "by construction contains no
symlinks") and `fstat` the descriptor — is wrong, and review caught it.
**That reasoning was the bug.** `O_NOFOLLOW` governs the **final** component
only; the kernel resolves every intermediate directory, following symlinks,
as normal. An attacker who can write to the export can swap an intermediate
*directory* for a symlink between `realpath()` and `open()`, and the open
walks straight through it — demonstrated, leaking a secret in four requests.
On NFS the window is wide: `realpath` costs a round trip per component.

The `dir_fd` walk in the table makes containment structural rather than
checked-and-hoped: every step is relative to a descriptor already held, so
there is no name for the kernel to re-resolve and nothing to swap — a
descriptor keeps pointing at its inode even if the directory entry that
produced it is replaced a microsecond later. `O_NOFOLLOW` on *every*
component means a symlink appearing anywhere in the chain is refused
(ELOOP). The decode-once / refuse-`..` / `commonpath` gate is kept as a
cheap plausibility check that rejects most hostile paths without an
`open()`.

`openat2(RESOLVE_BENEATH)` would do this in one syscall, but it is Linux 5.6+
only with no stdlib binding; the walk is pure stdlib and behaves identically
on the Linux mirror host and on macOS, where the tests run.

Symlink semantics are unaffected by the walk: it descends the components of
the *realpath output*, not of the URL, so an intra-root symlink was already
resolved and is served, an escaping one was already refused, and a symlink
appearing *after* the check is the attack, and is refused.

### Cost of a miss

The sstate **miss** is the dominant request pattern — bitbake probes
thousands of objects that do not exist — so a miss is: walk, `ENOENT`, `404`.
No `stat`, no `listdir`, no body. The `dir_fd` walk costs one open **per path
component** (typically three: root, hash-prefix directory, leaf) rather than
a single `open()`. That is the price of containment, it is bounded by path
depth, and it is small next to the `realpath()` the check already does — both
are O(components) round trips on NFS.

The server speaks HTTP/1.1 with `Content-Length` set on every response so
keep-alive works — bitbake issues its probe stream over held connections, and
a fresh TCP (and TLS) handshake per probe would otherwise be most of a miss's
cost.

## Credentials and auth

| Threat | Defence |
|---|---|
| Credential theft from disk | The password is stored as a salted PBKDF2-SHA256 hash (200k iterations), never plaintext. The daemon **refuses to start** if the credential file is group/world-accessible. |
| Credential theft from `ps` | The password never goes on argv (`/proc/PID/cmdline` is world-readable). `--hash-password` prompts; the daemon reads a file, or an env var as second-best. |
| Timing attacks on the password | `hmac.compare_digest`, never `==`. An unknown username burns a decoy derivation, so latency is not a username oracle. The decoy copies its cost from a real loaded credential rather than from our own defaults, so a cred file with different parameters cannot make it cheaper or dearer than the real thing. |
| **PBKDF2 as a CPU amplifier** | A verification cache plus a per-IP KDF budget (`--kdf-rate` 4/s, burst 16). See below. |
| Password sniffing | **Basic auth over plain HTTP sends the password in the clear.** Use `--tls-cert/--tls-key` (TLS 1.2 minimum) or rely on the IP allowlist on a trusted LAN. |
| Unauthorized clients | HTTP Basic **and/or** an `ipaddress`-based CIDR allowlist. Allowlist-only is supported and reasonable on a trusted wired LAN. Auth runs **before any filesystem access**, so an unauthenticated client cannot even learn whether a file exists. |

### The verification cache and the KDF budget

Verified naively, every request carrying an `Authorization` header costs a
full 200k-iteration PBKDF2 — on the order of 0.1s of CPU — before anything is
known about the client: one cheap HTTP request buying 0.1s of CPU, ~34 req/s
to peg a core, with the general rate limiter off by default. The KDF being
slow is its point; being slow on demand, for anyone, is the bug — and that
naive version is what review found.

The **verification cache is what makes budgeting the KDF safe.** bitbake is
a legitimate flood: thousands of sstate probes carrying the identical
`Authorization` header, so rate-limiting derivations alone would 401 a real
build. With the cache that flood costs exactly **one** derivation and every
later probe is a dict lookup; a per-IP budget on actual derivations only ever
bites a client trying *distinct* passwords — the attacker, never bitbake.

What is cached is a keyed hash, not the password: HMAC-SHA256 of `user:pass`
under a per-process random secret (length-prefixed, so `("ab","c")` and
`("a","bc")` cannot collide). Entries expire (300s TTL), the table is bounded
at 1024 so it cannot be grown into a memory attack, and both hits and misses
are cached.

Over budget returns a **plain 401 — the same answer a wrong password gets,
not a 429**, which would let an attacker distinguish "throttled" from
"wrong". The event is logged so an operator can see it.

Known residual leak: a cache hit is fast and a miss is slow, so an attacker
can distinguish "this exact pair was tried recently" from a fresh one. That
leaks nothing about whether a username exists or a password is right — the
decoy still equalises that — and it is a good trade for removing the
amplifier.

## Protocol and resource handling

| Threat | Defence |
|---|---|
| Writes triggered by a client | Only `GET`/`HEAD`/`OPTIONS` exist. Everything else is `405` with a correct `Allow`. No request body is ever opened as a file and no request path is ever passed to an `open(..., "wb")`/`unlink()`. (`--cache-dir`, opt-in and off by default, adds ONE internal write path — see below — but it is still true that nothing a client sends can become a filename or trigger a write directly.) |
| Directory-shape disclosure | **Listings off by default** — a listing of an sstate cache is a map of every package, version and hash the host has ever built. |
| Version-banner recon | `Server: mackas-mirrord`. No `Python/3.13.5`. |
| Stack traces / reflected XSS | `send_error` is replaced entirely: a fixed, input-free body per status code. Nothing the client sends is ever echoed. Tracebacks go to the log. |
| Log injection | Every logged path/method is escaped to printable ASCII, so a client cannot forge a log line or inject a terminal escape. |
| Slowloris | A socket timeout (30s default) evicts a stalled connection. It is armed on the raw socket at `accept()` time, not in the handler. |
| Thread exhaustion | `ThreadingHTTPServer` with `daemon_threads` **plus a hard connection cap** — a semaphore, because ThreadingHTTPServer alone spawns a thread per connection until the box dies. |
| **TLS handshake wedging the accept loop** | The listening socket stays plain TCP; the handshake runs in `process_request_thread()`, in a worker. See below. |
| **Request smuggling (CL.0 desync)** | Bodies on bodyless methods are read and discarded before any response. See below. |
| Request-line/header floods | `http.client._MAXLINE`/`_MAXHEADERS` are set at import: ~512 KiB/connection instead of ~6.6 MB. See below. |
| Request floods | An optional per-IP token bucket, **off by default**: bitbake legitimately fires thousands of sstate probes as fast as it can, and a limit that stops an attacker also throttles the one client this exists to serve. It is a blunt instrument, not a WAF, and useless against a distributed source. (The KDF budget above is separate, and *is* on by default — it can be, because bitbake does not brute-force passwords.) |

### TLS off the accept loop

The natural TLS implementation — `httpd.socket = ctx.wrap_socket(httpd.socket,
server_side=True)`, wrapping the **listening** socket — is wrong, and shipped
once. It turns `SSLSocket.accept()` into "accept, then run the whole
handshake inline" — in `serve_forever`'s single accept loop. One client that
completed the TCP handshake and then sent zero bytes blocked that loop
forever, and with it every other client. Not slow: stopped. `--timeout` did
not help (applied in `StreamRequestHandler.setup()`, which never ran); the
connection cap did not help (downstream of the block).

The handshake therefore runs in the worker thread — not in `get_request()`,
which still runs on the accept thread. The accept loop only ever does
`accept()`, and the handshake happens under the semaphore, already counted
against `--max-connections`, so a flood of open-and-go-silent clients costs
the same as any other slow client instead of being a server-wide off switch.
The accept-time socket timeout arms the deadline before `wrap_socket()`
starts talking.

### Bodies on bodyless methods

No method here takes a body, so no handler ever calls `rfile.read()` — and a
handler that simply ignores bodies is exploitable, as review found. A GET
with `Content-Length: 6` and a body was answered normally, keep-alive stayed
on, and the six unread bytes sat in the socket buffer — where the next loop
of `handle_one_request()` parsed them as a **brand-new request line**. One
request in, two responses out: a smuggling primitive — a proxy or load
balancer in front counts one request where the server counts two, and the
attacker chooses what the second says. `do_OPTIONS` was the worst case: 204,
no body read, connection kept alive.

The rule is that nothing reaches a response until the body is off the socket
or the connection is closed:

| Request | Answer |
|---|---|
| `Content-Length` ≤ 64 KiB | Read and discarded, then handled normally. |
| `Content-Length` > 64 KiB | `413` + close. We will not read megabytes to be polite about a body that should not exist. |
| `Transfer-Encoding` present | `400` + close. A dechunker we do not need is a parser differential we do not want, and the framing is now unknowable. |
| Conflicting `Content-Length` headers | `400` + close. Two lengths exist only to make us and a proxy disagree. |

It runs after `check_access()`, so an unauthenticated client is still refused
before we read anything — every failure path sets `close_connection` on
status ≥ 400, so a smuggled body dies with the connection.

### Header memory

Checking header limits in `parse_request()` cannot bound memory, though a
comment once claimed it did: by the time `parse_request()` can look at
`self.headers`, `http.client.parse_headers()` has already read the whole
header block — up to `_MAXHEADERS` (100) lines of `_MAXLINE` (65536) bytes
each, **~6.6 MB per connection buffered before the first check runs**, ~420 MB
an unauthenticated client could pin at `--max-connections 64`. A 431 sent at
that point is an autopsy, not a defence.

The limits have to be enforced by the loop doing the reading, and its only
knobs are `http.client`'s two module globals. mackas-mirrord sets them at
import (8 KiB × 64), giving **~512 KiB/connection, 32 MB at the default
cap**. `MAX_HEADER_BYTES` (16 KiB total) is still checked afterwards.

Touching a private global is a real trade:

- **The alternatives are worse.** `MessageClass` is handed to the email
  parser only after `_read_headers()` has buffered everything, and
  `http.server` calls `parse_headers()` inline — bounding the read without a
  private name means reimplementing `parse_request()` wholesale, and a
  hand-rolled HTTP header parser is a far bigger liability than an
  underscore.
- **The blast radius is nil.** The globals affect `http.client`, and this
  single-purpose daemon never acts as an HTTP *client*.
- **It fails safe.** A `hasattr()` guards each; if a future CPython renames
  them, the tightening is skipped and we are back to the stock 6.6 MB —
  worse, but not broken. A regression test asserts the tightening works, so
  we find out.

## The local file cache (`--cache-dir`) — the server's first write path

Off by default. When `--cache-dir` is unset, none of this code runs and
behaviour is byte-for-byte that of a server without the feature — asserted by
a regression test (`TestCacheDisabledByDefault`), not just claimed.

**What it does:** once a resolved object has been requested more than
`--cache-min-hits - 1` times today (default 3, i.e. "more than 2"), a
background thread copies it into `--cache-dir` and later requests for that
object are served from the local copy instead of the (possibly slow)
NFS/SMB-mounted root.

**Why this is safe to add to a "no write path" server:**

| Property required | How it holds |
|---|---|
| No client input reaches the write | The only path ever written is the one `resolve_under_root()` already validated and `open_under_root()` already opened for THIS response — the same fully-resolved real path, reused, not re-derived from the URL. The on-disk cache filename is `sha256(that real path)`, a string this server computed, never one a client sent. |
| The cache dir cannot become a new escape route | `--cache-dir` is validated like a root (`realpath`'d, must exist or be creatable) plus checked against every `--root` with `os.path.commonpath` in both directions: a cache dir may not be inside a root (which would let a cached copy be re-served as ordinary root content) and a root may not be inside a cache dir (which would let cached copies be fetched directly, bypassing the hit-count policy). |
| The write path itself cannot be hijacked | The cache dir gets the same discipline as the credential file: the daemon refuses to start if it is group- or world-writable, because anyone who can write there can plant a file that is served as though it were a legitimate cache hit. |
| A partial write is never served | Every cache write is `mkstemp()` in the same day-directory as the final name, written in full, then `os.replace()` — an atomic same-filesystem rename. A reader either does not find the file yet (falls back to source) or finds it fully written; there is no window with a partial file under the final name. A crash mid-write leaves an orphaned temp file, never a corrupt one served. |
| Caching cannot become a way to skip auth/allowlist/rate-limiting | A cache hit is served by `serve_file()`, which is reached only after `check_access()` has already run for that request — exactly the same as a source-root response. A regression test (`test_cached_response_still_goes_through_access_control`) asserts it. |
| The dominant sstate-MISS path stays exactly as cheap | Hit-count bookkeeping happens only AFTER the source open confirms a regular file exists — never for a 404. Counting misses too would grow the hit-tracking table by one entry per distinct object bitbake ever probed for (almost all of which never exist), which is unbounded; counting only confirmed hits bounds it by the number of objects this mirror actually ever serves. |
| Promotion never adds latency to the triggering request | The copy runs on a background thread, bounded by a small semaphore (default 4 concurrent), never on the thread answering the request that crossed the threshold. That request is served from the source root exactly as before; only later requests see the cache. |

**Eviction is hybrid, and deliberately so:**

* **Daily rotation** is what keeps steady-state size down. Cached objects
  live at `<cache_dir>/<YYYY-MM-DD>/<hash>`; a promotion lazily sweeps away
  every day-directory that is not today's (a `shutil.rmtree` of a handful
  of directories, not a per-file scan), and — independent of the sweep — a
  file cached yesterday is simply never found by today's lookup, because
  the day component of its path has changed. The trigger is "on cache
  writes", not a timer thread: a write already means "we are touching this
  filesystem", so idle periods cost nothing.
* **The size cap** (`--cache-max-size-mb`, default 4096 MiB / 4 GiB) is the
  backstop *within* a single day: it evicts least-recently-used objects,
  oldest access time first, once the cache exceeds the cap. "Recently used"
  is `atime`, bumped explicitly by this server on every cache hit rather
  than relied on from the filesystem, because `noatime` is a common,
  reasonable mount option this code must not assume against. `mtime` is
  deliberately NOT used for recency — a cached copy's `mtime` mirrors the
  *source* file's `mtime`, so `Last-Modified`/`If-Modified-Since` behave
  identically whether a response comes from cache or from the root.

**Not defended against, stated plainly (same spirit as the section below):**
an operator who points `--cache-dir` at a filesystem too small for
`--cache-max-size-mb`; a `--cache-dir` on the same slow NFS/SMB mount the
cache exists to route around (defeats the purpose, is not checked for); disk
exhaustion between an eviction pass and the next write, which is handled the
same way any other write failure here is — logged, the promotion abandoned,
the request still served from source.

## Correctness notes

- **`If-Modified-Since` works** — implemented explicitly, since the server is
  built on `BaseHTTPRequestHandler` and does *not* inherit
  `SimpleHTTPRequestHandler`.
- **`Range` works too**, and is a genuine addition:
  `SimpleHTTPRequestHandler` does not implement `Range` at all, it ignores
  the header and sends the whole body. Single ranges are supported (the only
  form wget sends); multi-range falls back to `200`, as RFC 7233 allows.

## Not defended against, stated plainly

A hostile client on the allowlist; a distributed flood; anyone who can
already write to the NFS export replacing a *legitimate* cache object with a
malicious one (bitbake's own sstate hashing guards that, not this server);
and, without TLS, a passive network attacker reading the password.
