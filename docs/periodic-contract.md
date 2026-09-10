# Periodic contract

Time is signed Int64 microseconds from a monotonic clock. Epoch must be
nonnegative, period positive. The first deadline is epoch + period. Reject
overflow; do not wrap. The schedule owns no clock and performs no OS calls.

There is one schedule owner. `TryAcquire` and `Complete` must be serialized by
that owner; schedule instances themselves are not general thread-safe queues.
Only the native timer's cancellation operation is explicitly cross-thread.

`TryAcquire` before a deadline or while active returns false. When idle and late,
it admits the latest due cycle, counts older due cycles as skipped, and records
the original deadline. It never executes early. Completion skips any additional
deadlines through the completion time inclusive and moves to the first future
deadline. No replay backlog and no overlapping invocation of one service.

Cancel forbids new acquisitions; completion of an already active invocation
remains legal. Calling Complete without an active invocation is a usage error.
An invocation's start must not precede the last observed schedule time. Reject
backward time. Range/clock errors must not leave a partly updated schedule.

Each sample includes planned deadline, actual start and completion. Started and
skipped counters must reconcile with the original cycle indices. Reports must
include skipped cycles, not only successful callback latency.

The prototype reports timing, not hard real-time certification. An explicit
qualification profile is required before a timing pass/fail claim.
