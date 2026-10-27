# okay-goose — notes for agents

- okay's effects for Goose (https://github.com/aardappel/goose, cloned and built at ../goose; compiler
  ../goose/build/goose). Local repository, not published.
- The design and what works: README.md. The front end `src/okgc.goose` is written in Goose itself (the user's
  rule): tables are locals of `compile`, the passes nested functions over them (Goose's "several tables, one
  context" idiom); no recursion needed so far.
- Goose facts that shaped it: fixed-size structs are COPIED when passed by value — a context goes by reference
  (`cx: C&`), or a handler's state changes only in the copy; generic bodies are checked only at instantiation, so
  a missing operation is an error there (`requires_Set` turns it into one place); function values cannot be
  stored, so wrappers are generic structs with overloads; no modules' privacy (sensitive effects need okgc's own).
- `tests/run.sh` must pass after any change; expected outputs in tests/expected (regenerate only on purpose).
- Commits: no Co-Authored-By lines.
