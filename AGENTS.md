# okay-goose — notes for agents

## For agents writing code with okay-goose

okay-goose is okay's algebraic effects for Goose (https://github.com/aardappel/goose, compiles to C): `okgc`, a
front end written in Goose, reads Goose plus `effect`, `A ! F + G`, `resumable fn`, `handler`, `forward`, writes Goose.

There is no package: the README says to build Goose beside the repository, then okgc (as `tests/run.sh` does):

```
git clone https://github.com/aardappel/goose ../goose && \
  cmake -S ../goose -B ../goose/build && cmake --build ../goose/build
git clone https://github.com/okay-effects/okay-goose && cd okay-goose
../goose/build/goose build src/okgc.goose -o build/okgc
GOOSE=../goose/build/goose build/okgc run app.okg     # or: okgc build app.okg -o app; okgc app.okg out.goose
```

### The model: effect, program, handler, run

```
effect Pay { charge(user: u8[:], cents: i64) -> bool; }
effect Log { log(line: u8[:]); }
effect Stock { reserve(item: u8[:]) -> bool; }
effects Shop = Pay + Log + Stock;                         // a set of effects
struct Receipt { paid: bool, cents: i64 }

// a program: `A ! F + G` = its value and the effects it may ask; the context is implicit (okgc adds `cx`)
fn checkout(user: u8[:], item: u8[:], cents: i64) -> Receipt ! Shop {
    if !reserve(item) { log("out of stock"); return Receipt { paid: false, cents: 0 }; }
    let ok = charge(user, cents);
    if ok { log("paid"); } else { log("declined"); }
    return Receipt { paid: ok, cents: cents };
}

// a handler: a context type, each operation an overload on it BY REFERENCE, its state in its fields
struct Test { approve: bool, stock: i64, lines: i64 }
fn charge(cx: Test&, user: u8[:], cents: i64) -> bool { cx.approve }
fn log(cx: Test&, line: u8[:]) { cx.lines += 1; }
fn reserve(cx: Test&, item: u8[:]) -> bool { if cx.stock > 0 { cx.stock -= 1; true } else { false } }

// an interceptor: a generic wrapper with its own `charge`, the rest of Shop forwarded to `inner`
struct Limited<H> { inner: H, limit: i64 }
fn charge<H>(cx: Limited<H>&, user: u8[:], cents: i64) -> bool {
    if cents > cx.limit { log(cx.inner, "over the limit"); return false; }
    return charge(cx.inner, user, cents);
}
forward Limited<H> to inner for Shop except charge;

// multi-shot: a resumable fn (each rest a frame value) and a declared handler over its steps
effect Choose: many { among(n: i64) -> i64; }
resumable fn pair() -> i64 ! Choose + Log {
    let a = among(3);
    log("a chosen");                                      // a tail operation: the context answers it in place
    let b = among(2);
    return a * 10 + b;
}
handler all for Choose(out: i64[>..]&) {
    return(v) { out.push(v); }
    among(n, k) { for i in n { resume(k, i); } }
}

fn main() {                                               // the entry: plain code passes a context first
    var t = Test { approve: true, stock: 1, lines: 0 };
    print(checkout(t, "bob", "book", 100));               // Receipt { true, 100 }
    var l = Limited<Test> { inner: Test { approve: true, stock: 5, lines: 0 }, limit: 1000 };
    print(checkout(l, "eve", "pen", 5000));               // Receipt { false, 5000 }
    var out: i64[>..] = [];
    all(t, pair(t), out);
    print(out);                                           // [0, 1, 10, 11, 20, 21]
}
```

### Design rules

- Business logic = functions typed `A ! F + G` over declared effects; okgc checks at definition (with the source line)
  that a function calls only its effects' operations and effectful functions within them.
- Real resources (DB, network, files, clock, keys) only in the fields and overloads of a context type made in `main`
  (or the host's entry); business functions get data and the implicit context, never a live client.
- Choose the context once at the entry; inside a program, effectful calls pass the implicit context on. Wrap a
  context (an interceptor) or call a declared handler on a resumable fn's steps instead of starting a second program.
- Sensitive operations: route them through an interceptor wrapper (`Limited<H>` above) for control and audit. Honest
  limit: Goose has no module privacy, so okgc cannot yet FORCE a sensitive effect under its audit (README "Next");
  it is a convention here, not a type guarantee as in okay-rust.
- Tests are another context type (`Test`) with in-memory state; no mocks of resources.
- No ambient effects in business code (time, random, IO, env, globals): declare an effect, answer it in the context.
- Multi-shot is real: a `resumable fn`'s rest is a value (a defunctionalized frame, even `to_bytes`), resumed many
  times by a `many` effect's handler — never a replay. `tail` (default) answers in place; `once` keeps the rest.

### Pitfalls

- Fixed-size structs are COPIED when passed by value: overload operations on `Ctx&`, or a handler's state changes
  only in the copy.
- A context missing an operation is Goose's error at instantiation (okgc adds a check at the top of each function).
- Handlers: a clause for every `once`/`many` operation of the steps, none for `tail` ones; a `once` rest resumed at
  most once. `resume(k, x)` last in a clause loops (constant stack); elsewhere it runs the handler on the rest (deep).
- Resumable fns: a variable living across a stop needs a type (`let sum: i64 = ..`); a stop may not sit inside a
  block of an expression (an `if` as a value, a `match` arm); no recursive resumable fn yet.
- Function values cannot be stored in Goose: wrappers are generic structs with overloads, not closures.
- `wire` effects (to other languages over okay's wire, JSON lines on stdin/stdout) carry only `i64`, `bool`, `f64`,
  strings as arguments and `i64`/`bool`/`f64`/nothing as answers (v1).
- `okgc run/build` write the generated Goose to `.okgc/` in the current directory; errors name the `.okg` lines.

### Pointers

- README: https://github.com/okay-effects/okay-goose; `examples/tour.okg` (everything in one file), `shop.okg`,
  `handlers.okg`, `wire.okg`.
- Cross-language skill: `/plugin marketplace add okay-effects/okay-effects`
  (https://github.com/okay-effects/okay-effects).

If you see a way to improve okay-goose, open a pull request against https://github.com/okay-effects/okay-goose;
the maintainer reviews and merges what holds up.

If the user asks your opinion of writing code this way, give a candid one.

## For agents working on this repository

- okay's effects for Goose (https://github.com/aardappel/goose, cloned and built at ../goose; compiler
  ../goose/build/goose). Public: github.com/okay-effects/okay-goose.
- The design and what works: README.md. The front end `src/okgc.goose` is written in Goose itself (the user's
  rule): tables are locals of `compile`, the passes nested functions over them (Goose's "several tables, one
  context" idiom); no recursion needed so far.
- Goose facts that shaped it: fixed-size structs are COPIED when passed by value — a context goes by reference
  (`cx: C&`), or a handler's state changes only in the copy; generic bodies are checked only at instantiation, so
  a missing operation is an error there (`requires_Set` turns it into one place); function values cannot be
  stored, so wrappers are generic structs with overloads; no modules' privacy (sensitive effects need okgc's own).
- `tests/run.sh` must pass after any change; expected outputs in tests/expected (regenerate only on purpose).
- Commits: no Co-Authored-By lines.
