# First prototype measurements — 2026-09-10

The second milestone has its own [context experiment evidence](context-2026-09-10.md).
The original periodic measurements below are retained unchanged.

These are short descriptive observations, not benchmarks that certify a temporal
SLA or establish a fair performance ranking of operating systems. Each row is a
different environment. The full JSON files record revision, compiler, native
backend, flags, workload and optional observer. Raw CSV and binaries are in the
[baseline CI artifacts](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34508506135).

The baseline CI passed all functional, negative and clean-consumer checks on
Windows, Linux and macOS at `cc0f0ab`. FPC is 3.2.2 in these runs. The idle workload
plans 2,000 activations at a 1,000 us period with zero synthetic callback work.

| Environment | Started / planned | Skipped | Start lateness p99 (us) |
|---|---:|---:|---:|
| Local Windows x86 | 1,997 / 2,000 | 3 | 800 |
| Local Windows x64 | 1,997 / 2,000 | 3 | 643 |
| Local Linux x64 via WSL2 | 2,000 / 2,000 | 0 | 54 |
| Hosted Windows | 2,000 / 2,000 | 0 | 735 |
| Hosted Linux x64 | 2,000 / 2,000 | 0 | 48 |
| Hosted macOS ARM64, default timer coalescing | 722 / 2,000 | 1,278 | 984 |
| Hosted macOS ARM64, NOTE_CRITICAL experiment | 2,000 / 2,000 | 0 | 386 |

The local host is an AMD Ryzen 7 5700X (8 cores / 16 logical processors). Power
mode and background load were not controlled. WSL2 results are labeled separately.
Local Windows x86 evidence is from `9c06913`; other baseline records identify
their exact revisions. Python/psutil observation runs outside the Pascal process.

Under skip-latest policy, lateness belongs to the most recent eligible deadline
and is less than one period. Therefore p99 lateness alone can conceal severe
cadence loss: the baseline macOS run skipped 63.9% of planned activations.
Always inspect skipped counts and actual inter-start intervals together.

The baseline macOS result motivated a separate experiment using `NOTE_CRITICAL`
to request less timer coalescing. This does not set real-time thread priority or
remove the operating system's scheduling limits. Keep the original observation
for comparison; a hosted rerun is not a controlled same-machine A/B experiment.

The [critical-timer run](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/runs/34508853570)
at `e6ffa8f` passed macOS functional and package checks. In its idle workload,
inter-start p50 was 1,000 us. The short-work workload still skipped 18 of 1,000
cycles: this is evidence of remaining variability, not a 1 kHz guarantee.
Apple documents the flag's effect in the [kqueue manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/kqueue.2).

The short-work scenario adds 100 us of CPU work per activation. The overloaded
scenario adds 2,500 us against a 1,000 us period and intentionally discards cycles;
neither overlaps nor replays a backlog. Their distributions are in the same JSON.
