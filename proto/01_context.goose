// 1. EFFECTS AS OPERATIONS OVER A CONTEXT: a program takes one untyped `cx`; each operation an overload chosen by
// the context's type when the program is monomorphized. An interceptor is a generic wrapper of a context.

struct Receipt { paid: bool, cents: i64 }

// the program: its effects are the operations it calls — no list of them; the context by reference (a struct
// passed by value is copied, as in C, and a handler's state would change only in the copy)
fn checkout<C>(cx: C&, user: u8[:], cents: i64) -> Receipt {
    let ok = charge(cx, user, cents);
    if ok { log(cx, "paid"); } else { log(cx, "declined"); }
    return Receipt { paid: ok, cents: cents };
}

// a test context: its handlers and its state
struct Test { approve: bool, told: i64 }
fn charge(cx: Test&, user: u8[:], cents: i64) -> bool { cx.approve }
fn log(cx: Test&, line: u8[:]) { cx.told += 1; print("test log: ", line); }

// another context: a bank with a balance
struct Bank { balance: i64 }
fn charge(cx: Bank&, user: u8[:], cents: i64) -> bool {
    if cents > cx.balance { return false; }
    cx.balance -= cents;
    return true;
}
fn log(cx: Bank&, line: u8[:]) { print("bank log: ", line); }

// an interceptor: a limit around any context H — charge checked, log passed on
struct Limited<H> { inner: H, limit: i64 }
fn charge<H>(cx: Limited<H>&, user: u8[:], cents: i64) -> bool {
    if cents > cx.limit { log(cx.inner, "refused by the limit"); return false; }
    return charge(cx.inner, user, cents);
}
fn log<H>(cx: Limited<H>&, line: u8[:]) { log(cx.inner, line); }

// an aborting handler: a charge over a hard ceiling ends the whole session
struct Strict { ceiling: i64 }
fn charge(cx: Strict&, user: u8[:], cents: i64) -> bool {
    if cents > cx.ceiling { return Receipt { paid: false, cents: -1 } from session; }
    return true;
}
fn log(cx: Strict&, line: u8[:]) { print("strict log: ", line); }

fn session(cx: Strict&) -> Receipt {
    let a = checkout(cx, "ann", 10);
    print("first: ", a.paid);
    return checkout(cx, "ann", 5000);   // aborts: the session's value is the handler's
}

fn main() {
    var t = Test { approve: true, told: 0 };
    let r1 = checkout(t, "bob", 100);
    print(r1.paid, " told ", t.told);

    var b = Bank { balance: 500 };
    let r2 = checkout(b, "bob", 300);
    let r3 = checkout(b, "bob", 300);
    print(r2.paid, " ", r3.paid, " balance ", b.balance);

    var l = Limited<Bank> { inner: Bank { balance: 10000 }, limit: 1000 };
    let r4 = checkout(l, "eve", 5000);
    let r5 = checkout(l, "eve", 50);
    print(r4.paid, " ", r5.paid, " balance ", l.inner.balance);

    var s = Strict { ceiling: 1000 };
    let r6 = session(s);
    print("session: ", r6.paid, " ", r6.cents);
}
