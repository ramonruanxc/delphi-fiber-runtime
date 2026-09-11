# Repository conventions implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development; execute autonomously within the user's existing publication authorization.

**Goal:** Match the Pascal readability, explanatory README and Boss installation conventions of the sibling pool and service-host repositories.

**Architecture:** Preserve runtime behavior and qualified compiler boundaries. Format owned Pascal sources; add package metadata and executable installation examples; verify through the existing tests and real Boss consumers.

**Tech Stack:** Object Pascal/FPC 3.2.2, Boss, Python and GitHub Actions.

**Spec:** User correction on 2026-09-11; sibling READMEs, boss.json and source formatting are the reference. Runtime contracts remain normative.

## Tasks

- [ ] Format first-party Pascal units, includes, tests and demos with two-space indentation, separate statements/blocks and spaced declarations. Preserve tokens, directives and behavior. Add .editorconfig and document style. Split oversized includes only where necessary; do not reformat vendored native code.
- [ ] Rewrite README in the sibling structure/language: purpose, quick example, install with Boss/manual paths, how scheduling/events/stop work, differences from reference execution models, runnable demos, testing and limits. Provide a small compiled QuickStart example; avoid unsupported Delphi claims.
- [ ] Add boss.json; install a pinned official Boss CLI into ignored tools; validate package resolution and compile/run a clean consumer using the installed source, including Unix helper setup. Add reproducible consumer checks to CI where practical.
- [ ] Independently review formatting token preservation and public examples/install instructions. Run full local/hosted checks and clean packages, merge the passing revision, publish corrected version without rewriting existing release assets, verify the documented Boss command against the published version.

## Ownership

Formatter owns existing src/, demo/ and Pascal tests plus style configuration.
Documentation worker owns README, docs/getting-started.md and new demo/QuickStart.dpr.
Controller owns Boss metadata/consumer automation, workflows, release/progress and final verification.
