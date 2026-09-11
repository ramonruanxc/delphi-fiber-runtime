# Pascal conventions and Boss installation — 2026-09-11

Published [v0.3.1-prototype.1](https://github.com/ramonruanxc/delphi-fiber-runtime/releases/tag/v0.3.1-prototype.1)
at `cd66c5610590fea7432814aaff32de535a512247` through
[PR #4](https://github.com/ramonruanxc/delphi-fiber-runtime/pull/4).
The previous release and its evidence remain unchanged.

## Readability and examples

The formatting commit `fb9796f` was compared independently with `2baa953`:
38 original Pascal files and 42,020 tokens match after expanding the three
new routine includes. String literals, directives and meaningful comment text
are preserved. The resulting 41 formatted files have no tabs and at most
419 lines. QuickStart was added separately with the same two-space style.

README and the [getting-started guide](../getting-started.md) now explain
services, cooperative waits, events, ownership, stop results and installation.
QuickStart runs a periodic publisher and a subscription on the same carrier.
Its checked shutdown requires settled event accounting and no task faults.

## Executed checks

- [Branch CI](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34610685162)
  and [PR CI](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34610691131)
  passed on Windows, Linux, macOS ARM64 and macOS Intel at `1608e67`.
- [Merged revision CI](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34610971141)
  and the [release workflow](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34611036616)
  passed on all four targets at the published revision.
- Each full check runs 47 Python tests, nine Pascal suites, named negative
  builds, descriptive benchmarks and QuickStart. Packaging compiles and runs
  four demos from an extracted source archive in a path with spaces.
- Local Windows x64 FPC 3.2.2 checks and packaging passed at `1608e67`.
  Windows x86 and WSL Linux also compiled and ran the installed Boss example.

An existing resume test initially failed on macOS Intel because its condition
pump had a 1 ms wall safety budget. A deliberate 20 ms pause reproduced exactly
`SCHEDULER_CONDITION_SETTLED`; a 2 s safety budget then passed. Exact virtual
time, retained-task and trace assertions remain unchanged. This is a test-only
preemption fixture, with no change to production scheduling.

## Boss and downloaded release

Boss 3.0.17 is checksum-pinned in the consumer automation. Every release CI host
requested the tag and obtained its matching revision while tag and `main`
coincided. Each verified its own cache revision and compared all 121 exported
source files before building and running the installed example.
The consumer's parent repository cannot substitute for dependency provenance.

Plain `boss install github.com/ramonruanxc/delphi-fiber-runtime` and a
`0.3.1-prototype.1` dependency constraint were initially executed locally while
the tag and `main` identified the same revision. Both delivered five messages,
reported zero discarded/aborted deliveries and completed checked shutdown.

After `main` advanced to documentation commit `87bac23`, the constrained
installation incorrectly retrieved that newer revision instead of `cd66c56`.
Its cache HEAD and newly installed documentation confirmed the mismatch, and
the consumer verifier rejected it. Boss 3.0.17 therefore does not qualify as
a reproducible version pin. The guide now uses a tagged clone or release source
ZIP for exact revisions; the plain Boss installation remains verified.
Version `0.3.2-prototype.1` updates package metadata and this installation
guidance. Its production runtime and verification code match `cd66c56`.

After publication, all five ZIPs and their SHA-256 file were downloaded again.
The source archive matched all 121 tracked files from the tag. The four native
archives matched the expected OS/CPU pairs, all 16 executable hashes and the
MIT/Boost notices. All four downloaded Windows x64 demos were then executed
successfully, including QuickStart.

These are functional and installation results for FPC 3.2.2. They do not add
Delphi qualification, hard 1 ms guarantees or physical suspend/resume evidence.
