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
effects Payments = Pay + Log;                          // a set of effects, of effects or of sets
fn pay<C>(cx: C& / Payments, user: u8[:], cents: i64) -> Receipt { … }   // what it may ask of cx
forward Limited<H> to inner for Shop except charge;    // a wrapper's other operations passed on
```

Checked at definition, with the source line: a function calls on its context only the operations of its set, and
calls another function with effects only if that one's set is in its own. Written out: `requires_Payments(cx)` at
the top of such a function (a context lacking an operation is Goose's error inside it, naming the operation), the
forwarding functions, everything else as it was.

```
okgc input.okg output.goose
```

## Layout

- `src/okgc.goose` — the front end
- `examples/shop.okg` — the shop: effects, sets, rows, an interceptor with forwarding
- `proto/01_context.goose` — effects as overloads on a context, an interceptor, an aborting handler
- `proto/02_machine.goose` — a machine: defunctionalized frames, `among` taking `k`, the `all` handler resuming it
  for each alternative; `k` as bytes and back
- `tests/run.sh` — builds okgc, runs everything, compares with `tests/expected`

```
git clone https://github.com/aardappel/goose ../goose && cmake -S ../goose -B ../goose/build && cmake --build ../goose/build
tests/run.sh
```

## Next

- errors of a generated `requires_…` mapped back to the source line
- handlers classified by what they do with `k` (`tail`, `abort`, `once`, `many`) and the mechanism generated:
  direct call, `return … from`, a state machine, the machine
- the machine's frames generated from ordinary code (`machine fn … { a <- among(…); … }`)
- sensitive effects (needs okgc's own modules and privacy: Goose has none)
- okgc rewritten in its own dialect, its diagnostics and tables as effects
