# Context experiment contract

This is the second approved milestone (design sections 6 and 10), independent of
the periodic scheduler. It tests stackful suspension before service integration.

## Scope and compatibility

Initial compiler qualification is explicitly FPC 3.2.2. Other FPC versions and
Delphi must fail clearly when compiling the experimental context unit, while
the existing independent periodic units remain available. Compiler-specific RTL
state handling belongs in one compatibility include, never application code.
Unix programs must list cthreads first in their uses clause. The runtime rejects
FPC's stock no-thread manager; custom thread managers are not qualified.

Windows uses native fibers with floating-point state switching. Unix uses a
small C ABI over pinned Boost.Context assembly and guarded mmap stacks. The C
helper never receives managed Pascal values or an escaping Pascal exception.
Each task stays on its creating native thread. No native thread per task, task
migration, transparent blocking-call interception or implicit preemption.

## Public API

`TFiberRuntime.Create` attaches the current native thread. Only one runtime may
be attached per thread. `CreateTask(AProc: TFiberProc; AData: Pointer;
AStackBytes: NativeUInt = 262144): TFiberTask` creates a dormant task, with a
requested stack size between 65536 and 67108864 bytes inclusive.
`TFiberProc = procedure(ATask: TFiberTask; AData: Pointer)`.

A task exposes `Resume`, `Yield`, `Cancel`, `CheckCancelled`; read-only `State`,
`CancelRequested`, `ErrorClass`, `ErrorMessage`; and a borrowed `LocalValue:
Pointer` slot owned by application code. State is one of `fsCreated`,
`fsRunning`, `fsSuspended`, `fsCompleted`, `fsCancelled`, `fsFaulted`.

All operations, including cancellation and destruction, belong to the creating
thread. Cross-thread attempts raise `EFiberUsage` without changing state. Resume
is only legal from the carrier, never while another task is executing. A completed,
cancelled or faulted task cannot resume. Yield is legal only on the current task.
Invalid calls fail before a context switch. Backend name is observable.

Cancel on a created task marks it cancelled without invoking its callback.
Cancel on a suspended task sets a sticky request; a later Resume continues at
the yield checkpoint, raises `EFiberCancelled` inside that task and runs its
cleanup. Cancellation is cooperative: user code may catch it, and completion is
not reported until control actually returns. CheckCancelled tests the same flag.
If user code catches cancellation and then returns normally, the final state is
fsCompleted and CancelRequested stays true. fsCancelled means the cancellation
exception reached the task boundary and its cleanup completed.

Exceptions escaping the callback are caught on that task's own stack. Store
class/message as copied strings and mark fsFaulted, without transferring the
exception object or unwinding into a native caller. Cancellation uses fsCancelled.
Completion returns control to the carrier. Task-local data is not native TLS:
ordinary Pascal threadvars remain shared by tasks on one carrier.

Destruction is permitted only for never-started or terminal tasks. A
BeforeDestruction guard rejects invalid calls before cleanup begins. Destroying a
running/suspended task raises EFiberUsage and preserves it, so live stacks are
never silently discarded. Runtime destruction requires all tasks already freed.
Do not use FreeAndNil for an operation expected to be refused: that helper clears
the reference before Free.

## RTL and floating-point restrictions

SJLJ exception-address chains require separate storage per context. A pinned
FPC compatibility adapter may use its compiler helpers and public record layout
to save/install that chain. It must perform no allocations, managed operations
or exception-producing work between installing a chain and switching stacks.
SEH context switching remains delegated to native Windows fibers.

Resume/Yield during active exception handling is rejected when detected.
Suspending from exception handlers or during unwinding remains prohibited even
when an RTL cannot detect it. Yield from allocator, backtrace or error hooks is
also unsupported. Signal/async-exception delivery during the tiny
chain-switch interval is not supported. Never yield while holding a native lock.
The experiment does not claim transparent preservation of every RTL threadvar.

Tests must interleave live try/finally frames, managed strings/interfaces,
task-local values, shared threadvars and differing floating-point rounding modes;
then raise and catch new exceptions after switching. This goes beyond a simple
ping-pong demonstration. An unsafe compiler/backend combination fails its gate.

## Evidence

Named negative builds remove the task identity guard and the RTL-head isolation
guard; require their exact assertions with exit 1, never timeout/crash/no output.
Benchmark switching on one native thread, with a preallocated task set, and
report elapsed time/switch counts without converting them into a 1 ms guarantee.
Keep all first-milestone tests in CI, validate a clean consumer and bind packaged
context executables/native dependencies to the release revision.
