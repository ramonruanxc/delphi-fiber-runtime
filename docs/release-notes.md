Second experimental milestone of Delphi Fiber Runtime: cooperative stackful tasks
alongside the independent fixed-rate periodic scheduler and cancellable timers.

Includes Windows, Linux and macOS packages with PeriodicDemo and ContextDemo,
tracked source and SHA-256
checksums. The release workflow compiles and executes functional tests, negative
builds, descriptive benchmarks and clean-consumer checks on the tagged revision.
Each native archive includes compiler/CPU/OS metadata and its raw timing evidence.

The context experiment uses Windows native fibers and a pinned Boost.Context
assembly/C boundary on Unix, with a narrowly version-gated FPC 3.2.2 RTL adapter.
It tests nested suspension, managed state, error containment and cooperative
cancellation before allowing stack destruction. The MIT and Boost notices are
included in native packages.

Timing is descriptive, with no universal 1 ms guarantee. Delphi context validation
remains pending; FPC results do not certify Delphi compatibility. Suspending during
exception handlers/unwinding and system sleep/resume handling remain unqualified.
Blocking calls are not transparently asynchronous. Timer/channel/service integration
is the next milestone; this is not a complete Java-style virtual-thread runtime.
