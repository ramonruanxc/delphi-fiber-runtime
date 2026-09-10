# Context Experiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal:** Publish the next independently testable milestone: stackful cooperative tasks with explicit compiler/RTL qualification and reproducible evidence.

**Architecture:** The existing timer/schedule remains independent. Pascal owns task lifecycle, cancellation, error containment and task-local state. Windows native fibers and a pinned Boost.Context C ABI on Unix own machine contexts; a compiler-specific adapter preserves the FPC exception-address chain where needed.

**Tech Stack:** FPC 3.2.2; Windows fiber APIs; C11/Boost.Context assembly; Python; GitHub Actions.

**Spec:** `../specs/2026-09-10-delphi-fiber-runtime-design.md`, sections 6 and 10; normative API in `../../context-contract.md`.

## Global constraints

- Maximum practical Delphi and Free Pascal portability, without requiring features exclusive to a recent Delphi release.
- Platform independence through replaceable backends and explicit support levels.
- Low-level C/C++ or assembly may be used where justified by compatibility or measurements.
- Initially, a stackful task remains assigned to one carrier for its lifetime.
- Never delete a live stack or force termination to claim successful shutdown.
- FPC execution does not validate Delphi; experimental context support is gated separately from periodic support.
- User approval to continue the approved sequence and use configured GitHub CLI includes implementation, reviewed publication and a prerelease.

## Task 1: Native context boundary

Files: `native/context/*`, including pinned third-party source/license/provenance.

Produces the C ABI (all errors as positive errno values; create returns NULL and errno):
```c
typedef struct fr_context fr_context;
typedef void (*fr_context_entry)(void *);
fr_context *fr_context_create(fr_context_entry entry, void *data, size_t stack_bytes);
int fr_context_resume(fr_context *ctx);
int fr_context_yield(fr_context *ctx);
int fr_context_destroy(fr_context *ctx);
const char *fr_context_backend(void);
```

- [x] Write a native test with nested yield, automatic variables, alternating contexts, forbidden suspended destruction, owner-thread rejection and completion.
- [x] Observe a named assertion failing against a stub; implement dormant contexts and caller transfers, guarded stack allocation and same-thread checks.
- [x] Compile C/assembly, archive a static library and execute native tests on Linux; hosted macOS runs the same source. Only copy upstream make/jump files actually used, retaining their license and exact revision.
- [x] Commit owned files and obtain independent review. Native tests do not establish Pascal RTL safety.

## Task 2: Pascal lifecycle and RTL experiment

Files: `src/FiberRuntime.Context.pas`, `src/context/*`, `tests/ContextTests.dpr`.

Consumes Task1 ABI on Unix and native Windows fibers. Produces the exact API in
`docs/context-contract.md`. Public exception types are EFiberUsage and
EFiberCancelled; states are fsCreated/fsRunning/fsSuspended/fsCompleted/
fsCancelled/fsFaulted. `TFiberRuntime.BackendName: string` identifies the backend.

- [x] Write state/nested-stack tests before implementation. Example: a callback stores a local value, enters try/finally, yields, verifies that value after Resume and executes its finalizer exactly once.
- [x] Implement same-thread attachment, dormant creation, task identity guards and legal state transitions. Reject destructive Free attempts without freeing the live object.
- [x] Implement compiler-specific exception chain isolation after examining actual FPC3.2.2 sources. Check the head itself before throwing in a mutation test, so unsafe chain isolation fails by named assertion instead of crashing.
- [x] Alternate two tasks with different rounding modes, strings, reference-counted interfaces and local pointer values. Exercise new exceptions after suspension, ordinary shared threadvars, root-side exceptions between task resumes, fault containment and cancellation cleanup.
- [x] Add narrowly targeted CONTEXT_PROVE_IDENTITY / CONTEXT_PROVE_RTL variants. Normal tests assert the intended guard; negative test executions require exact assertion/exit1.
- [x] Run Win32/Win64/Linux locally as available; hosted macOS is required before publishing that target. Document unvalidated handler/unwind/signal behavior explicitly.
- [x] Commit owned files and obtain independent review.

## Task 3: Demonstration and automation

Files: `demo/ContextDemo.dpr`, `scripts/context_build.py`, `scripts/check.py`,
`scripts/package.py`, relevant Python tests and `.github/workflows/*`.

- [x] Build the Unix helper from selected pinned assembly files with gcc/clang and ar, producing build/native/libfr_context.a. Windows uses Pascal native fibers and needs no C helper.
- [x] Add context tests/negative builds to existing checks with isolated outputs, preserving the strict exit/signature gate. Record compiler, CPU, context backend and executed checks in summary JSON.
- [x] Add a one-carrier demo alternating persistent tasks; record task count, yield count, round-trip time and completion/cancellation, without printing in the measured region.
- [x] Package ContextDemo plus the existing PeriodicDemo; verify both binary hashes, both licenses and compile/run both from a clean extracted source path with spaces. Unix clean consumers build their helper first.
- [x] Run the hosted matrix on Windows/Linux/macOS. Keep periodic results descriptive and preserve v0.1.0 history.

## Task 4: Evidence and publication

Files: README, docs/context-contract.md, support matrix, verification, context evidence, changelog and release notes.

- [x] Record actual support per compiler/backend, test results, switching measurements, stack cost and restrictions. Do not label blocking native calls or ordinary threadvars fiber-aware.
- [x] Obtain full independent review; resolve important findings with focused regression checks.
- [ ] Publish reviewed branch via gh, verify CI, merge after passing checks and tag v0.2.0-prototype.1 only after main checks pass.
- [ ] Verify the release workflow and downloaded archive checksums/metadata/executables. Context experiment completion does not imply the later service/channel integration exists.
