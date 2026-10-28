# Backlog

Not decided, or later. The README's "Next" is what is planned; this is what may be.

- **okgc rewritten in its own dialect** — its diagnostics, tables and passes as effects (`Log`, `State`, `Fail`) with
  handlers: okgc checking itself, the first large program on okay-goose. Undecided (the user, 2026-10-28): wanted
  only if it earns its place; the front end works in plain Goose.
- A recursive resumable fn: a frame holding a frame of itself needs a pool (Goose: no type contains itself by value).
- A stop inside a block of an expression (`if c { op() } else { 0 }` as a value, a `match` arm): lowered as the
  statement forms are, the expression split.
- Handlers forwarding the operations they do not handle to an outer machine (a handler of Choose inside a program
  that also yields): today a handler covers every once/many operation of the steps it runs.
- Sensitive effects: okgc's own modules and privacy (Goose has none), a sensitive effect's handler only under its
  audit, as okay-rust's `Audited`.
- Effect polymorphism for function values: `F: fn(i64) -> i64 ! e` — a higher-order function's effects its
  argument's.
- A host protocol and okay's wire: a resumable fn's steps as data (`Data`, a name and a record) for a host, as
  okay-rust's `okay::host`.
- okay-kernel's TCK on okay-goose's machine.
- Benchmarks against okay-rust's typed lanes and machine.
