# Support matrix

Support is specific to compiler, OS, CPU and backend. The current milestone is
experimental: functional evidence does not certify a 1 ms temporal tolerance.
The exact compiler and runner environment are recorded in each CI artifact's
`summary.json`; package CPU/OS are obtained from the compiler, not Python's host.

| Combination | Status / evidence |
|---|---|
| FPC 3.2.2, Windows x86 | Functional tests, benchmarks and clean-consumer package passed locally |
| FPC 3.2.2, Windows x64 | Full local checks and hosted Windows Server 2025 checks passed |
| FPC 3.2.2, Linux x64 (WSL2 Ubuntu 24.04) | Full local checks passed; WSL is identified separately from native Linux |
| FPC 3.2.2, Linux x64 hosted runner | Functional tests, benchmarks and clean-consumer package passed |
| FPC 3.2.2, macOS 26.6.2 ARM64 hosted runner | Functional tests, benchmarks and clean-consumer package passed |
| Delphi 12, Windows x86/x64 | Unvalidated: installed edition rejects command-line compilation |
| Older Delphi/FPC versions, other CPU combinations | Planned; not certified by the current builds |
| Mobile platforms | Outside this milestone |

Windows attempts a high-resolution waitable timer and identifies its standard
fallback in `BackendName`. Linux uses CLOCK_MONOTONIC; macOS uses matching Mach
clock/timer units and requests reduced coalescing with NOTE_CRITICAL. This can
increase wakeups and power usage. No native timer can guarantee scheduling latency
under all loads. See [recorded evidence](evidence/README.md) for the exact revisions.

Suspend/resume detection, rebasing and discontinuity records from the full design
are not yet implemented. These measurements cover uninterrupted execution only;
do not qualify a run spanning system sleep. The OS clock/timer suspend semantics
differ. This limitation must be resolved before support includes resume behavior.

The portable schedule uses a conservative Pascal API, but historical compilers
and backend ABI combinations still require builds.

## Context experiment (separate qualification)

| Compiler / target | Context backend | Evidence |
|---|---|---|
| FPC 3.2.2 Windows i386, default SEH | Windows fibers with floating-point switching | Local functional tests and demo passed |
| FPC 3.2.2 Windows x64, default SEH | Windows fibers with floating-point switching | Local functional tests and demo passed |
| FPC 3.2.2 Linux x64 | Boost.Context 1.85.0 C ABI, FPC SJLJ adapter | Local WSL functional tests and demo passed; hosted verification follows |
| FPC 3.2.2 macOS ARM64 | Boost.Context 1.85.0 C ABI, FPC SJLJ adapter | Hosted verification pending |
| macOS x64 | Matching upstream assembly included | Execution not yet qualified |
| Other FPC versions; Delphi | Additional RTL adapter required | Experimental context unit refuses compilation |

Context guards check FPC version and the expected Windows SEH configuration.
Unix requires cthreads first; custom thread managers are unqualified. Windows
requires ConvertThreadToFiberEx/CreateFiberEx and refuses attachment to an already
fiber-converted host thread. Tests qualify the shipped default build configuration,
not nondefault shadow-stack, sanitizer or signal/async-exception behavior.

The Windows stack metadata uses the native stack top and rounded reservation
estimate. Unix exposes the actual usable mmap interval excluding guard pages.
Neither is a measurement of committed memory or a claim of stack-overflow recovery.

Managed locals and explicit LocalValue are exercised by context tests; ordinary
threadvars remain shared. Exception-handler/unwind suspension, task migration,
transparent blocking calls and full timer/channel/service integration remain
outside this milestone. See [context contract](context-contract.md).
