# Contributing

[AGENTS.md](AGENTS.md) is the real guide — build/test commands, the hard
invariants, testing discipline, commit style. Read it before sending a
change; this file is just the two things worth saying up front.

- **Be terse.** Commit message bodies and code comments should be short —
  a few sentences of *why*, not a walkthrough. AGENTS.md's own style
  section says the same thing; it applies to human contributors too.
- **Run `./run-tests.sh` before every commit**, and keep docs (`docs/`,
  `README.md`) updated in the same commit that makes them stale, not a
  follow-up.

Security issues: see [SECURITY.md](SECURITY.md).
