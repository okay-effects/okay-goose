# The resumable lanes made faster (2026-10-28)

`okgc build bench/lanes.okg -o build/lanes --include bench/opaque.h`; µs per run of n = 1000 (so ns per step).
Method: each lane run alone (`build/lanes R:choose`), A and B alternating, every run holding JMH's lock
(`$TMPDIR/jmh.lock`: other sessions measure on this laptop), 3–5 rounds each, medians. Since 742625c every answer
of a lane goes through `okay_opaque` (an empty asm, as Zig's `doNotOptimizeAway` and Rust's `black_box` in their
lanes): without it the threaded generator folds into n(n-1)/2 and measures nothing. `general` also keeps each answer
(`okay_keep(v)`, as Zig's), which costs the old code 1.28 → 1.62.

| lane | before | after | okay-zig resumable | okay-rust `#[resumable]` |
|---|---|---|---|---|
| R:choose — every path of a choice among 1000 | 1.237 | **0.400** | 0.38 | 0.24 |
| R:generate — a generator of 1000 values, summed | 1.202 | **0.240** | 0.39 | 0.29 |
| R:general — a deep handler taking the rest at each of 1000 steps | 1.623 | **0.240** | 0.39 | 0.35 |

Paired A/B, load 1.8–2.9, 5 rounds each. Again later under load 4.2–4.4, 3+3 rounds, the old
okgc (with only 742625c) against 61ddd95: choose 1.311 → 0.440, generate 1.316 → 0.279, general 2.038 → 0.278;
G:state 0.018 / 0.018 and G:writer 0.145 / 0.147 unchanged (no resumable code in them). Zig's and Rust's numbers are
theirs, from their own runs, not measured again here.

What was slow, and why:

- **choose: a recursive call for every leaf.** The handler `among(n, k) { for i in n { resume(k, i); } }` resumes
  not last, so okgc wrote `count_all(cx, resume(cx, k, i), found)`: for each of the 1000 paths a call of the
  recursive handler with the step (a 33-byte packed enum) in memory, its prologue spilling 10 registers, to find
  `Done` at once and add 1. Now (f874783) such a resume goes through `okay_rest_<handler>`, a plain function the
  C compiler inlines: `Done` is the return clause's right there, in the clause's loop; only an operation calls the
  handler again. The loop per path: the asm barrier, the frame's `at` tested, `found` incremented. 1.24 → 0.40.
- **generate, general: four dispatches through `match at` per step.** okgc cut `for i in 0..n { emit(i); }` into
  blocks — header, body, the stop's resume point, the increment — each ending `at = l; continue;`, and Goose writes
  `match at` as a chain of `if (at == 0) … else if (at == 1) …`. Everything was inlined (run_numbers into the
  handler's loop, the frame in registers, no copy), but each value went 5 → 3 → 1 → 2 round the loop, a compare
  chain each time. Now (61ddd95) a block jumped to from one place only is written at that place: the resume point
  holds the increment, and the loop's header (jumped to from two places) is the one dispatch left. 1.20 → 0.24 and
  1.62 → 0.24. The C compiler can do the same (`-mllvm -enable-dfa-jump-thread` on the old code: generate 1.28 →
  0.27, general 1.92 → 0.28, load 4.4), which confirms where the time went; but okgc should not depend on a flag.

What was checked and is not the cost:

- The frame is not copied per step in these lanes: the step function is inlined into the handler's loop and the
  frame's fields live in registers (seen in the assembly, `cc -O2 -S` of `goose -o lanes.c`). In choose the frame
  (24 bytes) is copied once per path, as it must be: each path resumes it.
- No indirect call, no function pointer: the dispatch is an if-chain on an integer.
- No bounds or overflow checks in the hot loops: `gs_add_i64` is a plain add without `--debug`.

Tried, refuted:

- Threading every block (the loop's header written into both its places too, one dispatch per step instead of
  two): generate 0.240 / 0.240, general 0.260 / 0.251 against single-place only — no gain, kept the simple rule.
- `-O3` instead of Goose's `-O2` (a `--cc` wrapper): generate 0.280 / 0.282, general 0.282 / 0.281, and choose
  1.135 against 0.437 — far worse. Kept -O2.
- LTO: nothing to gain, the program is one C file.

Also found and fixed (8b91604): a variable set before a stop and read after it in straight-line code was not kept
by the frame (it came back as its default) — the block after a stop was not a block of its own in the frame's
analysis. `examples/loops.okg` (`pair`) checks it.

# Lanes against okay-rust (before the work above: R: numbers as of 9d51a22)

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

## Against okay-rust's fast API (okay::typed)

The same lanes against okay-rust's one API — compiled, as okay-goose is — three alternating rounds under JMH's
lock, 2026-10-28, load 2.1–3.1, medians. The rest taken many times is okay-rust's typed API by REPLAY (the body run
again for each path), as it was until 2026-10-27 (commit 0fb0ddd; the replay has been removed since: the one API
is one-shot by design).

| lane | okay-goose | okay-rust typed | Scala (okay-core) |
|---|---|---|---|
| every path of a choice among 1000 | **1.25** | 5.92 (replay) | 13.24 |
| the rest taken and resumed at each of 1000 steps | **1.26** (R:general) | 2.21 (T:generate: suspended, resumed once each) | 9.44 |
| a generator of 1000 values | **1.26** | 2.21 | 22.6 (okay-one's) |
| 1000 values told | **0.14** | 1.08 | 9.45 |

Both are compiled state machines. Where the time goes in Rust: an `async` body is polled through `Pin`, `Poll` and a
`Context`, its handlers behind `RefCell`s, each suspension a round through the poll loop; a path of a choice runs the
body again from its start. In Goose a step is a plain function returning a plain enum, and a rest resumed again is a
struct copied. The writer: a Goose array grows by a pointer bump and never moves; a `Vec` reallocates.
