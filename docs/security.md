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

- **No telemetry, no phone-home.** mackas makes no network calls of its own.
  Network access is only ever the build's own fetches (git/https, driven by
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
  second, not even read-only. The `docker` shim deliberately refuses
  `--privileged`, `--device` and host networking rather than passing them
  through.
- **Input/config safety.** A config file is *sourced as shell*, so it is executed
  only if it is owned by you (or root) and not group/world-writable — file and
  directory both (`config_file_is_safe`). Every setting written into a generated
  file is validated first (`validate_settings` rejects `"`, backticks and control
  characters) so a value cannot break out of the shell or YAML it lands in. The
  git "dubious ownership" workaround is scoped to a generated `GITCONFIG_FILE`,
  never applied globally, and never overrides one you set.

## Supply-chain integrity

- **Pinned, verified toolchain.** `kas-container` is pinned to a specific version
  and **sha256-verified** on download; the container image is pinned by tag. A
  reference clone of kas lives in `kas-upstream/` for reading — the project keeps
  **zero patches to kas**, so there is no vendored, modified upstream to drift.
- **Minimal dependency surface.** The Python components are **stdlib-only**
  (3.7+): no `pip install`, no third-party packages, nothing to compromise via a
  transitive dependency. The rest is POSIX shell plus tools already on a Mac
  (bash, coreutils) and Apple `container`.
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

- Keep TMPDIR/sstate on local storage you trust — a network-backed volume is
  slower *and* corruptible on a link drop (see [storage.md](storage.md)).
- Do not enable the mirror on an untrusted network.
- Treat the OE layers and image contents you build as their own supply-chain
  review; that is out of mackas's scope.
