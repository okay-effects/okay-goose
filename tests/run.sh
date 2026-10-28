#!/usr/bin/env bash
# okay-goose's tests: okgc built, each example run and its output compared with tests/expected.
# GOOSE: the goose compiler (default ../goose/build/goose beside this repository)
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
goose=${GOOSE:-$here/../goose/build/goose}
cd "$here"
mkdir -p build
fail=0
check() {  # name, actual output file
    if diff -u "tests/expected/$1.out" "$2" > /dev/null; then echo "ok   $1"; else echo "FAIL $1"; diff -u "tests/expected/$1.out" "$2"; fail=1; fi
}
"$goose" build src/okgc.goose -o build/okgc > /dev/null || { echo "FAIL okgc does not build"; exit 1; }
build/okgc examples/shop.okg build/shop.goose && "$goose" build/shop.goose > build/shop.out 2>&1
check shop build/shop.out
build/okgc examples/choose.okg build/choose.goose && "$goose" build/choose.goose > build/choose.out 2>&1
check choose build/choose.out
build/okgc tests/bad_machine.okg build/bad_machine.goose > build/bad_machine.out 2>&1
check bad_machine build/bad_machine.out
build/okgc tests/bad_rows.okg build/bad.goose > build/bad_rows.out 2>&1
check bad_rows build/bad_rows.out
build/okgc tests/missing_op.okg build/missing.goose && "$goose" build/missing.goose > build/missing.out 2>&1
if grep -q "missing.goose:2: error: unknown function: refund" build/missing.out && grep -q "in fn pay(NoRefund&)" build/missing.out; then echo "ok   missing_op"; else echo "FAIL missing_op"; fail=1; fi
for p in 01_context 02_machine; do "$goose" proto/$p.goose > build/$p.out 2>&1; check $p build/$p.out; done
exit $fail
