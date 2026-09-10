# Periodic Prototype Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Track steps using checkboxes.

**Goal:** Publish the first independently testable milestone: a portable fixed-rate 1 kHz scheduling core, native timing demo, strict CI and versioned release artifacts.

**Architecture:** The pure Pascal schedule is independent of clocks and timers. A separate native adapter supplies monotonic microseconds and cancellable absolute-deadline waits. The benchmark is a persistent callback executor using both, and records all cycles including skips.

**Tech Stack:** Object Pascal (FPC 3.2.2 and separately tested Delphi), native OS APIs with a small C helper if needed, Python 3 automation, GitHub Actions.

**Spec:** ../specs/2026-09-10-delphi-fiber-runtime-design.md

## Global constraints

- The primary timing requirement is **periodic service activation every 1 ms (1 kHz)**.
- Maximum practical Delphi and Free Pascal portability, without requiring features exclusive to a recent Delphi release.
- Platform independence through replaceable backends and explicit support levels.
- CI/CD, executable demos, negative builds and reproducible evidence.
- Low-level C/C++ or assembly may be used where justified by compatibility or measurements.
- The first milestone is a portable **1 kHz scheduling experiment**, before a complete fiber runtime.
- Read `docs/periodic-contract.md` for the normative first-milestone API behavior.

## Task 1: Deterministic schedule

Files: `src/FiberRuntime.Schedule.pas`, `tests/ScheduleTests.dpr`.

Produces:
```pascal
type
  TPeriodicTick = record
    Index: Int64;
    DeadlineUs: Int64;
    StartedUs: Int64;
  end;
  TPeriodicSchedule = class
  public
    constructor Create(AEpochUs, APeriodUs: Int64);
    function TryAcquire(ANowUs: Int64; out ATick: TPeriodicTick): Boolean;
    procedure Complete(ANowUs: Int64);
    procedure Cancel;
    function NextDeadlineUs: Int64;
    function StartedCount: Int64;
    function SkippedCount: Int64;
    function IsActive: Boolean;
    function IsCancelled: Boolean;
  end;
```

- [ ] Test before implementation; save the expected red result.
- [ ] Verify 999 us refuses, 1040 us admits index 1/deadline 1000, a second acquire while active refuses, Complete(3200) skips 2 and 3 and NextDeadlineUs returns 4000.
- [ ] Verify idle late acquisition admits only latest due index; cancellation is sticky; completion at exact boundary skips that boundary; backward time, invalid period, overflow and unmatched completion fail without corrupting state.
- [ ] Run `fpc -B -Mdelphi -Sa -Cr -Co -Fusrc -FUbuild/core -obuild/ScheduleTests.exe tests/ScheduleTests.dpr`, then the executable (extension differs on Unix).
- [ ] Add narrowly targeted compile-time negative variants `PROVE_DRIFT` and `PROVE_OVERLAP`; failures have distinct named assertions. Normal builds never enable them.
- [ ] Self-review and commit only owned files. Independent reviewer checks contract and quality.

## Task 2: Native timer adapter

Files: `src/FiberRuntime.Platform.pas`, `native/*` if needed, `tests/PlatformTests.dpr`.

Produces `TPlatformTimer` with `Create`, `Destroy`, `NowUs: Int64`, `WaitUntil(ADeadlineUs: Int64): Boolean`, `Cancel`, `BackendName: string`. `WaitUntil` returns false on sticky cancellation and true only after the monotonic deadline. One waiting owner, concurrent Cancel supported. Caller must join before destruction. Constructor errors release partial resources.

- [ ] Write tests for monotonic readings, no early return, past deadline, cancellation before wait, cancellation from a native worker while waiting, and cleanup.
- [ ] Implement native event-driven waits. Windows: waitable timer plus cancellation event, using remaining time from QPC rather than UTC absolute deadlines. Linux: monotonic timerfd/eventfd with poll. macOS: native monotonic timer/wait and explicit cancellation notification. Avoid polling sleeps.
- [ ] If helper C is necessary, define a small opaque-handle ABI; keep allocations and errors on their originating side. Provide exact build commands to the integration owner.
- [ ] Compile/run on locally available systems and let CI exercise the others. Report unsupported behavior rather than guessing a pass.
- [ ] Commit owned files and submit for independent review.

## Task 3: Benchmark, build runner and CI/CD

Files: `demo/PeriodicDemo.dpr`, `scripts/check.py`, `scripts/report.py`, `tests/test_report.py`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `scripts/package.py`, `tests/test_package.py`.

Consumes the exact schedule and timer interfaces above.

- [ ] Build/check automation creates isolated output directories per variant; compilation failure and timeout are never negative-test success.
- [ ] Benchmark accepts duration in cycles, period in microseconds and callback workload, preallocates measurements, and prints CSV only after timing. Check no overlap through the schedule; record epoch, cycle index, deadline, start and finish, started/skipped totals and backend.
- [ ] Reporter rejects malformed/incomplete/non-monotonic data, computes actual interval and lateness distributions, includes skipped cycles in counts and emits JSON. Without an explicit profile it labels results descriptive.
- [ ] CI matrix installs FPC on Windows, Linux and macOS, builds tests and demo, runs strict negative checks and uploads reports. Add separate compiler jobs only with actual toolchains.
- [ ] Tag-driven CD uses successful checks on that exact revision, packages source plus platform demo/native artifacts, checksums and a documented support matrix. Test packaging from a clean consumer path with spaces.
- [ ] Compile actual Delphi targets available locally; report limitations if they cannot run.

## Task 4: Evidence, review and publication

Files: `README.md`, `LICENSE`, `CHANGELOG.md`, `docs/support-matrix.md`, `docs/verification.md`, `docs/evidence/*`.

- [ ] Record measured results with environment, commit and workload identifiers; distinguish local Windows and WSL from hosted native runners.
- [ ] Final independent review receives full diff and test evidence; fix important findings with scoped regression checks.
- [ ] Use configured gh authentication to create public `ramonruanxc/delphi-fiber-runtime`; publish only project materials, not conversation exports or machine-local paths.
- [ ] Push a reviewed branch, verify hosted jobs, and merge after passing required checks. Validate the release workflow using a prototype version tag after the merge checks pass.
- [ ] Report the actual outcome and limits. Fiber/context work remains the next separately planned milestone, gated by this experiment; do not claim a full virtual-thread runtime exists.
