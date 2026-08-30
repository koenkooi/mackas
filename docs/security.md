# Security posture (and CRA readiness)

How mackas is built to keep security risk low, and how those choices relate to
the security expectations of regulations such as the EU **Cyber Resilience Act
(CRA)**. To *report* a vulnerability, see [SECURITY.md](../SECURITY.md).

mackas is free software (GPL-3.0-or-later) and a developer tool — it drives
[kas-container](https://github.com/siemens/kas) OpenEmbedded builds on
macOS via Apple's `container` runtime. It is not a commercial product shipped to
end users. The CRA framing below is *readiness*, not a compliance claim; the
maintainer should confirm it before relying on it.

## Scope

**In scope** — the code this repository ships: `mackas` (the CLI), `bin/docker`
(the runtime shim) and their generated files (`env.sh`, `gitconfig`, the
`kas/macos-local.yml` fragment); `mirror-server/mackas-mirrord` (the optional
HTTP mirror server); `mackas-uibridge/` (the optional live-progress bridge); and
the `tools/` scripts.

**Out of scope** — depended-on components, reportable to their own projects:
Apple `container` and the macOS Virtualization framework; kas / kas-container;
bitbake, OpenEmbedded-core and the layers a build pulls in; the contents of the
images a build produces; and the third-party OE layers or sources a build
fetches. mackas orchestrates these; it does not vouch for them.

## Security by design and default

- **No telemetry, no phone-home.** mackas never reports anything about you or
  your builds to anyone. The network it uses on its own account is short,
  named and inspectable: `setup` downloads the pinned, sha256-verified
  `kas-container` and runs `container image pull` for the pinned kas image;
  `check` probes `https://ghcr.io/v2/` for reachability, and — only when you
  have configured them — HEADs the HTTP mirror and pings the NFS server.
  Everything else is the build's own fetches (git/https, driven by
  kas/bitbake) and, if you explicitly enable it, the optional mirror.
- **No default secrets or open ports.** The two network-facing pieces are both
  off by default. The mirror server, when enabled, warns loudly unless the
  operator configures a credential or an IP allowlist (allowlist-only is a
  supported, stated trade on a trusted LAN). The live-progress bridge
  (`MACKAS_MONITOR=1`) publishes an unauthenticated, read-only JSON status feed
  from inside the build's own container for that one build's lifetime — see
  below.
- **Least privilege.** Builds run inside Apple `container` micro-VMs, not on the
  host. Each ext4 build volume is mounted by exactly one VM at a time — never a
  second, not even read-only. The `docker` shim never forwards `--privileged`
  (it is dropped before the call reaches Apple `container`), and hard-refuses
  `--device` and `--network host` rather than guessing a translation.
- **Input/config safety.** A config file is *sourced as shell*, so one mackas
  finds on its own (`~/.config/mackas/config`, `~/.mackas.conf`) is executed
  only if it is owned by you (or root) and not group/world-writable — file and
  directory both (`config_file_is_safe`); one you name yourself with
  `--config` or `$MACKAS_CONF` is deliberately exempt, being a request rather
  than an ambush. `./mackas.conf` is *not* in the search path at all, for the
  same reason: a cwd-relative config any untrusted tree could drop in was code
  execution needing no exploit. Every value written into a generated
  file is validated first (`validate_settings` rejects `"`, backticks and control
  characters) so a value cannot break out of the shell or YAML it lands in —
  including the undocumented `MACKAS_BREW_BIN` test seam, which is not a
  setting but is still an input, and reaches both generated shell files. The
  git "dubious ownership" workaround is scoped to a generated `GITCONFIG_FILE`,
  never applied globally, and never silently changes one you set — if your own
  `GITCONFIG_FILE` is missing, or lacks `safe.directory = *`, `setup` asks
  before writing or appending it.

## Supply-chain integrity

- **Pinned, verified toolchain.** `kas-container` is pinned to a specific version
  and **sha256-verified** on download; the container image is pinned by tag. A
  reference clone of kas lives in `kas-upstream/` for reading — the project keeps
  **zero patches to kas**, so there is no vendored, modified upstream to drift.
  That pin applies specifically to `$MACKAS_BIN/kas-container.real`, the
  downloaded file; the small protection wrapper script mackas generates
  alongside it at `$MACKAS_BIN/kas-container` is **locally generated, not
  downloaded or hash-pinned the same way**, and is held to the same
  interpolation-safety rules (`shq()`/safe quoting) as the other generated
  files this repo already writes, such as `env.sh`.
- **Minimal dependency surface.** The Python components are **stdlib-only**
  (3.7+): no `pip install`, no third-party packages, nothing to compromise via a
  transitive dependency. The rest is POSIX shell plus tools already on a Mac
  (bash, coreutils) and Apple `container`. One fetch is worth naming: when
  `volume fsck` finds no host-side `e2fsck` it falls back to a throwaway
  container and `apt-get install`s `e2fsprogs` there — from Debian's repos,
  unpinned. That install lives and dies with the one container and never
  touches the host; having e2fsprogs on the host, or pointing
  `MACKAS_FSCK_IMAGE` at an image that already has it, skips both entirely.
- **SBOM.** The dependency set is small and enumerable — bash 3.2, GNU coreutils
  (`realpath`), Apple `container`, the pinned `kas-container` (hash recorded in
  the source), the pinned kas container image, and Python 3.7+ stdlib. A
  machine-readable SBOM is *not yet generated* (aspirational; a good first issue).

## The optional network-facing components

Both are optional and off by default; you opt in.

`mackas-mirrord` is the hardened one: it serves read-only, confines all file
access beneath its configured roots (no path traversal), supports TLS, uses a
PBKDF2-derived credential with constant-time comparison, and bounds request
headers and bodies.

The live-progress bridge (`mackas-uibridge/mackasjson.py`, enabled with
`MACKAS_MONITOR=1`) is deliberately smaller in surface: it emits **one
generated JSON document** and never reads an arbitrary path off disk, so it has
no traversal surface to harden. It runs *inside* the build's container and is
published to the host with Apple `container`'s `-p`; it has **no auth and no
TLS** — acceptable only because it is a read-only, single-machine status feed
alive for one container's lifetime, opt-in, and never on by default. Do not
enable it where the published port is reachable by something you do not trust.
Its `MACKAS_MONITOR_PORT` is validated as an integer before it reaches
`--runtime-args` (same injection guard as `MACKAS_CPUS`/`MACKAS_MEMORY`).

## Secure updates

Because the tool is a single script plus a single-file server, "update" means
`git pull`; there is no bundled auto-updater to subvert, and the one artifact it
downloads (`kas-container`) is hash-checked on every fetch.

## Hardening you own

- Keep TMPDIR/sstate on local storage you trust — an SMB-backed working volume
  is slower *and* has corrupted real builds (see [storage.md](storage.md)).
- Do not enable the mirror on an untrusted network.
- Treat the OE layers and image contents you build as their own supply-chain
  review; that is out of mackas's scope.
