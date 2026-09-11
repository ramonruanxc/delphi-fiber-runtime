Repository conventions update: consistent two-space Pascal formatting, an
expanded usage guide, a runnable service/event QuickStart and a Boss manifest.
Formatting preserves the original token stream. Boss installation and the
installed-source QuickStart are exercised on every CI host.

Integrated experimental runtime: cooperative tasks, fixed-rate periodic services,
compatible timer/channel waits, bounded mailbox and explicit lifecycle ownership.

Includes Windows, Linux and macOS ARM64/Intel packages with PeriodicDemo,
ContextDemo, RuntimeDemo and QuickStart,
tracked source and SHA-256
checksums. The release workflow compiles and executes functional tests, negative
builds, descriptive benchmarks and clean-consumer checks on the tagged revision.
Each native archive includes compiler/CPU/OS metadata and its raw timing evidence.

The context experiment uses Windows native fibers and a pinned Boost.Context
assembly/C boundary on Unix, with a narrowly version-gated FPC 3.2.2 RTL adapter.
It tests nested suspension, managed state, error containment and cooperative
cancellation before allowing stack destruction. The MIT and Boost notices are
included in native packages.

Adds reusable notifications, periodic rebase after detected resume, clock-fault
cleanup, independently stoppable services, owned event endpoints and channel
backpressure. Mixed-workload comparisons consume actual pinned pool/service-host
APIs; traces separate timer eligibility, enqueue, resume and callback execution.
Allocation entry calls and FPC heap observations complement sampled OS resources.

Timing is descriptive, with no universal 1 ms guarantee. Delphi context validation
remains pending; FPC results do not certify Delphi compatibility. Suspending during
exception handlers/unwinding and physical system sleep/resume remain unqualified.
Invalid clocks stop admission and permit cleanup. Valid resumes preserve active
workflows and start a new periodic segment without replaying elapsed sleep periods.
Blocking calls are not transparently asynchronous. See docs/acceptance.md for
implemented behavior and qualification boundaries.
