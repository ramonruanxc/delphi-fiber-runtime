# Portable Delphi service runtime: design specification

Date: 2026-09-10

Status: approved design baseline. Implementation progress and evidence are tracked separately in the milestone plan and verification documents.

Repository: [delphi-fiber-runtime](https://github.com/ramonruanxc/delphi-fiber-runtime). Implementation status is recorded separately from this approved design.

## 1. Objective

Build a new runtime inspired by Java virtual threads and by the user's `delphi-concurrent-pool` and `delphi-service-host`. Preserve independently executing services communicating through events, while allowing logical tasks to share native executor threads.

The primary timing requirement is **periodic service activation every 1 ms (1 kHz)**. It is not merely dispatch latency below 1 ms, and it is not a promise that arbitrary application work completes within 1 ms.

The other approved requirements are:

- Maximum practical Delphi and Free Pascal portability, without requiring features exclusive to a recent Delphi release.
- Platform independence through replaceable backends and explicit support levels.
- Performance and resource efficiency measured against the existing execution models.
- CI/CD, executable demos, negative builds and reproducible evidence.
- Low-level C/C++ or assembly may be used where justified by compatibility or measurements.

This is a soft real-time design on general-purpose operating systems. A universal hard deadline guarantee is outside the supported claim.

## 2. First milestone and scope boundary

The first milestone is a portable **1 kHz scheduling experiment**, before a complete fiber runtime.

It must exercise the same periodic contract on Windows, Linux and macOS using native timer adapters. A minimal workload runs on a persistent executor, with preallocated measurement storage. The experiment reports timing quality and cost; it does not pretend that fibers are necessary to implement a periodic callback.

After the experiment, context switching and fiber-aware waits are evaluated separately. The periodic scheduler must remain usable independently of fibers.

The initial scope excludes transparent interception of arbitrary blocking APIs, forced preemption of arbitrary Pascal code, universal compatibility with third-party libraries, mobile targets, production hard-real-time claims, and a custom assembly context implementation without a demonstrated need.

## 3. Architecture

### Public API and shared core

Portable Pascal units own service registration, lifecycle, event contracts, periodic schedule calculations, cancellation, ready-task management, bounded channels and diagnostics.

Application code must not need operating-system conditionals to implement a service. Public operations describe intent: run, await, publish, receive, cancel and stop.

Short callbacks may execute directly. Workflows requiring suspension inside nested calls may use stackful tasks. Periodic activations reuse their registration and execution resources instead of creating a native thread or fiber per tick.

### Backend boundaries

| Boundary | Responsibility |
|---|---|
| Clock | Monotonic timestamps, frequency/conversion and suspend behavior |
| Timer | Arm the nearest deadline, disarm and notify without periodic polling |
| Wakeup | Wake idle executors with a protocol that cannot lose notifications |
| Native execution | Create and join persistent threads with correct host RTL initialization |
| I/O | Begin operations, deliver results and implement supported cancellation |
| Context | Create, switch, resume and retire execution stacks |
| UI dispatch | Optional integration with the actual main thread of VCL, FMX or Lazarus |

Scheduler policy must not depend on a specific native timer or fiber API. Backends advertise capabilities and limitations. A fallback cannot silently claim the scale or performance of another backend.

### Backend candidates

- Windows: high-resolution waitable timers where available, IOCP for supported asynchronous I/O, and a native fiber context candidate.
- Linux: monotonic timerfd deadlines integrated with an event mechanism such as epoll; a separately validated context backend.
- macOS: monotonic native deadlines and an event/timer backend selected by measurement; a separately validated context backend.
- libuv is an I/O portability candidate, not the scheduler contract and not a complete virtual-thread implementation. Its timers must be evaluated against the periodic requirement; native timing adapters remain possible.
- Boost.Context is a context portability candidate. Its architecture support does not certify Delphi/FPC exception and RTL compatibility.

If a native helper is used, expose a small versioned C ABI using opaque handles, explicit buffer lengths, calling conventions and ownership. Managed Pascal values, C++ objects and exceptions must not cross that boundary. Runtime exceptions are captured on the originating side and reported as explicit outcomes.

## 4. Periodic scheduling contract

### Fixed-rate activation

For period P = 1,000 microseconds and monotonic epoch T0:

`deadline(n) = T0 + n * P`, with the first activation at n = 1.

The next planned activation is derived from the original epoch, never from the previous completion time. This prevents application execution time from accumulating as schedule drift.

Use integer/rational conversions appropriate to the clock frequency. Repeated rounding of one period must not accumulate avoidable drift. Detect overflow and invalid periods.

The epoch is a monotonic schedule reference, not a civil UTC timestamp. In particular, Windows waitable timers' UTC-based absolute mode is not interchangeable with a monotonic timestamp: the adapter must translate the remaining duration or otherwise implement the monotonic contract.

### Dispatch and non-overlap

- A timer notification makes due work eligible for execution; it does not certify that the callback began on time.
- Do not intentionally invoke a cycle before its deadline. Recheck the monotonic clock when necessary.
- A service has at most one active invocation. A suspended invocation still counts as active.
- A late but eligible invocation records its actual start and associated planned deadline.
- Native timer callbacks perform bounded scheduler work; they do not run arbitrary service code inline on an infrastructure callback thread.

### Default overload policy: skip missed periods

If the executor becomes available after several deadlines while the service is idle, discard the older eligible cycles and permit at most the latest due cycle to run. Record how many were skipped. Never replay an unbounded backlog.

If deadlines pass while the service is already active, those activations are skipped. After completion, schedule the first deadline strictly in the future, retaining the original epoch.

Example: the cycle due at 1 ms begins at 1.04 ms and finishes at 3.20 ms. The 2 ms and 3 ms activations are skipped; the next planned activation is 4 ms. The service is never invoked concurrently with itself.

Count each planned activation once: started, skipped, or still pending. Runtime termination additionally accounts for pending activations according to the shutdown boundary. Optional future catch-up policies require their own bounded contracts.

### Timing quality

There is no agreed numeric jitter tolerance yet. This is not permission to treat 1 ms of additional delay as acceptable.

Functional support and temporal qualification are separate. Benchmarks always report measured distributions. A temporal pass/fail profile must explicitly specify maximum allowed start lateness, allowed violation rate, test duration, workload and hardware configuration. Without that profile, results are descriptive and cannot certify timing compliance.

### Suspend, resume and clock changes

Wall-clock corrections must not move deadlines. After detected system resume, rebase the periodic schedule, record a discontinuity and do not replay sleep-time activations. Exclude that discontinuity from uninterrupted-run timing distributions and report it separately. Backends must document how resume is detected and which clock behavior they use; unvalidated handling is a support limitation.

## 5. Execution and performance policy

Ready work runs without an artificial sleep between tasks. Idle infrastructure threads may block awaiting a timer, I/O completion or explicit notification. A logical task waiting for work must not block a carrier needed by other ready tasks.

Separate latency-sensitive periodic execution from blocking legacy operations and long CPU tasks. Executor capacity is configured and measured; creating more threads is not an automatic latency remedy.

Use bounded queues, bounded dispatch batches and explicit admission policies. Limit allocations in hot paths and keep synchronous logging out of timing measurements. Measure before adding lock-free structures, affinity policies or custom assembly.

An optional short bounded spin before parking may be benchmarked as a latency/CPU tradeoff. It is disabled in the portable baseline until evidence justifies a profile. Continuous busy waiting and real-time priority are not default settings.

A serial 1 kHz service needs enough budget for both its work and scheduling delays. Multiple services must fit the executor capacity. A callback that takes longer than its period causes recorded overruns; fibers cannot make that callback finish sooner.

## 6. Fibers, ownership and cancellation

Suspension requires fiber-aware timers, channels, waits and synchronization. Reusing the existing blocking queues inside fibers does not fulfill that contract.

Initially, a stackful task remains assigned to one carrier for its lifetime. This reduces migration concerns but does not isolate thread-local state between fibers on that carrier.

Before a context backend can be validated, test nested calls, exception handling, try/finally cleanup, managed strings/interfaces, floating-point state and interleaved task execution. Document threadvar/TLS behavior and provide explicit task-local storage. Suspension during exception handling or unwinding is unsupported until specifically validated.

Native locks that identify their owner by OS thread cannot be treated as task-owned locks. Do not suspend while holding a native lock. Fiber-aware synchronization uses logical task identity and resumes waiting tasks through the scheduler.

Cancellation is cooperative. Wake compatible waits and allow cleanup to complete. Never delete a live stack or force termination to claim successful shutdown. An uncancellable external operation can cause a reported stop timeout; its resources remain owned until it actually terminates.

Service stop prevents new activations, cancels outstanding work and subscriptions as specified, waits for active work to settle and disposes of pending deliveries. A successful stop means the stopped service cannot subsequently produce observable callbacks through the runtime. A timeout is a distinct result, not success.

## 7. Portability and support matrix

The matrix key is compiler version, operating system version, CPU architecture and backend revision.

Initial target families are Windows x86/x64, Linux x64 and macOS x64/ARM64, with actual compiler availability checked per combination. Additional architectures are extension points, not implied support.

| Status | Evidence required |
|---|---|
| Planned | Design target only; no implementation claim |
| Experimental | Backend exists, with recorded validation gaps or restrictions |
| Validated | Required build, functional tests and demos executed for that exact combination |
| Unsupported | Explicitly unavailable or outside the current matrix |

All combinations start as planned. No Delphi version is certified by an FPC run. Older compiler support is pursued through a conservative base API and isolated compatibility units; optional modern wrappers cannot become a core requirement.

Temporal qualification is attached separately to hardware/workload profiles. A functionally validated backend may have insufficient precision for a user's 1 kHz tolerance.

## 8. Validation and benchmarks

### Deterministic tests

Inject a virtual clock and fake timer notifications to verify fixed-rate calculations, no early execution, integer conversion, skipped cycles, no overlap, cancellation, shutdown and clock discontinuities without relying on wall-clock timing.

Concurrency tests exercise lost wakeups, duplicate resume, ownership races, starvation, bounded capacity and interaction between stopping and publishing. Hangs must produce named failures and nonzero results.

### Native measurements

Measure each stage separately: planned deadline, timer observation, enqueue, execution start and completion. Report:

- Start lateness and actual inter-start interval distributions.
- Callback duration, dispatch delay and phase error relative to the original epoch.
- Started and skipped activation counts, violations of the configured timing profile and unexpected failures.
- CPU usage, native thread count, committed/reserved memory and relevant allocations.

Use preallocated recording storage and export results after the measurement window. Account for skipped cycles in the denominator; do not report only the successfully executed callbacks. Record warmup separately and include both idle and loaded conditions.

Compare a minimal callback, a controlled short CPU workload and mixed periodic/event traffic. Compare the current native-thread/service and pool models with the prototype under equivalent workloads. Test one service before increasing counts. Record build flags, compiler, OS, backend, hardware, power mode and commit identifiers.

### Negative builds

Remove one protection at a time and require the intended failure signature. Candidate mutations include fixed-delay rescheduling, disabled wakeup, missing overlap guard, disabled cancellation wakeup, duplicate enqueue and omitted ownership cleanup.

Timeout, crash and absent diagnostic output are failures unless that exact outcome is the test's declared target. A negative leak check must independently verify the expected exit code and a positive leak report. Each mutation gets isolated build outputs to prevent stale compilation artifacts.

## 9. CI/CD

CI builds available target combinations, runs contract tests, builds and executes demos, checks packaged contents and verifies installation through a clean consumer project. Delphi-specific jobs need appropriate compiler installations and runners; unavailable jobs remain visible as validation gaps.

Shared runners collect performance reports but do not establish strict timing guarantees. Controlled runners evaluate explicit temporal profiles. Store raw benchmark data and machine-readable summaries as artifacts with their environment metadata.

CD publishes versioned source, documentation, checksums and any native binaries through a tag-driven release workflow after required checks. Releases identify their validated support matrix and timing evidence. Experimental binaries are clearly labeled. Native packages must match the declared platform and architecture.

External repository creation, credentials and the first public release are separate execution steps, not actions performed by this specification.

## 10. Delivery sequence and acceptance

1. **Periodic core:** deterministic fixed-rate scheduling and overload policy pass with a virtual clock.
2. **Native timing experiment:** run the same 1 kHz workload on the three platform families and publish measurements and limitations.
3. **Context experiment:** validate suspension and RTL behavior per backend before labeling fibers supported.
4. **Runtime integration:** implement compatible waits, channels, cancellation and service lifecycle using the validated contracts.
5. **Comparative demo and release pipeline:** clean-install consumers, controlled benchmarks, negative builds and distributable artifacts.

Advance based on evidence. If timing is inadequate, identify whether the delay is in timer delivery, dispatch, workload or system scheduling before optimizing. If a context backend cannot safely host a compiler's runtime, report that combination as unsupported or experimental; do not silently substitute native threads while claiming fiber scalability.

## 11. References

- [OpenJDK JEP 444: Virtual Threads](https://openjdk.org/jeps/444)
- [Windows fibers](https://learn.microsoft.com/en-us/windows/win32/procthread/fibers)
- [Windows high-resolution waitable timer creation](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)
- [Windows timer deadlines and clock semantics](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimerex)
- [Linux timerfd and monotonic deadlines](https://man7.org/linux/man-pages/man2/timerfd_create.2.html)
- [Linux absolute waits and scheduling delay](https://man7.org/linux/man-pages/man2/clock_nanosleep.2.html)
- [libuv design and platform backends](https://docs.libuv.org/en/v1.x/design.html)
- [Boost.Context architecture matrix](https://www.boost.org/doc/libs/latest/libs/context/doc/html/context/architectures.html)

Public design references: [delphi-concurrent-pool](https://github.com/ramonruanxc/delphi-concurrent-pool) at `efef9d6` and [delphi-service-host](https://github.com/ramonruanxc/delphi-service-host) at `ed3be34`. These are design references, not dependencies introduced by this document.
