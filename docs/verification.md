# Verification

Run `python scripts/check.py`, then `python scripts/package.py` from a clean clone.
The runner builds each variant into its own directory with FPC range/overflow
checks (`-B -Mdelphi -Sa -Cr -Co`). Missing positive markers, compilation failures,
unexpected exceptions, crashes and timeouts fail the run.

The schedule suite covers no drift, late admission, no overlap, exact boundaries,
cancellation, invalid construction, backward time and atomic overflow recovery.
`PROVE_DRIFT` and `PROVE_OVERLAP` must terminate with exit 1 and exactly their named
assertion; an absent diagnostic cannot turn a negative test green. Python tests
also challenge this classifier directly.

Native tests cover monotonic readings, past/future deadlines, no early return,
sticky cancellation, cross-thread cancellation and repeated resource lifetimes.
Their timing bounds detect hangs; they are not a jitter qualification profile.

The benchmark records the first deadline at epoch + 1000 us. It stops admitting
cycles at the end of its planned horizon, finishes any already active callback,
and counts every unstarted planned cycle as skipped, including trailing cycles
missed by a late wakeup. It never prints or grows the sample array inside the
measurement window. `--work-us` is a deliberate CPU workload for overload tests.

The report checks metadata, exact deadline phase, ordering, non-overlap and sample
counts before calculating nearest-rank percentiles. It rejects replayed cycles
and deadlines crossed during a preceding invocation. It includes skipped cycles
in threshold assessments; these do not certify hardware/workload qualification.
The idle, short CPU work and overloaded
scenarios in shared CI are descriptive, without an agreed jitter threshold.

Artifacts contain raw CSV, report JSON, compilation logs and environment/commit
metadata. Optional psutil sampling reports observed RSS/VMS, thread count and CPU
time; it can miss peaks, undercount final CPU and influence execution. VMS is not
portable committed-memory accounting. Windows reports an additional sampled
private committed-byte peak from psutil's `private` field (Windows PrivateUsage),
excluding shared mappings. Other targets explicitly report that field unavailable;
reserved bytes remain unavailable on all targets, never substituted with RSS/VMS
or requested stack size. See [Windows counter semantics](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex).
The integrated demos also report FPC allocation entry calls as described below.

The release workflow runs the same matrix on the tag revision before publishing
source and native demo archives with SHA-256 checksums. A source archive is also
extracted into a clean temporary directory with spaces, compiled and executed.

## Evidence and limits

[Local and hosted results](evidence/README.md) include Windows x86/x64, Linux WSL2,
native hosted Linux and hosted macOS ARM64/Intel. GitHub Actions provides the full
per-revision build artifacts. The suite has 70 deterministic schedule checks,
nine Pascal suites, 44 Python test methods and five negative
executables on Windows (six on Unix). The optional reference comparison adds a
named host-fault negative. Unix also runs the native context suite
and a positive test of explicit missing-thread-manager rejection.
The installed Delphi edition prints `This version of the product does not
support command line compiling.` while returning exit code 0; that is recorded
as unavailable, not a successful Delphi build.

The integrated milestone measures one persistent carrier, 1/8/32 periodic services,
short CPU work and suspended work with channel delivery. It compares actual pinned
worker/pool/service-host APIs in separate processes. No leak-freedom claim is
inferred from resource churn.

## Context experiment additions

The second milestone keeps all periodic checks and adds a native C suite on Unix,
Pascal ContextTests and ContextDemo. The driver builds static helper objects and
archives from the pinned upstream assembly and requires fresh outputs at every
stage; an old test executable cannot certify a compiler that produced nothing.

Context builds enable FPC stack checking and optimization (`-Ct -O2`). Tests
interleave protected Pascal bodies and preserve local data, managed
values, stack bounds and floating-point rounding. They exercise callback failures,
cooperative cancellation and rejected destruction of suspended tasks. A different
thread must be refused without mutating task state. The identity mutation must
fail with CONTEXT_TASK_IDENTITY. Unix's SJLJ isolation mutation must fail with
CONTEXT_RTL_ISOLATION before throwing through a corrupt chain. Windows uses native
SEH instead, so that particular mutation is explicitly not applicable there.
Another Unix executable deliberately omits cthreads and must demonstrate an
explicit constructor rejection, so a constant thread ID cannot bypass ownership.

ContextDemo records 16 completed tasks and 16,000 yields on one carrier, plus a
separate cancelled task whose finalizer must run once. Cancellation is outside the
timing window. Timing includes the demo's resume loop and minimal callback work;
it is descriptive, and no relation to the periodic deadline tolerance is inferred.
The requested 256 KiB per task is a stack reservation parameter, not a measurement
of committed memory. Guard pages add overhead; no overflow-recovery or leak-freedom
claim follows from these functional tests.

The source package builds PeriodicDemo, ContextDemo, RuntimeDemo and QuickStart
in a clean consumer. Each native archive contains these four demos, their
evidence and MIT/Boost notices. All four hashes must match the same clean
revision's summary.
Nonignored untracked inputs also make the repository dirty. ReferenceDemo requires
optional pinned benchmark inputs and is not in the native runtime distribution.

CI also downloads Boss 3.0.17 using pinned official release checksums and runs
`scripts/boss_consumer.py` on all four hosts. A fresh project and isolated
`BOSS_HOME` install the requested remote branch or tag through Boss. The installed
cache's Git revision must equal the expected commit: silent version fallback is
a failure. Boss exports the dependency without `.git`, so verification addresses
its isolated cache explicitly and compares every exported source file with that
commit (allowing Boss's Pascal CRLF normalization). The consumer's parent Git
checkout cannot substitute for dependency provenance.
The installed package's own build helper then compiles and runs QuickStart,
including the Unix native helper. Logs, consumer manifests and a binary hash
are retained under `build/boss-consumer/`. Plain unversioned installation is
verified separately after publication; it can resolve differently as tags change.
Boss 3.0.17 also advances a version-constrained installation to `main` when
that branch moves beyond the tag. A constraint alone is therefore not a
reproducibility guarantee. The exact-revision check deliberately rejects this
case, including on reruns of an older release workflow. Use the tagged clone
or source ZIP instructions in the getting-started guide for a fixed revision.

FPC 3.2.2 context support is an experiment with a narrow RTL adapter. Active
exception-handler/unwind suspension, allocator/error-hook suspension, asynchronous
exceptions/signals during handoff, nondefault shadow-stack configurations and
unvalidated compiler versions remain outside its qualification. See the
[context contract](context-contract.md) for the ownership and cancellation rules.

## Integrated runtime and comparisons

Windows CI installs the official Lazarus 4.4/FPC 3.2.2 x64 distribution through
`scripts/install-fpc-windows.ps1`, with bounded mirror downloads and a pinned
SHA-256. The retrieved installer had a valid Authenticode signature from Stichting
Programming Free Pascal & Lazarus Foundation. CI requires the same hash and
verifies compiler version/CPU after installation. This replaces an automatic
SourceForge download that stalled until the hosted job timed out.

NotificationTests covers preposted signals, coalescing, parking races, cancellation
and resource churn. Paired-clock tests exercise uncertainty, offset changes and
native availability. SchedulerTests uses virtual time and producer handshakes for
bounded admission, FIFO turns, delayed tasks, duplicate wakes, Post rollback,
cooperative timeout, ownership and clock-fault cleanup. It also covers
carrier preemption separately from virtual deadline assertions: the resume
condition test deliberately pauses for 20 ms under a 2 s cleanup safety budget
while still requiring virtual time 10 us and final timer observations at 100 us.
ChannelTests covers
full/empty predicates, close/drain and cancellation. ServiceTests covers fixed
epoch across suspension, skips, independent stop and retained live resources.
ServiceResumeTests verifies idle and active resume, segment accounting and
cancelled cleanup. EventHubTests verifies bounded atomic fanout, managed payload
release, pending source disposal, recipient cancellation, active-handler timeout
and safe suppression of posted deliveries after their service has been freed.

Additional mutations require SCHEDULER_READY_ONCE and SERVICE_STOP_NO_CALLBACK,
exit 1. A deliberately failing reference callback must produce REFERENCE_HOST_FAULT,
exit 1: successful reference-host shutdown alone does not establish successful work.

RuntimeDemo records every started activation, including one cancelled during a
compatible wait, and its final cleanup timestamp. Each activation accounts for
one accepted or rejected event; accepted deliveries complete or are explicitly
disposed during stop. Validation checks phase, latest-due index, non-overlap,
timestamps, event counts and shutdown.
Empty traces remain descriptive data but cannot certify demo/consumer execution.
Samples are preallocated and printed after stop.

The FPC allocation observer replaces three entry points during RunUntil and
restores the original memory manager in finally. It first self-tests an explicit
allocation/reallocation. Hooks never suspend or allocate. Counts are entry calls,
not physical allocations; heap before/after and process-lifetime peak are not OS
committed memory. Native stacks request 256 KiB each plus overhead. RSS/VMS remain
external sampled observations. See the [FPC interface](https://github.com/fpc/FPCSource/blob/release_3_2_2/rtl/inc/heaph.inc).

`--references` fetches exact SHAs without modifying sibling repositories.
Workers/pool/fibers use the same fixed-epoch native-timer callback adapter. Pool
jobs retain their worker while waiting; fewer workers than services cause reported
starvation. The unmodified host has its own interval policy: only actual intervals,
counts and callback durations are compared, never invented fixed-epoch deadlines.
All modes use a declared 50 ms startup window, 200 nominal cycles, 100 us CPU work,
1 or 8 services and a four-worker pool. Mixed events declare the same immutable
payload size, queue capacity, fanout and handler CPU work. Admission, completion,
disposal and rejection counts are checked. Results are not a controlled ranking.

Runtime traces record the requested wait deadline, scheduler observation of timer
eligibility, first enqueue, resume, callback start and completion. Missing stages
remain null for inline or non-timer dispatch. The latest-due activation deadline
can follow the original enqueue, so it is validated separately. Observation is
not a kernel interrupt timestamp. Crossing-resume invocations and segments are
separated from uninterrupted distributions. Physical power cycling is not inferred
from simulated clock generations or successful native clock reads.
