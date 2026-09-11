# Pascal code style

First-party Pascal follows the readable layout used by the sibling
`delphi-concurrent-pool` and `delphi-service-host` libraries.

- Use two spaces per indentation level; never use tabs.
- Put `begin`, `end`, `try`, `except` and `finally` on their own lines.
  A terminator such as `end;` or `end.` belongs on the same line as `end`.
- Write one executable statement per line, including short accessors and guards.
  Put the body of an `if`, `while` or `for` on the following indented line.
- Separate routine implementations with a blank line. Keep routine declarations
  at the outer scope and indent local declarations and executable bodies.
- Put `uses` on its own line and list units on separate indented lines. Preserve
  their order because initialization and name resolution can depend on it.
- Keep related fields together, with spaces around operators and after commas.
  Wrap long signatures and expressions at a meaningful boundary; aim for 100
  columns without splitting string literals just to satisfy a width target.
- Keep compiler directives intact and visible on separate lines. They define
  compiler, CPU and ABI boundaries; formatting must not reorder or rewrite them.
- Explain ownership, lifetime and concurrency constraints where they matter.
  Preserve useful comments rather than describing every obvious statement.
- Keep each file below 500 lines. If expanded code exceeds the limit, extract
  complete related routines into a named include at the same declaration point.
  Avoid splitting a routine or hiding execution order behind unrelated files.

The `.editorconfig` supplies whitespace defaults. Vendored native code retains
its upstream formatting. A formatter must leave tokens, string literals,
compiler directives and meaningful comment text unchanged; disable transformations
such as adding/removing blocks, semicolons or sorting `uses` clauses.

For formatting-only changes, compare the Pascal token sequence with the base
revision, expanding newly extracted includes at their original position, then
run `python scripts/check.py --out build/style-check`. Hosted compiler/platform
checks remain necessary for the platform matrix; a local pass is evidence only
for the compiler and platform actually executed.
