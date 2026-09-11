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
The scheduler distinguishes a valid resume-generation increase from an invalid
or backward clock. `TResumePolicy=(rpRebasePeriodic,rpStop)` is an optional third
constructor argument, defaulting to rpRebasePeriodic. Valid resume records
ResumeGeneration/ResumeEpochUs and wakes timers so services can rebase between
invocations. Ordinary waits still recheck their requested deadlines. rpStop instead
treats resume as a clock fault. The owner-only `ClockDiscontinuity: Boolean` is
sticky on faults, blocks admission and requests cancellation; Stop permits cleanup.
During fault cleanup a coarse GetTickCount64 budget bounds cooperative turns,
and task time reads use the last valid time when the native clock reports a fault.

`TFiberScheduler.Create(AMaxTasks: Integer = 1024; ADriver: TSchedulerDriver = nil;
AResumePolicy: TResumePolicy = rpRebasePeriodic)`
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
all admission. Service.Stop uses the corresponding condition cleanup pump to
include its communication lifecycle in the same timeout budget.

`RunUntilCondition(Condition,Data,DeadlineUs)` drives a carrier-side predicate
using the fault-tolerant cleanup clock. Service communication uses it to wait
for attributed handlers without stopping unrelated services. Predicates must
not reenter, suspend or mutate the scheduler. `CleanupNowUs` provides the same
clock domain for computing the deadline.

`TScheduledTask` exposes `Yield`, `Delay(ADurationUs: Int64)`,
`AwaitUntil(ADeadlineUs: Int64)`, `Park`, `Cancel`, `CheckCancelled`;
read-only `State: TFiberState`, `CancelRequested`, `ErrorClass`, `ErrorMessage`,
`Scheduler: TFiberScheduler`, and borrowed `LocalValue: Pointer`.
Only the current task may suspend. Yield enqueues one turn; Park waits for
WakeTask/cancellation; Delay/AwaitUntil wait without occupying the carrier.
Cancellation is checked before and after each compatible wait. No user code may
free scheduler-owned task handles. No switching during handlers/unwind or while
holding native locks, as specified by the context contract.

`AwaitUntilOrResume(ADeadlineUs,AExpectedGeneration:Int64):Boolean` returns false
when the resume generation changes, letting a periodic service replace its old
epoch before admitting another invocation. Active callbacks are not preempted.
The task Trace record contains flags plus requested WaitDeadlineUs, first
TimerObservedUs, first ReadyEnqueuedUs, ResumedUs, ReadyReason and generation.
The selected latest-due activation can have a deadline later than enqueue; tracing
must preserve the requested wait deadline separately.

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
and attached communication settle or timeout; successful Stop means no
subsequent invocation or attributed event callback.
`Task`, `StartedCount`, `SkippedCount` expose evidence. All service operations
are owner-only. Destruction refuses an active task. Each invocation may suspend,
but remains active throughout; completion uses the original fixed-rate schedule
to skip every elapsed cycle. Faults stop the service and remain on Task.
Owner-only `EpochUs` and `PeriodUs` expose the actual schedule definition.

Raw channels retain their explicit borrowed-pointer contract. Owned service events
use TFiberEventHub, stable hub-owned endpoints and managed interface payloads.
Attaching a service binds lifecycle hooks: Stop blocks its publication, discards
pending source deliveries, cancels its recipient subscriptions and waits active
attributed handlers. A timeout retains ownership and prevents unsafe destruction.
Stable endpoint tokens outlive Service.Free so accepted native posts can be safely
suppressed without dereferencing a freed service. Hub destruction requires posted
envelopes and subscriptions settled.

`TFiberEventHub.Create(Scheduler, Capacity, MaxSubscriptions)` preallocates a
delivery pool and a separate native-post envelope pool, each of Capacity slots.
`Attach(Service): TServiceEndpoint` binds one lifecycle hook and returns a
hub-owned endpoint. `Subscribe(Recipient, Handler, Data): TServiceSubscription`
creates a persistent dispatcher task; account for these tasks in scheduler
capacity. Endpoint and subscription handles cannot be freed by callers. Stop
and free attached services before freeing the hub, then free the scheduler.

Endpoint `Publish(const Payload:IInterface):Boolean` is owner-only and admits
the entire fanout to current subscriptions or rejects it when capacity is full.
Each active handler is outside the pending delivery capacity. Handler signature
is `procedure(Task:TScheduledTask; Source:TServiceEndpoint;
const Payload:IInterface; Data:Pointer)`. Handlers may use compatible waits;
the shared managed payload must remain immutable or be explicitly synchronized.

Endpoint `Post(const Payload:IInterface):Boolean` may be used by native producers.
True accepts an envelope for deferred owner-side admission, not a guarantee that
its later fanout will fit. `PostAcceptedCount` and `PostRejectedCount` distinguish
envelope acceptance and deferred rejection. Retain the hub while producers can
call Post; payload reference counting must be thread-safe. No interface lifetime
hook may suspend, reenter the runtime or raise during reference management.

PublishedCount counts accepted logical publications; AdmittedCount counts their
fanout deliveries. At every settled observation:
`Admitted = Pending + Active + Delivered + Discarded + Aborted`. Delivered means
normal handler completion, Discarded means removed before entry, and Aborted means
an entered handler was cancelled or faulted. Inspect subscription Task faults;
successful lifecycle cleanup alone does not imply successful application work.

## Completion and evidence

Tests cover virtual time, no early activation, fairness, task identity, bounded
admission, duplicate wakes, full/empty/close, cleanup, stop timeout, foreign owners,
native notification races and accepted Post delivery. Negative builds require
named exit-1 failures for duplicate-ready protection and stopped-service admission.
Retain all earlier tests and package evidence. Compare fixed workloads against
explicit native-thread and worker-pool execution models; identify whether actual
reference libraries can compile and never relabel a model as the original library.
Report distributions, skips, resource observations, environment and limitations.
Valid resumes start new periodic segments after an active invocation finishes;
crossing invocations and discarded old segments are reported separately from
uninterrupted timing. Invalid/backward clocks stop dispatch with an explicit fault.
