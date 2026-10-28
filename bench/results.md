# Lanes against okay-rust

`bench/lanes.okg` (`okgc build bench/lanes.okg -o build/lanes`) against okay-rust's `machine/benches/kernel.rs`, the
same programs and n = 1000, µs per run (warm-up 1 s, 5 rounds of 1 s). One laptop, two alternating rounds under
JMH's lock, 2026-10-28, load 2.0–2.6; the median of the two. Scala: okay-core's KernelBenchmark (2026-10-14).

| lane | okay-goose | okay-rust | Scala (okay-core) |
|---|---|---|---|
| writer — 1000 values told, kept | **0.137** (G:writer) | 1.12 (T:writer) | 9.45 |
| a generator of 1000 values, summed | **1.21** (R:generate) | 2.18 (T:generate) | 22.6 (okay-one's) |
| every path of a choice among 1000 | **1.23** (R:choose) | 105.6 (the machine; the one API has no multi-shot rest) | 13.24 |
| a deep handler taking the rest at each of 1000 steps | **1.23** (R:general) | 39.7 (the machine's `general`) | 9.44 |
| state, 1000 gets and puts | 0.017 (G:state: folded) | 0.017 when folded (D:state); 1.87 with the context behind `black_box` (T:state) | 12.47 |

What the numbers are:

- **The direct style** is what okay-rust's typed API is: handlers known at compile time, inlined. Both fold a
  state loop the compiler sees through. The writer is 8× faster here: Goose's growable array grows by a bump of the
  data stack's pointer and never moves; Rust's `Vec` in a `RefCell` checks a borrow and reallocates.
- **The generator** is the same idea in both — a compiled state machine, the rest resumed once — and 1.8× faster
  here: the handler's tail `resume` is a loop over plain values, the frame a small struct.
- **The rest taken many times** (`choose`, `general`) has no counterpart in okay-rust's one API (one-shot by
  design); okay-rust's machine interprets a program as data — nodes, frames and rests on the heap — and is 30–85×
  slower. okay-goose's resumable fn is compiled: its rest is a flat frame, copied by value to be resumed again.
  Against Scala's kernel, 8–11× faster.
- A Goose lane that folds is not a measure of an effect's cost; okay-rust's opaque lanes (`black_box`) have no Goose
  counterpart (Goose has no `black_box`); the state lane is shown for completeness only.
