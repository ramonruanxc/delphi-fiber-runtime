# Integrated runtime contract

This implements the remaining approved design with one cooperative carrier per
scheduler. The existing standalone periodic API remains independent of contexts.
Compiler/backend support is explicit; FPC evidence never certifies Delphi.

## Scheduler and driver

`TSchedulerDriver` has virtual `NowUs: Int64`, `WaitUntil(DeadlineUs: Int64)` and
`Wake`. Only Wake may be called from another thread. The default driver owns a
native TPlatformTimer. An injected driver is borrowed and supports virtual-time
tests. `TPlatformTimer.WaitUntilOrWake` returns twDeadline, twNotified or
twCancelled; Notify is reusable and coalesced, Cancel stays sticky. Existing
WaitUntil ignores notifications and still waits for the deadline/cancellation.
Cancellation has priority, then an already elapsed deadline, then notification.
Expired-deadline calls preserve a pending notification.

`TSchedulerDriver.ClockGeneration: Int64` defaults to zero; custom drivers must
override it to report discontinuities. The native driver uses paired-clock
`TPlatformTimer.SuspendGeneration` and exposes availability separately through
`SuspendDetectionAvailable`. A 1,000 us sampling tolerance avoids mistaking
preemption for sleep; under the documented paired-clock model cumulative offset
growth above 3,000 us is distinguishable, smaller changes are not guaranteed.
Wide/invalid samples raise EClockDiscontinuity. Old Windows versions without
the required precise clocks remain explicitly unavailable for this detector.
Physical power-cycle acceptance is separate from simulated and native clock tests.
The scheduler's owner-only `ClockDiscontinuity: Boolean` becomes sticky when
time moves backward or the generation changes. It prevents new dispatch/admission,
requests cancellation and reports the fault; `Stop` still drives finally cleanup.
During fault cleanup a coarse GetTickCount64 budget bounds cooperative turns,
and task time reads use the last valid time when the native clock reports a fault.

`TFiberScheduler.Create(AMaxTasks: Integer = 1024; ADriver: TSchedulerDriver = nil)`
preallocates bounded task/ready/mailbox storage. It owns all spawned task handles
until destruction. Handles remain valid until then. Terminal tasks do not release
admission slots: capacity bounds total Spawn calls in this scheduler lifetime.
The owner-only `MaxTasks: Integer` exposes that bound to channel waiter storage.
`Spawn(AProc: TScheduledProc; AData: Pointer): TScheduledTask`, where
`TScheduledProc = procedure(ATask: TScheduledTask; AData: Pointer)`.
`RunUntil(ADeadlineUs: Int64): Boolean` dispatches FIFO turns, checks timers and
mailbox every bounded turn and returns true only if all tasks and posted work
settled; false means deadline elapsed with resources retained. Ready work never
uses Sleep or blocks on native waits. Only an idle carrier parks at the nearest
task/run deadline. Deadline eligibility is rechecked after wakeup.
`RunTaskUntil(ATask: TScheduledTask; ADeadlineUs: Int64): Boolean` instead returns
when that owned task is terminal, permitting independent service stop while other
services remain registered. All pumps reject reentrant calls.
An O(capacity) timer scan is acceptable initially and must be measured honestly.

`NowUs: Int64`, `CurrentTask: TScheduledTask`, `CheckOwner`,
`WakeTask(ATask: TScheduledTask)` support higher layers; all are owner-only.
`Post(AProc: TCarrierProc; AData: Pointer): Boolean`, where
`TCarrierProc = procedure(AData: Pointer)`, is a bounded thread-safe mailbox.
Successful Post transfers only responsibility to invoke; data remains borrowed.
Post returns false when full/stopping. Accepted callbacks are drained before
successful shutdown, cannot yield, and run on the owner. Exceptions are contained
and counted in `PostFaultCount: Int64`; callers own their payload lifetime.
Publish-before-notify plus the persistent native notification must prevent a
lost wakeup between draining work and parking. RequestStop is thread-safe and
idempotent. It rejects new admission and requests cancellation of all tasks.
Admission and notification are transactional under the mailbox lock: a failing
Wake rolls back the queue entry before the exception escapes. Therefore a raised
Post has not accepted the borrowed payload. Driver Wake must never reenter the
scheduler, suspend or call application code while that leaf lock is held.

`Stop(ATimeoutUs: Int64): Boolean` is owner-only, requests stop and drives cleanup
until settled or timeout. Destroy rejects live tasks and undrained posts before
freeing anything. A callback that blocks or never yields cannot be preempted;
timeouts are checked when the carrier regains control, never advertised as hard
interrupts. Cancelling a task makes a compatible wait ready, permits finally
cleanup, and never deletes a live stack.
`StopTask(ATask: TScheduledTask; ATimeoutUs: Int64): Boolean` performs target
cancellation and cleanup with the same fault-tolerant budget. On a healthy
scheduler it leaves other tasks and admission active; detected clock faults stop
all admission. Service.Stop delegates to this operation.

`TScheduledTask` exposes `Yield`, `Delay(ADurationUs: Int64)`,
`AwaitUntil(ADeadlineUs: Int64)`, `Park`, `Cancel`, `CheckCancelled`;
read-only `State: TFiberState`, `CancelRequested`, `ErrorClass`, `ErrorMessage`,
`Scheduler: TFiberScheduler`, and borrowed `LocalValue: Pointer`.
Only the current task may suspend. Yield enqueues one turn; Park waits for
WakeTask/cancellation; Delay/AwaitUntil wait without occupying the carrier.
Cancellation is checked before and after each compatible wait. No user code may
free scheduler-owned task handles. No switching during handlers/unwind or while
holding native locks, as specified by the context contract.

## Channels and service lifecycle

`TFiberChannel.Create(AScheduler: TFiberScheduler; ACapacity: Integer)` is a
bounded FIFO of borrowed Pointer values, owner-only and associated with one
scheduler. `TrySend(AValue: Pointer): Boolean` never suspends.
`Send(AValue: Pointer): Boolean` and `Receive(out AValue: Pointer): Boolean`
park the current task while full/empty. Wakeups recheck predicates. Waiter
registration is removed in finally even when cancellation is raised.
`Close` rejects sends, lets buffered values drain, and wakes both sides; false
means closed. `Discard` empties the buffer without freeing borrowed values.
Destroy refuses active waiters. No silent overwrite or unbounded waiter storage.
Carrier calls are allowed when Send/Receive can complete immediately; only a
blocking path requires a current task. Channel lifetime must end before its
scheduler is destroyed, and the same ordering applies to service objects.

`TFiberService.Create(AScheduler: TFiberScheduler; APeriodUs: Int64;
AProc: TServiceProc; AData: Pointer)`, where
`TServiceProc = procedure(ATask: TScheduledTask; const ATick: TPeriodicTick;
AData: Pointer)`, creates a dormant fixed-rate periodic service.
`Start` creates exactly one persistent task and fixes the epoch. It is called
once; `Cancel` prevents more activations and cancels compatible waits.
`Stop(ATimeoutUs: Int64): Boolean` drives the owner scheduler until this task
is terminal or timeout; successful Stop means no subsequent invocation.
`Task`, `StartedCount`, `SkippedCount` expose evidence. All service operations
are owner-only. Destruction refuses an active task. Each invocation may suspend,
but remains active throughout; completion uses the original fixed-rate schedule
to skip every elapsed cycle. Faults stop the service and remain on Task.
Owner-only `EpochUs` and `PeriodUs` expose the actual schedule definition.

Events use one explicit bounded channel per subscription; a receiver task owns
its subscription lifetime. Publishing uses TrySend with an explicit full result,
or Send for backpressure. Stop the receiver, close and discard its channel,
then release borrowed payloads. No hidden global bus or callbacks after stop.
Native producers use Post to request owner-side delivery, keeping its lifetime
contract. The integration demo must exercise this workflow with multiple services.

## Completion and evidence

Tests cover virtual time, no early activation, fairness, task identity, bounded
admission, duplicate wakes, full/empty/close, cleanup, stop timeout, foreign owners,
native notification races and accepted Post delivery. Negative builds require
named exit-1 failures for duplicate-ready protection and stopped-service admission.
Retain all earlier tests and package evidence. Compare fixed workloads against
explicit native-thread and worker-pool execution models; identify whether actual
reference libraries can compile and never relabel a model as the original library.
Report distributions, skips, resource observations, environment and limitations.
System sleep/resume or backward clocks must stop dispatch with an explicit fault
unless an independently tested rebase policy is implemented.
