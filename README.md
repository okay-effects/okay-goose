# okay-goose

[okay](https://github.com/okay-effects/okay)'s algebraic effects for [Goose](https://aardappel.github.io/goose/), a
memory-safe systems language that compiles to C: no heap, no GC, function values only at compile time, whole-program
monomorphization. Local, not published.

## How effects map onto Goose

| | in Goose |
|---|---|
| an effect | a set of operations over a context: `charge(cx, user, cents) -> bool` |
| a program with effects | `fn checkout<C>(cx: C&, …)`: it calls the operations; monomorphized for each context |
| a set of effects | the context's type (`Prod`, `Test`, `Limited<H>`): one type, no list in each function |
| a handler | an overload of the operations for the context's type, its state in the context's fields |
| an interceptor (control, audit) | a generic wrapper of a context: `Limited<H>`, its own `charge`, the rest forwarded |
| a handler dropping the rest | `return E from f`: a jump to it past any frames, no unwinder |
| the rest kept and resumed (once, many times) | a machine: the program as data, each rest a named variant (defunctionalized), `k` a copy of the frames — and bytes (`to_bytes`): it can be saved and resumed elsewhere |

Goose's own design note on coroutines (`docs/design/coroutines.md`, October 2026) reaches the same place: a
suspended function keeps neither of its stacks, so coroutines are stackless state machines, their frames values.

## okgc — the front end (v0), written in Goose

It reads Goose with four additions and writes plain Goose:

```
effect Pay { charge(user: u8[:], cents: i64) -> bool; refund(id: i64); }
effects Shop = Pay + Log + Stock;                      // a set of effects, of effects or of sets
fn pay(user: u8[:], cents: i64) -> Receipt ! Pay + Log {   // A ! F + G: a value, and the effects asked for
    let ok = charge(user, cents);                      // an operation: the context is implicit
    if ok { log("paid"); } else { log("declined"); }
    return Receipt { paid: ok, cents: cents };
}
fn audit_all(n: i64) ! Log { … }                       // effects and no value
forward Limited<H> to inner for Shop except charge;    // a wrapper's other operations passed on
```

A function's type is `A ! F + G`: its value and its effects (effects or sets). The context is implicit: okgc adds a
type parameter and a first parameter `cx`, and passes it to every operation and every function with effects called
in the body. Plain code calls one with a context first: `checkout(test, "bob", "book", 100)`. Checked at definition,
with the source line: a function calls only the operations of its effects, and functions with effects within its
own. Written out: the context added; a check at the top that the context has every operation (a missing one is
Goose's error, naming it); `requires_Shop(cx)` for each set; the forwarding functions; everything else as it was —
ON THE SAME LINES, so an error Goose reports in the output is at the source's line.

```
okgc input.okg output.goose
```

### Machine fns: the rest as a value

An effect's kind says what its handlers do with the rest: `tail` (the default) answers and goes on, `once` and
`many` keep it. In a `machine fn` an operation of a `once`/`many` effect is where the program stops; okgc cuts it
there, each rest a frame (a variant naming the stop, its fields the variables it needs), each piece a function.

```
effect Choose: many { among(n: i64) -> i64; }

machine fn pick(base: i64) -> i64 ! Choose + Log {
    let a = among(3);              // a stop: the rest kept
    log("first chosen");           // a tail operation: the context answers it in place
    let b = among(2);
    let sum: i64 = base + A[a];    // a variable living across a stop has a type
    return sum + B[b];
}
```

Written out, a STATE MACHINE: its frame one struct — where it stopped (`at`) and every variable of the function
(`struct Pick_k { at: i64, base: i64, a: i64, b: i64, sum: i64 }`) —, its body `loop { match at { … } }`, cut into
blocks only where a statement holds a stop: a stop ends a block (its step returned, the rest a frame), an `if`,
`while`, `for` or `loop` holding one becomes jumps between blocks (`break`, `continue` and `return` inside too), a
statement holding none is copied as it is. Its steps: `enum Pick { Done { v: i64 }, Among { n: i64, k: Pick_among } }`;
the first `pick(cx, base)`, the others `resume(cx, k, v)` by the operation's rest type, `v` of its type — no cast. A
handler is plain code over the steps: `all` resumes a rest once for each alternative, `first` once, a generator's
consumer pulls (`examples/loops.okg`). A step is flat: written out as bytes (`to_bytes`), it is resumed from them
later or elsewhere (`examples/choose.okg`). A variable of a machine fn has a type (op-bound ones take the
operation's), one name each.

A machine fn calls a machine fn as a statement (`let x = range(0, 3);`): the callee's steps pass out as the
caller's — its rest kept in the caller's frame, a field —, its value bound when it is done; resumed, the value goes
to the callee (`examples/nested.okg`: a generator delegating to another, a choice made in a callee).

A stop inside an expression is taken out before its statement — left to right, innermost first —, its value a
made-up variable in the call's place: in a `let`, an `if`'s condition, a `while`'s (asked again at each turn), a
`for`'s range, a `return`, a `match`'s scrutinee (`examples/expressions.okg`). Not inside a block of an expression
(an `if` as a value, a `match` arm): there it may not run at all.

### Handlers declared

```
handler all for Choose(out: i64[>..]&) {
    return(v) { out.push(v); }
    among(n, k) { for i in n { resume(k, i); } }
}
handler count_paths for Choose -> i64 {
    return(v) { 1 }
    among(n, k) { var s: i64 = 0; for i in n { s += resume(k, i); } s }
}
```

One function for the steps of ANY machine fn with those effects (`all(cx, pair(cx), out)`): a loop over the steps,
a clause for each. `resume(k, x)` last in a clause goes on in the loop — no stack: a generator of a million values
is summed in constant stack —; anywhere else it runs the handler on the rest, a deep handler, its value the
handler's for that rest (`count_paths`). Checked: a clause for every once/many operation, each naming its
arguments and the rest; no clause for a tail operation (the context answers those). `examples/handlers.okg`.

## Layout

- `src/okgc.goose` — the front end
- `examples/shop.okg` — the shop: effects, sets, `A ! F + G`, an interceptor with forwarding
- `examples/choose.okg` — a machine fn: all paths, the first, a step saved as bytes and resumed
- `examples/loops.okg` — a generator pulled value by value; a search whose `while` stops at each guess
- `examples/nested.okg` — machine fns calling machine fns: a generator delegating, a choice in a callee
- `examples/handlers.okg` — handlers declared: all paths, the first, the number of paths, a million values summed
- `examples/expressions.okg` — stops inside expressions: a quiz asking its host, numbers made of choices
- `proto/01_context.goose` — effects as overloads on a context, an interceptor, an aborting handler
- `proto/02_machine.goose` — a machine: defunctionalized frames, `among` taking `k`, the `all` handler resuming it
  for each alternative; `k` as bytes and back
- `tests/run.sh` — builds okgc, runs everything, compares with `tests/expected`

```
git clone https://github.com/aardappel/goose ../goose && cmake -S ../goose -B ../goose/build && cmake --build ../goose/build
tests/run.sh
```

## Next

- see BACKLOG.md for what is undecided or later
- sensitive effects (needs okgc's own modules and privacy: Goose has none)
- okgc rewritten in its own dialect, its diagnostics and tables as effects
