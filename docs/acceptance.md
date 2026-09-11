# Integrated delivery acceptance

This records the portable cooperative runtime baseline, not universal Delphi
compatibility or hard real-time certification.

| Approved requirement | Delivered evidence / boundary |
|---|---|
| 1,000 us fixed-rate service | Original epoch+n*period, persistent task, virtual-time tests and per-service traces |
| No overlap while suspended | Invocation stays acquired through callback return; elapsed periods counted as skips |
| No Sleep polling of ready work | FIFO turns, compatible timer/channel waits; only idle carrier parks natively |
| Bounded capacity / backpressure | Lifetime task capacity, ready queue, mailbox and channels; explicit rejection |
| Same-carrier contexts | Native Windows / pinned Boost.Context C ABI, per-target FPC3.2.2 RTL evidence |
| Ownership, errors, cancellation | Owner guards, fault containment, finally cleanup, rejected live destruction |
| Service stop and events | Owned hub endpoints, managed payloads, pending delivery disposal and active-handler quiescence |
| Cross-thread wakeup | Persistent notifications and transactional Post; producer/park handshakes |
| Clock discontinuity | Paired clocks, resume generation, periodic segment rebase and invalid-clock cleanup |
| Platforms and versions | Native OS backends, compiler-independent schedule consumer, distinct context tiers |
| Existing-project comparison | Actual pinned APIs with matched event payload/capacity/fanout/work; original host cadence labeled |
| Performance evidence | Deadline/timer eligibility/enqueue/resume/callback stages, intervals/skips, event accounting, allocation calls and sampled resources |
| CI/CD | Named positive/negative checks, clean consumers, hashes/licenses and tag-gated publication |

Material boundaries:

- Integrated contexts remain FPC3.2.2-only. Both installed Delphi compilers refuse
  CLI compilation due their edition. A core probe is provided for a usable
  compiler; a guessed RTL adapter would not establish portability.
- Valid resume generations preserve active workflows and rebase periodic services
  between invocations. Crossing invocations are recorded separately. Invalid or
  backward clocks stop dispatch; rpStop also treats resume as a fault. Injected
  clock tests do not qualify physical suspend/resume on every supported machine.
- No jitter/hardware profile was supplied. Shared runners produce descriptive
  evidence. Timer observation is scheduler-observed eligibility, not a kernel
  interrupt timestamp. OS committed/reserved accounting is not inferred from
  heap or RSS/VMS observations.

Optional native asynchronous I/O and GUI adapters, task migration, preemption and
transparent interception of blocking calls are not implemented. Existing native
workers can compose through Post; applications must respect capacity and borrowed
payload lifetime. These extension points are not represented as completed features.

The runtime remains experimental. Implemented lifecycle and communication contracts
are executable; unavailable compiler/hardware qualification stays visible rather
than being marked as passed.
