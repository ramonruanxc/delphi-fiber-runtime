# Runtime Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute all tasks autonomously.

**Goal:** Complete integrated cooperative services, bounded communication, portable support tiers, comparative demonstrations and reviewed distribution.

**Architecture:** A bounded owner-thread scheduler wraps qualified contexts. Native notifications and timers wake idle carriers; task waits park logical tasks. Channels and periodic services compose that scheduler.

**Tech Stack:** Conservative Object Pascal, FPC 3.2.2 qualified contexts, native Windows/Linux/macOS adapters, Python, GitHub Actions.

**Spec:** `../specs/2026-09-10-delphi-fiber-runtime-design.md`; exact API in `../../runtime-contract.md`.

## Global constraints

- Maximum practical Delphi and Free Pascal portability with explicit backend support tiers.
- Platform independence through replaceable backends and truthful execution evidence.
- One carrier per task lifetime; no force termination or deletion of live stacks.
- Primary cadence is a periodic service every 1,000 us; timing remains descriptive without a qualification profile.
- Keep files below 500 lines; no credentials or conversation exports; preserve sibling libraries.
- Existing user approval includes autonomous implementation, reviews, CI, merging and publication through gh.

## Task 1: Reusable native notification

Files: `src/FiberRuntime.Platform.pas`, `src/platform/*`, `tests/NotificationTests.dpr`.
Produces enum TTimerWaitResult=(twDeadline,twNotified,twCancelled), Notify and WaitUntilOrWake(Int64):TTimerWaitResult. Existing WaitUntil contract preserved.

- [x] RED test: Notify before wait returns twNotified; second wait reaches its deadline; Cancel always wins.
- [x] Implement separate reusable OS notification without polling/Sleep; Linux drain eventfd, Windows auto-reset event, Darwin persistent user-event predicate.
- [x] Test repeated notify, notify during wait and drain/park races with producer handshakes, deadline/cancellation priority and resource churn on local Windows/Linux.
- [x] Commit owned files and obtain independent review.

## Task 2: Bounded scheduler and compatible waits

Files: `src/FiberRuntime.Scheduler.pas`, `src/scheduler/*`, `tests/SchedulerTests.dpr`.
Consumes context unit and Task1 API. Produces exact scheduler/task/driver signatures in runtime-contract.

- [x] RED virtual driver test: task A awaits 1,000 us while task B executes before the clock advances; validate completion and cleanup.
- [x] Implement bounded FIFO ready queue, owner checks, registration, timer scan, exception containment and cancellation; duplicate WakeTask must never enqueue twice.
- [x] Implement bounded Post and RequestStop with synchronized publication before Notify; accepted work drains before successful Stop, posts after stop rejected.
- [x] Test fairness, no early execution, all state/ownership guards, capacity, foreign posts, stop timeout and retained live stacks; CONTEXT_PROVE_READY must fail named SCHEDULER_READY_ONCE before unsafe transfer.
- [x] Run local Win32/64/Linux and commit owned files for independent review.

## Task 3: Channels and persistent services

Files: `src/FiberRuntime.Channel.pas`, `src/FiberRuntime.Service.pas`, `tests/ChannelTests.dpr`, `tests/ServiceTests.dpr`.
Consumes Task2 exact signatures and existing Schedule unit. Produces channel/service APIs in runtime-contract.

- [x] RED channel predicate test: full sender parks, another task drains FIFO, close wakes both sides, cancellation removes waiters.
- [x] Implement bounded borrowed-value channel and waiter lifecycle with no suspension while holding native locks.
- [x] RED service test with fake time: callback suspends beyond two periods, never overlaps, resumes on the next original-epoch deadline; Stop removes future activity.
- [x] Implement one persistent task per service, cancellation and truthful Stop timeout; CONTEXT_PROVE_SERVICE_STOP produces SERVICE_STOP_NO_CALLBACK exit1.
- [x] Run local tests, commit and obtain independent review.

## Task 4: Compatibility, demos and comparative automation

Files: `demo/RuntimeDemo.dpr`, `demo/ComparisonDemo.dpr`, `scripts/check.py`, `scripts/package.py`, new reporting/tests as needed, workflows and compatibility docs.

- [ ] Resolve practical portability tiers and reference-library build availability from actual source/toolchains; implement useful supported fallbacks where needed without pretending fiber scalability.
- [ ] Build mixed periodic/channel demo with 1,000 us services, measured planned/start/finish/counts, cancellation and quiescent shutdown. Preallocate timing buffers.
- [ ] Compare equivalent native-thread, bounded-worker and cooperative workloads with declared model/reference distinction, resource sampling and no OS/performance guarantees.
- [ ] Add all positive/named negative checks and semantic report validation; clean consumer builds and executes every packaged demo; hashes bind binaries to exact clean revision.
- [ ] Run 3OS CI, preserve earlier evidence, resolve independent integration review findings.

## Task 5: Full acceptance and publication (after Tasks 6â€“8)

Files: README, contracts, support/verification/evidence, changelog/release notes, final acceptance matrix.

- [ ] Reconcile every approved requirement with delivered functionality, execution evidence or explicit unavailable target; do not call unimplemented core behavior complete.
- [ ] Publish actual measurements and restrictions, complete full independent review, merge only passing final revision.
- [ ] Validate main, publish versioned prerelease, verify downloaded assets/checksums/metadata and executable consumers. Record final status and material limitations.

## Task 6: Resume segments and dispatch tracing

Files: Scheduler/its includes/tests, Schedule and ScheduleTests. Owned by scheduler implementer.

- [ ] Separate valid forward resume-generation changes from invalid/backward clock faults. Default rpRebasePeriodic preserves tasks; rpStop remains configurable.
- [ ] Add task AwaitUntilOrResume(deadline,generation), scheduler ResumeGeneration/ResumeEpochUs and target/predicate cleanup pumping.
- [ ] Add inactive Rebase and complete-and-rebase semantics that close an active segment without counting sleep-time periods as ordinary missed cycles. Test crossing invocations and no replay.
- [ ] Add per-task trace of requested deadline, first timer eligibility, first ready enqueue, resume, reason and generation. Duplicate wakes preserve first admission; test actual ordering without inventing selected-deadline ordering.
- [ ] Run all prior and new tests, commit and independently review.

## Task 7: Owned service communication and resume handling

Files: Service/Channel/tests, new ServiceHooks/EventHub units/includes/tests. Owned by service implementer.

- [ ] Service uses resume-aware wait and rebase between callbacks; active callbacks preserve ownership and close their old timing segment separately.
- [ ] Add bounded managed payload hub, stable service endpoints, recipient-owned subscriptions and preallocated deliveries/post envelopes. All-or-none fanout, explicit rejection.
- [ ] Service.Stop automatically stops endpoint admission, discards source deliveries, cancels its subscriptions and waits active attributed handlers; timeout retains ownership.
- [ ] Test queued publish then source stop, active receiver timeout, recipient stop, late native posts after source destruction, payload finalizers and capacity faults. No use-after-free or callbacks after successful stop.
- [ ] Run local targets, commit and independently review.

## Task 8: Equivalent mixed traffic and segmented metrics

Files: RuntimeDemo, ReferenceDemo, allocation probe, runtime_report/references and their tests. Owned by comparison implementer.

- [ ] Record actual scheduler trace alongside callback boundaries with preallocated storage and segment/generation metadata. Separate crossing-discontinuity invocations from normal percentiles.
- [ ] Add equivalent mixed-event workload for actual worker/pool/host APIs and cooperative runtime, declaring payload/capacity/fanout/work/cycle configuration and acceptance/delivery/rejection/discard accounting.
- [ ] Preserve original-host cadence distinction and all strict fault/empty/provenance gates; validate malformed and loss/duplication traces before calculating statistics.
- [ ] Test independently, commit, review and extend main check/package hooks through controller before Task5 publication.
