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
portable committed-memory accounting. Allocation counts and separate committed /
reserved memory accounting remain future instrumentation.

The release workflow runs the same matrix on the tag revision before publishing
source and native demo archives with SHA-256 checksums. A source archive is also
extracted into a clean temporary directory with spaces, compiled and executed.

## Evidence and limits

[Local and hosted results](evidence/README.md) include Windows x86/x64, Linux WSL2,
native hosted Linux and hosted macOS ARM64. GitHub Actions provides the full
per-revision build artifacts. The local suite has 55 deterministic schedule
checks, native timer tests, two negative executables and 15 Python test methods.
The installed Delphi edition prints `This version of the product does not
support command line compiling.` while returning exit code 0; that is recorded
as unavailable, not a successful Delphi build.

This milestone measures one persistent executor. Comparison with the existing
pool/service-host implementations, mixed service/event loads, many-service scaling,
lost-wakeup stress under full runtime traffic and context/RTL tests belong to
subsequent milestones. No leak-freedom claim is inferred from resource churn.

## Context experiment additions

The second milestone keeps all periodic checks and adds a native C suite on Unix,
Pascal ContextTests and ContextDemo. The driver builds static helper objects and
archives from the pinned upstream assembly and requires fresh outputs at every
stage; an old test executable cannot certify a compiler that produced nothing.

Context tests interleave protected Pascal bodies and preserve local data, managed
values, stack bounds and floating-point rounding. They exercise callback failures,
cooperative cancellation and rejected destruction of suspended tasks. A different
thread must be refused without mutating task state. The identity mutation must
fail with CONTEXT_TASK_IDENTITY. Unix's SJLJ isolation mutation must fail with
CONTEXT_RTL_ISOLATION before throwing through a corrupt chain. Windows uses native
SEH instead, so that particular mutation is explicitly not applicable there.

ContextDemo records 16 completed tasks and 16,000 yields on one carrier, plus a
separate cancelled task whose finalizer must run once. Cancellation is outside the
timing window. Timing includes the demo's resume loop and minimal callback work;
it is descriptive, and no relation to the periodic deadline tolerance is inferred.
The requested 256 KiB per task is a stack reservation parameter, not a measurement
of committed memory. Guard pages add overhead; no overflow-recovery or leak-freedom
claim follows from these functional tests.

The source package builds both demos in a clean consumer. Each native archive
contains both demos, their evidence, the MIT notice and the Boost Software License.
Both executable hashes must match the same clean revision's check summary.

FPC 3.2.2 context support is an experiment with a narrow RTL adapter. Active
exception-handler/unwind suspension, allocator/error-hook suspension, asynchronous
exceptions/signals during handoff, nondefault shadow-stack configurations and
unvalidated compiler versions remain outside its qualification. See the
[context contract](context-contract.md) for the ownership and cancellation rules.
