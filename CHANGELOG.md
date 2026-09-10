# Changelog

## 0.2.0-prototype.1

- Experimental stackful tasks bound to one native carrier, with explicit yields,
  cooperative cancellation, task-local pointer data and callback error containment.
- Windows native fibers and guarded Unix contexts through a small static C ABI
  and pinned Boost.Context 1.85.0 assembly, including floating-environment handling.
- FPC 3.2.2 RTL compatibility boundary; broader compiler support requires separate
  qualification and does not block use of the independent periodic units.
- Native/Pascal context tests, targeted mutations, switching/cleanup demo and
  release packages containing both demos with source provenance and licenses.
- Integrated timer waits, channels and service lifecycle remain future milestones.

## 0.1.0-prototype.1

- Deterministic fixed-rate periodic schedule with no overlap, skip accounting,
  sticky cancellation and atomic validation of invalid times/overflow.
- Native timer adapters for Windows, Linux and macOS.
- Preallocated CSV benchmark and validated descriptive/explicit-profile reports.
- Cross-platform FPC CI, targeted negative builds, clean-consumer packages and
  tag-driven prerelease publication with SHA-256 checksums.
- This milestone does not implement fibers or transparent virtual threads.
