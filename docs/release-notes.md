First experimental milestone of Delphi Fiber Runtime: fixed-rate periodic
scheduling and native cancellable timers, targeting a planned 1 kHz cadence.

Includes Windows, Linux and macOS demo packages, tracked source and SHA-256
checksums. The release workflow compiles and executes functional tests, negative
builds, descriptive benchmarks and clean-consumer checks on the tagged revision.
Each native archive includes compiler/CPU/OS metadata and its raw timing evidence.

Timing results are descriptive, with no universal 1 ms guarantee. Delphi compiler
validation remains pending; Free Pascal results do not certify Delphi compatibility.
Suspend/resume handling is not yet validated. This release does not contain a
fiber context runtime or transparent virtual threads; those are subsequent stages.
