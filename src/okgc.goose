// okgc — okay-goose's front end, v0: effects declared and checked, plain Goose out.
//
// It reads Goose with four additions and writes plain Goose:
//
//   effect Pay { charge(user: u8[:], cents: i64) -> bool; refund(id: i64); }
//   effects App = Pay + Log;                          // a set of effects (of effects or of sets)
//   fn pay(user: u8[:], cents: i64) -> Receipt ! Pay + Log { … charge(user, cents) … }   // A ! F + G
//   forward Limited<H> to inner for App except charge;   // a wrapper's operations passed on to a field
//
// A function's type `A ! F + G`: its value `A`, its effects `F + G` (effects or sets). Its context is implicit: okgc
// adds it — a type parameter, a first parameter `cx` — and passes it to each operation and to each function with
// effects called in its body. Checked at definition: it calls only the operations of its effects, and functions
// with effects within its own. Plain code calls one with a context first: `pay(ctx, "bob", 100)`. Written out: the
// context added, a check at the top that the context has every operation (a missing one is Goose's error there,
// naming it), `requires_App(cx)` for each set, the forwarding functions, the rest of the text as it was — on the
// same lines: an error Goose reports in the output is at the source's line.
//
//   okgc input.okg output.goose

import std;
import os;

let K_IDENT = 0;
let K_NUM = 1;
let K_STR = 2;
let K_PUNCT = 3;
let K_SPACE = 4;      // whitespace and comments: kept in the output, skipped by the parser

struct Tok { kind: i64, at: i64, len: i64 }
struct Span { at: i64, len: i64 }
struct OpDecl { effect: i64, name: Span, params: Span, ret: Span }      // ret.len 0: no value
// an effect's kind: what its handlers do with the rest — answer and go on (tail), or keep it to resume once or
// many times (once, many: in a resumable fn its operations are where the program stops, the rest a value)
let TAIL = 0;
let ONCE = 1;
let MANY = 2;
struct EffDecl { name: Span, kind: i64, first_op: i64, n_ops: i64, from: i64, to: i64 }
struct MVar { name: Span, ty: Span }                 // a variable a resumable fn's rest may need: a frame's field
// a resumable fn's stop: the operation, the name its value is bound to (len 0: none), its arguments' parentheses,
// the statement's tokens, the variables known before it (vars[..nvars]: the frame's fields)
struct Point { op: i64, bind: Span, args_lp: i64, args_rp: i64, stmt_from: i64, stmt_to: i64, nvars: i64 }
struct SetDecl { name: Span, first: i64, n: i64, from: i64, to: i64 }  // members[first..first+n]: effects
struct Fwd { ty: Span, field: Span, set: i64, first_ex: i64, n_ex: i64, from: i64, to: i64 }
// a function with effects: `fn name<…>(params) -> A ! F + G { body }` — its set (anonymous, named by its effects'
// text), and the tokens the writer changes: after the name (or the generics' `>`) the context's type parameter, at
// `(` the context, `! F + G` dropped, at `{` the check that the context has every operation
// a handler: `handler name for F + G(params) -> R { return(v) { … } op(a, …, k) { … } }` — its clauses: the
// return clause (op -1) and one per operation, each its names (the operation's arguments, then the rest) and body
struct HDecl { name: Span, set: i64, params: Span, ret: Span, first: i64, n: i64, from: i64, to: i64 }
struct Clause { op: i64, first_name: i64, n_names: i64, open: i64, close: i64 }
struct FnDecl { name: Span, name_i: i64, set: i64, gt: i64, lp: i64, rp: i64, no_params: bool, bang_from: i64,
                bang_to: i64, open: i64, close: i64, resumable: bool, kw: i64, ret: Span }

fn is_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

// The whole run over one file: false when it found errors (printed, nothing written). `lines`: for each line of the
// output (from 1), the source's line it came from
fn compile(path: const u8[:], src: u8[:], out_path: const u8[:], lines: i64[>..]&) -> bool {
    var toks: Tok[>..] = [];
    var ops: OpDecl[>..] = [];
    var effs: EffDecl[>..] = [];
    var sets: SetDecl[>..] = [];
    var members: i64[>..] = [];
    var fwds: Fwd[>..] = [];
    var excepts: Span[>..] = [];
    var fns: FnDecl[>..] = [];
    var hdecls: HDecl[>..] = [];
    var clauses: Clause[>..] = [];
    var cnames: Span[>..] = [];
    var errors = 0;

    fn text(s: Span) -> u8[:] { src[s.at..s.at + s.len] }
    fn tok_text(i: i64) -> u8[:] { src[toks[i].at..toks[i].at + toks[i].len] }
    fn span_of(i: i64) -> Span { Span { at: toks[i].at, len: toks[i].len } }
    fn line_of(at: i64) -> i64 {
        var n = 1;
        for i in at { if src[i] == '\n' { n++; } }
        return n;
    }
    fn error_at(at: i64, msg: u8[:]) {
        print(path, ":", line_of(at), ": error: ", msg);
        errors++;
    }

    // LEXING: every byte in some token, so the output can copy the text between the parts it rewrites
    fn lex() {
        var i = 0;
        while i < src.len {
            let start = i;
            let c = src[i];
            if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
                while i < src.len && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r') { i++; }
                toks.push(Tok { kind: K_SPACE, at: start, len: i - start });
            } else if c == '/' && i + 1 < src.len && src[i + 1] == '/' {
                while i < src.len && src[i] != '\n' { i++; }
                toks.push(Tok { kind: K_SPACE, at: start, len: i - start });
            } else if c == '/' && i + 1 < src.len && src[i + 1] == '*' {
                i += 2;
                while i + 1 < src.len && !(src[i] == '*' && src[i + 1] == '/') { i++; }
                i = if i + 2 <= src.len { i + 2 } else { src.len };
                toks.push(Tok { kind: K_SPACE, at: start, len: i - start });
            } else if is_alpha(c) {
                while i < src.len && (is_alpha(src[i]) || is_digit(src[i])) { i++; }
                toks.push(Tok { kind: K_IDENT, at: start, len: i - start });
            } else if is_digit(c) {
                // a dot is the number's only before a digit: `0..n` is a number and a range
                while i < src.len && (is_alpha(src[i]) || is_digit(src[i])
                                      || (src[i] == '.' && i + 1 < src.len && is_digit(src[i + 1]))) { i++; }
                toks.push(Tok { kind: K_NUM, at: start, len: i - start });
            } else if c == '"' || c == '\'' {
                i++;
                while i < src.len && src[i] != c {
                    if src[i] == '\\' { i++; }
                    i++;
                }
                i = if i < src.len { i + 1 } else { src.len };
                toks.push(Tok { kind: K_STR, at: start, len: i - start });
            } else {
                i++;
                toks.push(Tok { kind: K_PUNCT, at: start, len: 1 });
            }
        }
    }

    // the next token not space from i on (toks.len at the end)
    fn next(i: i64) -> i64 {
        var j = i;
        while j < toks.len && toks[j].kind == K_SPACE { j++; }
        return j;
    }
    fn is_punct(i: i64, c: u8) -> bool { i < toks.len && toks[i].kind == K_PUNCT && src[toks[i].at] == c }
    fn is_word(i: i64, w: u8[:]) -> bool { i < toks.len && toks[i].kind == K_IDENT && tok_text(i) == w }
    // the token closing the bracket at i (the same depth), or toks.len
    fn closing(i: i64, open: u8, close: u8) -> i64 {
        var depth = 0;
        var j = i;
        while j < toks.len {
            if is_punct(j, open) { depth++; }
            if is_punct(j, close) {
                depth--;
                if depth == 0 { return j; }
            }
            j++;
        }
        return toks.len;
    }

    fn find_effect(s: Span) -> i64 {
        for e in effs.len { if text(effs[e].name) == text(s) { return e; } }
        return -1;
    }
    fn find_set(s: Span) -> i64 {
        for k in sets.len { if text(sets[k].name) == text(s) { return k; } }
        return -1;
    }
    fn set_has(k: i64, e: i64) -> bool {
        let st = sets[k];
        for m in st.first..st.first + st.n { if members[m] == e { return true; } }
        return false;
    }
    // the operation called `s` of any effect: its index, or -1
    fn find_op(s: Span) -> i64 {
        for o in ops.len { if text(ops[o].name) == text(s) { return o; } }
        return -1;
    }
    fn find_fn(s: Span) -> i64 {
        for f in fns.len { if text(fns[f].name) == text(s) { return f; } }
        return -1;
    }

    // the parameters' names and types, split at the commas outside brackets
    fn each_param<F>(p: Span) {
        var depth = 0;
        var start = p.at;
        for i in p.at..p.at + p.len + 1 {
            let at_end = i == p.at + p.len;
            if !at_end {
                let c = src[i];
                if c == '[' || c == '<' || c == '(' { depth++; }
                if c == ']' || c == '>' || c == ')' { depth--; }
            }
            if at_end || (src[i] == ',' && depth == 0) {
                let part = trim(src[start..i]);
                if part.len > 0 {
                    let colon = find(part, ":");
                    F(trim(part[..colon]), trim(part[colon + 1..]));
                }
                start = i + 1;
            }
        }
    }

    // effect Name { op(params) -> ret; ... }
    fn parse_effect(from: i64) -> i64 {
        let name_i = next(from + 1);
        var open = next(name_i + 1);
        var kind = TAIL;
        if is_punct(open, ':') {
            let k = next(open + 1);
            if is_word(k, "once") { kind = ONCE; }
            else if is_word(k, "many") { kind = MANY; }
            else if !is_word(k, "tail") { error_at(toks[k].at, "an effect's kind is `tail`, `once` or `many`"); }
            open = next(k + 1);
        }
        guard toks[name_i].kind == K_IDENT && is_punct(open, '{') else {
            error_at(toks[from].at, "expected `effect Name { … }`");
            return from + 1;
        }
        let close = closing(open, '{', '}');
        let e = effs.len;
        let first = ops.len;
        var i = next(open + 1);
        while i < close {
            let op_name = i;
            let lp = next(i + 1);
            guard toks[op_name].kind == K_IDENT && is_punct(lp, '(') else {
                error_at(toks[i].at, "expected an operation: `name(params) -> type;`");
                return close + 1;
            }
            let rp = closing(lp, '(', ')');
            var ret = Span { at: 0, len: 0 };
            var semi = next(rp + 1);
            if is_punct(semi, '-') && is_punct(semi + 1, '>') {
                let r0 = next(semi + 2);
                var j = r0;
                while j < close && !is_punct(j, ';') { j++; }
                ret = Span { at: toks[r0].at, len: toks[j - 1].at + toks[j - 1].len - toks[r0].at };
                semi = j;
            }
            guard is_punct(semi, ';') else {
                error_at(toks[i].at, "expected `;` after an operation");
                return close + 1;
            }
            let params = Span { at: toks[lp].at + 1, len: toks[rp].at - toks[lp].at - 1 };
            ops.push(OpDecl { effect: e, name: span_of(op_name), params: params, ret: ret });
            i = next(semi + 1);
        }
        effs.push(EffDecl { name: span_of(name_i), kind: kind, first_op: first, n_ops: ops.len - first, from: from, to: close });
        return close + 1;
    }

    // effects Name = A + B + ...;  (an effect, or a set declared before)
    fn parse_set(from: i64) -> i64 {
        let name_i = next(from + 1);
        let eq = next(name_i + 1);
        guard toks[name_i].kind == K_IDENT && is_punct(eq, '=') else {
            error_at(toks[from].at, "expected `effects Name = A + B;`");
            return from + 1;
        }
        let first = members.len;
        var i = next(eq + 1);
        loop {
            guard i < toks.len && toks[i].kind == K_IDENT else {
                error_at(toks[from].at, "expected an effect or a set");
                return i + 1;
            }
            let e = find_effect(span_of(i));
            let k = find_set(span_of(i));
            if e >= 0 {
                members.push(e);
            } else if k >= 0 {
                let st = sets[k];
                for m in st.first..st.first + st.n { members.push(members[m]); }
            } else {
                error_at(toks[i].at, str("no effect or set `", tok_text(i), "` declared before"));
            }
            let after = next(i + 1);
            if is_punct(after, '+') { i = next(after + 1); continue; }
            guard is_punct(after, ';') else {
                error_at(toks[i].at, "expected `+` or `;`");
                return after;
            }
            sets.push(SetDecl { name: span_of(name_i), first: first, n: members.len - first, from: from, to: after });
            return after + 1;
        }
    }

    // forward Type<G> to field for Set [except a, b];
    fn parse_forward(from: i64) -> i64 {
        let ty0 = next(from + 1);
        var j = ty0;
        while j < toks.len && !is_word(j, "to") { j++; }
        let field_i = next(j + 1);
        let for_i = next(field_i + 1);
        let set_i = next(for_i + 1);
        guard j < toks.len && is_word(for_i, "for") && toks[set_i].kind == K_IDENT else {
            error_at(toks[from].at, "expected `forward Type to field for Set [except op, …];`");
            return from + 1;
        }
        let k = find_set(span_of(set_i));
        guard k >= 0 else {
            error_at(toks[set_i].at, str("no set `", tok_text(set_i), "` declared before"));
            return set_i + 1;
        }
        var last = j - 1;
        while last > ty0 && toks[last].kind == K_SPACE { last--; }
        let ty = Span { at: toks[ty0].at, len: toks[last].at + toks[last].len - toks[ty0].at };
        let first_ex = excepts.len;
        var i = next(set_i + 1);
        if is_word(i, "except") {
            i = next(i + 1);
            loop {
                excepts.push(span_of(i));
                if find_op(span_of(i)) < 0 { error_at(toks[i].at, str("no operation `", tok_text(i), "`")); }
                i = next(i + 1);
                if is_punct(i, ',') { i = next(i + 1); continue; }
                break;
            }
        }
        guard is_punct(i, ';') else {
            error_at(toks[from].at, "expected `;` after a forward");
            return i;
        }
        fwds.push(Fwd { ty: ty, field: span_of(field_i), set: k, first_ex: first_ex, n_ex: excepts.len - first_ex,
                        from: from, to: i });
        return i + 1;
    }

    // fn name<…>(params) -> A ! F + G { body }: a function with effects; any other fn is passed by
    fn parse_fn(from: i64, resumable: bool, kw: i64) -> i64 {
        let name_i = next(from + 1);
        var lp = next(name_i + 1);
        var gt = -1;
        if is_punct(lp, '<') {
            gt = closing(lp, '<', '>');
            lp = next(gt + 1);
        }
        guard is_punct(lp, '(') else { return from + 1; }
        let rp = closing(lp, '(', ')');
        let no_params = next(lp + 1) == rp;
        // the return type, then `!` and the effects, up to the body
        var i = next(rp + 1);
        var ret = Span { at: 0, len: 0 };
        let has_arrow = is_punct(i, '-') && is_punct(i + 1, '>');
        let ret_from = if has_arrow { next(i + 2) } else { -1 };
        var bang = -1;
        var depth = 0;
        while i < toks.len && !(depth == 0 && (is_punct(i, '{') || is_punct(i, ';'))) {
            if is_punct(i, '<') || is_punct(i, '[') || is_punct(i, '(') { depth++; }
            if is_punct(i, '>') && !is_punct(i - 1, '-') { depth--; }
            if is_punct(i, ']') || is_punct(i, ')') { depth--; }
            if depth == 0 && is_punct(i, '!') && bang < 0 { bang = i; }
            i++;
        }
        let open = i;
        guard is_punct(open, '{') else { return open + 1; }
        let close = closing(open, '{', '}');
        if bang < 0 {
            if resumable { error_at(toks[kw].at, "a resumable fn says its effects: `-> A ! F + G`"); }
            return close + 1;
        }
        if ret_from >= 0 {
            var last_ret = bang - 1;
            while last_ret > ret_from && toks[last_ret].kind == K_SPACE { last_ret--; }
            ret = Span { at: toks[ret_from].at, len: toks[last_ret].at + toks[last_ret].len - toks[ret_from].at };
        }
        // F + G: effects and sets, flattened into a set named by their text
        let first = members.len;
        var e = next(bang + 1);
        var last = e;
        loop {
            guard e < open && toks[e].kind == K_IDENT else {
                error_at(toks[bang].at, "expected effects after `!`: `A ! F + G`");
                return close + 1;
            }
            let ef = find_effect(span_of(e));
            let k = find_set(span_of(e));
            if ef >= 0 { members.push(ef); }
            else if k >= 0 {
                let st = sets[k];
                for m in st.first..st.first + st.n { members.push(members[m]); }
            } else {
                error_at(toks[e].at, str("no effect or set `", tok_text(e), "` declared before"));
            }
            last = e;
            let after = next(e + 1);
            if is_punct(after, '+') { e = next(after + 1); continue; }
            break;
        }
        let set = sets.len;
        let name = Span { at: toks[next(bang + 1)].at, len: toks[last].at + toks[last].len - toks[next(bang + 1)].at };
        sets.push(SetDecl { name: name, first: first, n: members.len - first, from: -1, to: -1 });
        fns.push(FnDecl { name: span_of(name_i), name_i: name_i, set: set, gt: gt, lp: lp, rp: rp, no_params: no_params,
                          bang_from: bang, bang_to: last, open: open, close: close, resumable: resumable, kw: kw,
                          ret: ret });
        return close + 1;
    }

    // handler name for F + G(params) -> R { return(v) { … } op(a, …, k) { … } }
    fn parse_handler(from: i64) -> i64 {
        let name_i = next(from + 1);
        let for_i = next(name_i + 1);
        guard toks[name_i].kind == K_IDENT && is_word(for_i, "for") else {
            error_at(toks[from].at, "expected `handler name for Effect { … }`");
            return from + 1;
        }
        // the effects, then the parameters and the result
        let first_m = members.len;
        var e = next(for_i + 1);
        var last = e;
        loop {
            let ef = find_effect(span_of(e));
            let k = find_set(span_of(e));
            if ef >= 0 { members.push(ef); }
            else if k >= 0 { let st = sets[k]; for m in st.first..st.first + st.n { members.push(members[m]); } }
            else { error_at(toks[e].at, str("no effect or set `", tok_text(e), "` declared before")); }
            last = e;
            let after = next(e + 1);
            if is_punct(after, '+') { e = next(after + 1); continue; }
            e = after;
            break;
        }
        let set = sets.len;
        sets.push(SetDecl { name: Span { at: toks[next(for_i + 1)].at, len: toks[last].at + toks[last].len - toks[next(for_i + 1)].at },
                            first: first_m, n: members.len - first_m, from: -1, to: -1 });
        var params = Span { at: 0, len: 0 };
        if is_punct(e, '(') {
            let rp = closing(e, '(', ')');
            params = Span { at: toks[e].at + 1, len: toks[rp].at - toks[e].at - 1 };
            e = next(rp + 1);
        }
        var ret = Span { at: 0, len: 0 };
        if is_punct(e, '-') && is_punct(e + 1, '>') {
            let r0 = next(e + 2);
            var r = r0;
            while r < toks.len && !is_punct(r, '{') { r++; }
            var lr = r - 1;
            while lr > r0 && toks[lr].kind == K_SPACE { lr--; }
            ret = Span { at: toks[r0].at, len: toks[lr].at + toks[lr].len - toks[r0].at };
            e = r;
        }
        guard is_punct(e, '{') else { error_at(toks[from].at, "expected `{` and the handler's clauses"); return e + 1; }
        let close = closing(e, '{', '}');
        let first_c = clauses.len;
        var c = next(e + 1);
        while c < close {
            let lp = next(c + 1);
            guard toks[c].kind == K_IDENT && is_punct(lp, '(') else {
                error_at(toks[c].at, "expected a clause: `return(v) { … }` or `op(args, k) { … }`");
                return close + 1;
            }
            let rp = closing(lp, '(', ')');
            let ob = next(rp + 1);
            guard is_punct(ob, '{') else { error_at(toks[c].at, "expected the clause's body `{ … }`"); return close + 1; }
            let cb = closing(ob, '{', '}');
            var op = -1;
            if !is_word(c, "return") {
                op = find_op(span_of(c));
                if op < 0 || !set_has(set, ops[op].effect) {
                    error_at(toks[c].at, str("`", tok_text(c), "` is no operation of the handler's effects"));
                } else if effs[ops[op].effect].kind == TAIL {
                    error_at(toks[c].at, str("`", tok_text(c), "` is a tail operation: the context answers it, not a handler of the rest"));
                }
            }
            let first_n = cnames.len;
            var t = next(lp + 1);
            while t < rp {
                if toks[t].kind == K_IDENT { cnames.push(span_of(t)); }
                t = next(t + 1);
            }
            clauses.push(Clause { op: op, first_name: first_n, n_names: cnames.len - first_n, open: ob, close: cb });
            c = next(cb + 1);
        }
        hdecls.push(HDecl { name: span_of(name_i), set: set, params: params, ret: ret, first: first_c,
                            n: clauses.len - first_c, from: from, to: close });
        // a clause for every once/many operation, with its arguments and its rest named
        let h = hdecls[hdecls.len - 1];
        let st = sets[set];
        for m in st.first..st.first + st.n {
            let ef = effs[members[m]];
            if ef.kind == TAIL { continue; }
            for o in ef.first_op..ef.first_op + ef.n_ops {
                var found = false;
                for q in h.first..h.first + h.n {
                    if clauses[q].op == o {
                        found = true;
                        var np = 0;
                        each_param(ops[o].params) { pn, ty => np++; };
                        if clauses[q].n_names != np + 1 {
                            error_at(toks[clauses[q].open].at, str("the clause of `", text(ops[o].name), "` names ",
                                np, " argument(s) and the rest `k`"));
                        }
                    }
                }
                if !found { error_at(toks[from].at, str("handler `", tok_text(name_i), "` has no clause for `", text(ops[o].name), "`")); }
                // ONCE: the rest resumed at most once — one `resume`, not in a loop, `k` used by it alone
                if ef.kind == ONCE {
                    for q in h.first..h.first + h.n {
                        let c = clauses[q];
                        if c.op != o || c.n_names == 0 { continue; }
                        let kname = text(cnames[c.first_name + c.n_names - 1]);
                        var resumes = 0;
                        var k_uses = 0;
                        var depth = 0;
                        var loop_depths: i64[..16] = [];
                        var pending = false;
                        for t in c.open..c.close + 1 {
                            if is_word(t, "for") || is_word(t, "while") || is_word(t, "loop") { pending = true; }
                            if is_punct(t, '{') {
                                depth++;
                                if pending && loop_depths.len < 16 { loop_depths.push(depth); pending = false; }
                            }
                            if is_punct(t, '}') {
                                if loop_depths.len > 0 && loop_depths[loop_depths.len - 1] == depth { loop_depths.resize(loop_depths.len - 1); }
                                depth--;
                            }
                            if toks[t].kind == K_IDENT && tok_text(t) == kname { k_uses++; }
                            if is_word(t, "resume") && is_punct(next(t + 1), '(') {
                                resumes++;
                                if loop_depths.len > 0 {
                                    error_at(toks[t].at, str("`", text(ops[o].name), "` is of a once effect (",
                                        text(ef.name), "): its rest is not resumed in a loop"));
                                }
                            }
                        }
                        if resumes > 1 {
                            error_at(toks[c.open].at, str("`", text(ops[o].name), "` is of a once effect (", text(ef.name),
                                "): its rest is resumed at most once, here ", resumes, " times"));
                        }
                        if k_uses > resumes {
                            error_at(toks[c.open].at, str("`", text(ops[o].name), "` is of a once effect (", text(ef.name),
                                "): its rest `", kname, "` is used only by its `resume`"));
                        }
                    }
                }
            }
        }
        return close + 1;
    }

    // the top level: the four forms found, everything else passed by
    fn parse() {
        var i = next(0);
        while i < toks.len {
            if is_word(i, "effect") { i = next(parse_effect(i)); }
            else if is_word(i, "effects") { i = next(parse_set(i)); }
            else if is_word(i, "forward") { i = next(parse_forward(i)); }
            else if is_word(i, "handler") { i = next(parse_handler(i)); }
            else if is_word(i, "resumable") && is_word(next(i + 1), "fn") { i = next(parse_fn(next(i + 1), true, i)); }
            else if is_word(i, "fn") || is_word(i, "recursive") {
                let f = if is_word(i, "recursive") { next(i + 1) } else { i };
                i = next(parse_fn(f, false, -1));
            }
            else { i = next(i + 1); }
        }
    }

    // CHECKING: each function with effects calls only the operations of its effects, and functions with effects
    // whose effects are within its own. Each such call is where the writer passes the context (`(` → `(cx, `)
    var passes: i64[>..] = [];
    fn check() {
        for f in fns.len {
            let d = fns[f];
            let set_name = text(sets[d.set].name);
            for i in d.open..d.close {
                guard toks[i].kind == K_IDENT && is_punct(next(i + 1), '(') else { continue; }
                // not a method call on something else, not a function declared here
                var before = i - 1;
                while before > 0 && toks[before].kind == K_SPACE { before--; }
                if is_punct(before, '.') || is_word(before, "fn") { continue; }
                let o = find_op(span_of(i));
                let g = find_fn(span_of(i));
                if o >= 0 {
                    if !set_has(d.set, ops[o].effect) {
                        error_at(toks[i].at, str("`", text(d.name), "` (! ", set_name, ") calls `", tok_text(i),
                            "` of ", text(effs[ops[o].effect].name), ", which ", set_name, " does not have"));
                    }
                    if effs[ops[o].effect].kind == TAIL { passes.push(next(i + 1)); }
                    else if !d.resumable {
                        error_at(toks[i].at, str("`", tok_text(i), "` keeps the rest of the program (",
                            text(effs[ops[o].effect].name), " is not tail): it is called in a resumable fn"));
                    }
                } else if g >= 0 {
                    let gs = sets[fns[g].set];
                    for m in gs.first..gs.first + gs.n {
                        if !set_has(d.set, members[m]) {
                            error_at(toks[i].at, str("`", text(d.name), "` (! ", set_name, ") calls `", tok_text(i),
                                "` (! ", text(gs.name), "), which needs ", text(effs[members[m]].name)));
                        }
                    }
                    passes.push(next(i + 1));
                }
            }
        }
    }

    // WRITING
    var out: u8[>..] = [];


    // every operation of the set the context answers (the tail ones: the others are the program's stops, answered
    // by what runs the machine) called on cx, never run: a context lacking one is an error here
    fn write_check(k: i64, sep: u8[:]) {
        let st = sets[k];
        format(out, "if false {");
        for m in st.first..st.first + st.n {
            let e = effs[members[m]];
            if e.kind != TAIL { continue; }
            for o in e.first_op..e.first_op + e.n_ops {
                format(out, sep, text(ops[o].name), "(cx");
                each_param(ops[o].params) { name, ty => format(out, ", default<", ty, ">()"); };
                format(out, ");");
            }
        }
        format(out, " }");
    }

    fn write_requires(k: i64) {
        format(out, "fn requires_", text(sets[k].name), "<C>(cx: C&) { ");
        write_check(k, " ");
        format(out, " }");
    }

    fn excepted(w: Fwd, o: i64) -> bool {
        for x in w.first_ex..w.first_ex + w.n_ex { if text(excepts[x]) == text(ops[o].name) { return true; } }
        return false;
    }

    fn write_forward(w: Fwd) {
        let ty = text(w.ty);
        let lt = find(ty, "<");
        let generics = if lt >= 0 { ty[lt..] } else { "" };
        let st = sets[w.set];
        var first = true;
        for m in st.first..st.first + st.n {
            let e = effs[members[m]];
            for o in e.first_op..e.first_op + e.n_ops {
                if excepted(w, o) { continue; }
                let op = ops[o];
                if !first { format(out, " "); }   // one line: the output's lines are the source's
                first = false;
                format(out, "fn ", text(op.name), generics, "(cx: ", ty, "&");
                if op.params.len > 0 { format(out, ", ", text(op.params)); }
                format(out, ")");
                if op.ret.len > 0 { format(out, " -> ", text(op.ret)); }
                format(out, " { ");
                if op.ret.len > 0 { format(out, "return "); }
                format(out, text(op.name), "(cx.", text(w.field));
                each_param(op.params) { name, ty2 => format(out, ", ", name); };
                format(out, "); }");
            }
        }
    }

    // RESUMABLE FNS: a state machine. Its frame is one struct — where it stopped (`at`) and every variable of the
    // function —; its body `loop { match at { … } }`, cut into blocks only where a statement holds a stop: a stop
    // ends a block (its step returned, the rest a frame), an `if`, `while`, `for` or `loop` holding one becomes
    // jumps between blocks; a statement holding none is copied as it is. Its steps a value: `Done`, or an operation
    // with its arguments and its rest `k` — flat: copied to resume again, written out as bytes. The first step
    // `name(cx, …)`, the others `resume(cx, k, v)`, by the operation's rest type, `v` of its type: no cast
    var mout: u8[>..] = [];
    var seg_start: i64[>..] = [];        // where each written-out part begins in mout, and its source line
    var seg_line: i64[>..] = [];

    fn is_control(i: i64, set: i64) -> i64 {
        if toks[i].kind != K_IDENT || !is_punct(next(i + 1), '(') { return -1; }
        let o = find_op(span_of(i));
        if o < 0 || effs[ops[o].effect].kind == TAIL || !set_has(set, ops[o].effect) { return -1; }
        return o;
    }

    fn write_resumable(d: FnDecl) {
        var vars: MVar[>..] = [];
        var stop_at: i64[>..] = [];          // each stop: its block's label, its operation, the variable bound
        var stop_op: i64[>..] = [];
        var stop_bind: i64[>..] = [];
        var loops: i64[>..<] = [];           // the lowered loops around: their break and continue labels, in pairs
        var body: u8[>..] = [];
        var syn: u8[>..] = [];               // made-up variables' names and types: a Span at -(offset + 1) is here
        var rep_from: i64[>..] = [];         // a stop inside an expression: the call's tokens, the variable now there
        var rep_to: i64[>..] = [];
        var rep_var: i64[>..] = [];
        var labels = 1;
        var fresh_vars = 0;
        // which variables the frame keeps: each variable's first block (-1: none yet), whether it is used in
        // another too; each block's being inside a lowered loop (entered again after a stop)
        var cur_block = 0;
        var vblock: i64[>..] = [];
        var vmulti: i64[>..] = [];
        var loopy: i64[>..] = [];
        let n = text(d.name);
        var pname: u8[>..] = [];
        if n[0] >= 'a' && n[0] <= 'z' { pname.push(n[0] - 32); } else { pname.push(n[0]); }
        pname.append(n[1..]);
        let has_ret = d.ret.len > 0 && text(d.ret) != "()";

        fn var_index(s: u8[:]) -> i64 {
            for v in vars.len {
                let sp = vars[v].name;
                let t = if sp.at < 0 { syn[-sp.at - 1..-sp.at - 1 + sp.len] } else { text(sp) };
                if t == s { return v; }
            }
            return -1;
        }
        fn add_var(name: Span, ty: Span) -> i64 {
            if var_index(text(name)) >= 0 {
                error_at(name.at, str("`", text(name), "` declared twice in a resumable fn: its variables are the ",
                    "frame's fields, one name each"));
                return var_index(text(name));
            }
            vars.push(MVar { name: name, ty: ty });
            vblock.push(-1);
            vmulti.push(0);
            return vars.len - 1;
        }
        // a call of a resumable fn: its index, or -1
        fn is_sub(i: i64) -> i64 {
            if toks[i].kind != K_IDENT || !is_punct(next(i + 1), '(') { return -1; }
            var before = i - 1;
            while before > 0 && toks[before].kind == K_SPACE { before--; }
            if is_punct(before, '.') || is_word(before, "fn") { return -1; }
            let g = find_fn(span_of(i));
            if g < 0 || !fns[g].resumable { return -1; }
            return g;
        }
        fn has_stop(from: i64, to: i64) -> bool {
            for t in from..to + 1 { if t < d.close && (is_control(t, d.set) >= 0 || is_sub(t) >= 0) { return true; } }
            return false;
        }
        fn synth(name: u8[:], ty: u8[:]) -> i64 {
            let na = syn.len;
            syn.append(name);
            let ta = syn.len;
            syn.append(ty);
            vars.push(MVar { name: Span { at: -(na + 1), len: name.len }, ty: Span { at: -(ta + 1), len: ty.len } });
            vblock.push(-1);
            vmulti.push(0);
            return vars.len - 1;
        }
        // a variable's name and type as written, or made up
        fn vtext(sp: Span) -> u8[:] { if sp.at < 0 { syn[-sp.at - 1..-sp.at - 1 + sp.len] } else { text(sp) } }
        fn vname(v: i64, buf: u8[>..]&) { buf.append(vtext(vars[v].name)); }
        fn vtype(v: i64, buf: u8[>..]&) { buf.append(vtext(vars[v].ty)); }
        fn use_var(v: i64) {
            if v < 0 { return; }
            if vblock[v] < 0 { vblock[v] = cur_block; } else if vblock[v] != cur_block { vmulti[v] = 1; }
        }
        fn mark(name: u8[:]) { use_var(var_index(name)); }
        // the last token of the statement starting at j: its `;`, or the `}` ending it (an if's last branch)
        fn stmt_end(j: i64, limit: i64) -> i64 {
            var e = j;
            var depth = 0;
            loop {
                if e >= limit { return limit; }
                if is_punct(e, '{') || is_punct(e, '(') || is_punct(e, '[') { depth++; }
                if is_punct(e, '}') || is_punct(e, ')') || is_punct(e, ']') {
                    depth--;
                    if depth == 0 && is_punct(e, '}') && !is_word(next(e + 1), "else") { return e; }
                }
                if depth == 0 && is_punct(e, ';') { return e; }
                e++;
            }
        }
        // the first `{` at depth 0 from i: where a condition ends
        fn open_brace(i: i64) -> i64 {
            var t = i;
            var depth = 0;
            while t < d.close {
                if depth == 0 && is_punct(t, '{') { return t; }
                if is_punct(t, '(') || is_punct(t, '[') { depth++; }
                if is_punct(t, ')') || is_punct(t, ']') { depth--; }
                t++;
            }
            return d.close;
        }
        fn new_label() -> i64 { labels += 1; return labels - 1; }
        fn frame_mark(l: i64) { body.push(1); format(body, l); body.push(2); }

        // tokens copied into the body: the context passed, `return x;` the program's Done; with `lowered`, a
        // `break` or `continue` of the lowered loop around (not of a loop inside the copied text) a jump
        fn copy_tokens(from: i64, to: i64, lowered: bool) {
            var close_at = -1;
            var depth = 0;
            var pending = false;
            var user_loops: i64[..16] = [];     // the brace depths of the loops inside the copied text
            var t = from;
            while t <= to && t < toks.len {
                var replaced = -1;
                for q in rep_from.len { if rep_from[q] == t { replaced = q; } }
                if replaced >= 0 {
                    vname(rep_var[replaced], body);
                    use_var(rep_var[replaced]);
                    t = rep_to[replaced] + 1;
                    continue;
                }
                var passed = false;
                for q in passes { if q == t { passed = true; } }
                if passed {
                    format(body, "(cx");
                    if !is_punct(next(t + 1), ')') { format(body, ", "); }
                    t++;
                    continue;
                }
                if t == close_at { format(body, ") }"); close_at = -1; }
                if is_word(t, "while") || is_word(t, "for") || is_word(t, "loop") { pending = true; }
                if is_punct(t, '{') {
                    depth++;
                    if pending && user_loops.len < 16 { user_loops.push(depth); pending = false; }
                }
                if is_punct(t, '}') {
                    if user_loops.len > 0 && user_loops[user_loops.len - 1] == depth { user_loops.resize(user_loops.len - 1); }
                    depth--;
                }
                if lowered && user_loops.len == 0 && loops.len >= 2 && (is_word(t, "break") || is_word(t, "continue")) {
                    let target = if is_word(t, "break") { loops[loops.len - 2] } else { loops[loops.len - 1] };
                    format(body, "{ at = ", target, "; continue; }");
                    t = next(t + 1);       // the `;`
                    t++;
                    continue;
                }
                if is_word(t, "return") {
                    let v = next(t + 1);
                    if is_punct(v, ';') { format(body, "return ", pname, ".Done {}"); t = v; continue; }
                    format(body, "return ", pname, ".Done { v: (");
                    var c = v;
                    var dp = 0;
                    while c < to && !(dp == 0 && is_punct(c, ';')) {
                        if is_punct(c, '(') || is_punct(c, '[') || is_punct(c, '{') { dp++; }
                        if is_punct(c, ')') || is_punct(c, ']') || is_punct(c, '}') { dp--; }
                        c++;
                    }
                    close_at = c;
                    t = v;
                    continue;
                }
                if toks[t].kind == K_IDENT { mark(tok_text(t)); }
                body.append(tok_text(t));
                t++;
            }
            if close_at >= 0 { format(body, ") }"); }
        }

        fn cap_to(buf: u8[>..]&, s: u8[:]) {
            if s[0] >= 'a' && s[0] <= 'z' { buf.push(s[0] - 32); } else { buf.push(s[0]); }
            buf.append(s[1..]);
        }

        // a stop: the step returned — the operation's arguments by its parameters' names, the rest a frame at a
        // new label — and that label's block opened, where resume comes back
        fn write_stop(o: i64, bind: i64, lp: i64, rp: i64) {
            let l = new_label();
            stop_at.push(l);
            stop_op.push(o);
            stop_bind.push(bind);
            let op = ops[o];
            format(body, " return ", pname, ".");
            cap_to(body, text(op.name));
            format(body, " { ");
            var a = next(lp + 1);
            each_param(op.params) { pn, ty =>
                var e = a;
                var dp = 0;
                while e < rp && !(dp == 0 && is_punct(e, ',')) {
                    if is_punct(e, '(') || is_punct(e, '[') { dp++; }
                    if is_punct(e, ')') || is_punct(e, ']') { dp--; }
                    e++;
                }
                format(body, pn, ": (");
                copy_tokens(a, e - 1, false);
                format(body, "), ");
                a = if e < rp { next(e + 1) } else { rp };
            };
            format(body, "k: ", pname, "_", text(op.name), " { k: ");
            frame_mark(l);
            format(body, " } }; },\n            ", l, " => {");
        }
        fn jump(l: i64) { format(body, " at = ", l, "; continue; },\n            "); }
        fn open(l: i64) {
            format(body, l, " => {");
            cur_block = l;
            while loopy.len <= l { loopy.push(0); }
            loopy[l] = if loops.len > 0 { 1 } else { 0 };
        }

        // a resumable fn called: run, its step looked at — its value bound and on, or its operation passed out as this
        // one's step, the callee's rest kept in this frame; resumed, the value given to the callee, looked at again
        fn write_sub(g: i64, bind: i64, lp: i64, rp: i64) {
            let c = fns[g];
            let cname = text(c.name);
            var cp: u8[>..] = [];
            cap_to(cp, cname);
            let nsub = fresh_vars;
            fresh_vars++;
            var sname: u8[..32] = [];
            format(sname, "okay_s", nsub);
            synth(sname, cp);
            let li = new_label();
            let ln = new_label();
            format(body, " ", sname, " = ", cname, "(cx");
            mark(sname);
            if next(lp + 1) != rp { format(body, ", "); copy_tokens(next(lp + 1), rp - 1, false); }
            format(body, ");");
            jump(li);
            open(li);
            format(body, " match ", sname, " { Done okay_d => {");
            mark(sname);
            if bind >= 0 { format(body, " "); vname(bind, body); use_var(bind); format(body, " = okay_d.v;"); }
            format(body, " at = ", ln, "; continue; },");
            for o in ops.len {
                if effs[ops[o].effect].kind == TAIL || !set_has(c.set, ops[o].effect) { continue; }
                let op = ops[o];
                var kname: u8[..48] = [];
                format(kname, "okay_k", nsub, "_", text(op.name));
                var kty: u8[>..] = [];
                format(kty, cp, "_", text(op.name));
                synth(kname, kty);
                var vv = -1;
                if op.ret.len > 0 {
                    var vname2: u8[..48] = [];
                    format(vname2, "okay_v", nsub, "_", text(op.name));
                    vv = synth(vname2, text(op.ret));
                }
                let lr = new_label();
                stop_at.push(lr);
                stop_op.push(o);
                stop_bind.push(vv);
                format(body, " ");
                cap_to(body, text(op.name));
                format(body, " okay_o => { ", kname, " = okay_o.k; return ", pname, ".");
                mark(kname);
                cap_to(body, text(op.name));
                format(body, " { ");
                each_param(op.params) { pn, ty => format(body, pn, ": okay_o.", pn, ", "); };
                format(body, "k: ", pname, "_", text(op.name), " { k: ");
                frame_mark(lr);
                format(body, " } }; },");
            }
            format(body, " }; },\n            ");
            // the resumptions: the value given to the callee's rest, its step looked at again
            for o in ops.len {
                if effs[ops[o].effect].kind == TAIL || !set_has(c.set, ops[o].effect) { continue; }
                let op = ops[o];
                var lr = -1;
                var vv = -1;
                for q in stop_at.len { if stop_op[q] == o && lr < 0 && stop_at[q] > li { lr = stop_at[q]; vv = stop_bind[q]; } }
                open(lr);
                format(body, " ", sname, " = resume(cx, okay_k", nsub, "_", text(op.name));
                mark(sname);
                var kn: u8[..48] = [];
                format(kn, "okay_k", nsub, "_", text(op.name));
                mark(kn);
                if vv >= 0 { format(body, ", "); vname(vv, body); use_var(vv); }
                format(body, ");");
                jump(li);
            }
            open(ln);
        }

        // the stops inside an expression (from..to), innermost first, each before the statement, its value a made-up
        // variable put in the call's place. Not inside a block of the expression: there it may not run at all
        recursive fn extract(from: i64, to: i64) {
            var t = from;
            var brace = 0;
            while t <= to && t < d.close {
                if is_punct(t, '{') { brace++; }
                if is_punct(t, '}') { brace--; }
                let o = is_control(t, d.set);
                let g = is_sub(t);
                if (o >= 0 || g >= 0) && brace > 0 {
                    error_at(toks[t].at, str("`", tok_text(t), "` inside a block of an expression: a resumable fn stops ",
                        "there only as a statement of it"));
                    t++;
                    continue;
                }
                if o >= 0 || g >= 0 {
                    let lp = next(t + 1);
                    let rp = closing(lp, '(', ')');
                    extract(next(lp + 1), rp - 1);
                    let ty = if o >= 0 { ops[o].ret } else { fns[g].ret };
                    if ty.len == 0 {
                        error_at(toks[t].at, str("`", tok_text(t), "` has no value to use in an expression"));
                        t = rp + 1;
                        continue;
                    }
                    var tname: u8[..32] = [];
                    format(tname, "okay_t", fresh_vars);
                    fresh_vars++;
                    let v = synth(tname, text(ty));
                    if o >= 0 { write_stop(o, v, lp, rp); } else { write_sub(g, v, lp, rp); }
                    rep_from.push(t);
                    rep_to.push(rp);
                    rep_var.push(v);
                    t = rp + 1;
                    continue;
                }
                t++;
            }
        }

        // a let at a lowered level: the variable a frame field, the statement an assignment
        fn lower_let(j: i64, e: i64) {
            let name_i = next(j + 1);
            var after = next(name_i + 1);
            var ty = Span { at: 0, len: 0 };
            if is_punct(after, ':') {
                let t0 = next(after + 1);
                var t = t0;
                while t < e && !is_punct(t, '=') { t++; }
                var last = t - 1;
                while last > t0 && toks[last].kind == K_SPACE { last--; }
                ty = Span { at: toks[t0].at, len: toks[last].at + toks[last].len - toks[t0].at };
                after = t;
            }
            let rhs = next(after + 1);
            let o = if is_punct(after, '=') { is_control(rhs, d.set) } else { -1 };
            if o >= 0 && next(closing(next(rhs + 1), '(', ')') + 1) == e {
                let v = add_var(span_of(name_i), if ty.len > 0 { ty } else { ops[o].ret });
                let lp = next(rhs + 1);
                write_stop(o, v, lp, closing(lp, '(', ')'));
                return;
            }
            let g = if is_punct(after, '=') { is_sub(rhs) } else { -1 };
            if g >= 0 && next(closing(next(rhs + 1), '(', ')') + 1) == e {
                let v = add_var(span_of(name_i), if ty.len > 0 { ty } else { fns[g].ret });
                let lp = next(rhs + 1);
                write_sub(g, v, lp, closing(lp, '(', ')'));
                return;
            }
            if has_stop(j, e) { extract(rhs, e - 1); }
            if ty.len == 0 {
                error_at(toks[name_i].at, str("`", tok_text(name_i), "` in a resumable fn: its variables are the frame's ",
                    "fields — give it a type (`let ", tok_text(name_i), ": T = …`)"));
                return;
            }
            add_var(span_of(name_i), ty);
            if is_punct(after, '=') {
                format(body, " ", tok_text(name_i), " = ");
                mark(tok_text(name_i));
                copy_tokens(rhs, e, true);
            }
        }

        // the statement's source line: a line of its own in the output, mapped back to it
        fn line_mark(j: i64) { body.push(3); format(body, line_of(toks[j].at)); body.push(4); }

        recursive fn lower(from: i64, to: i64) {
            var j = next(from);
            while j <= to && j < d.close {
                let e = stmt_end(j, to + 1);
                line_mark(j);
                if is_word(j, "let") || is_word(j, "var") {
                    lower_let(j, e);
                } else if !has_stop(j, e) {
                    format(body, " ");
                    copy_tokens(j, e, true);
                } else if is_sub(j) >= 0 && next(closing(next(j + 1), '(', ')') + 1) == e {
                    let lp = next(j + 1);
                    write_sub(is_sub(j), -1, lp, closing(lp, '(', ')'));
                } else if is_control(j, d.set) >= 0 && next(closing(next(j + 1), '(', ')') + 1) == e {
                    let lp = next(j + 1);
                    write_stop(is_control(j, d.set), -1, lp, closing(lp, '(', ')'));
                } else if is_word(j, "if") {
                    let ob = open_brace(next(j + 1));
                    let cb = closing(ob, '{', '}');
                    let la = new_label();
                    let lj = new_label();
                    let el = next(cb + 1);
                    let has_else = el <= e && is_word(el, "else");
                    let lb = if has_else { new_label() } else { lj };
                    extract(next(j + 1), ob - 1);
                    format(body, " if (");
                    copy_tokens(next(j + 1), ob - 1, false);
                    format(body, ") { at = ", la, "; } else { at = ", lb, "; } continue; },\n            ");
                    open(la);
                    lower(next(ob + 1), cb - 1);
                    jump(lj);
                    if has_else {
                        open(lb);
                        let be = next(el + 1);
                        if is_word(be, "if") { lower(be, e); }
                        else { lower(next(be + 1), closing(be, '{', '}') - 1); }
                        jump(lj);
                    }
                    open(lj);
                } else if is_word(j, "while") || is_word(j, "loop") {
                    let ob = open_brace(next(j + 1));
                    let cb = closing(ob, '{', '}');
                    let lh = new_label();
                    let lb = new_label();
                    let lx = new_label();
                    jump(lh);
                    open(lh);
                    if is_word(j, "while") {
                        extract(next(j + 1), ob - 1);
                        format(body, " if (");
                        copy_tokens(next(j + 1), ob - 1, false);
                        format(body, ") { at = ", lb, "; } else { at = ", lx, "; } continue; },\n            ");
                    } else {
                        jump(lb);
                    }
                    open(lb);
                    loops.push(lx);
                    loops.push(lh);
                    lower(next(ob + 1), cb - 1);
                    loops.resize(loops.len - 2);
                    jump(lh);
                    open(lx);
                } else if is_word(j, "for") {
                    // for i in a..b { … } or for i in n { … }: i a frame field, the end too
                    let name_i = next(j + 1);
                    let in_i = next(name_i + 1);
                    let ob = open_brace(in_i);
                    let cb = closing(ob, '{', '}');
                    guard is_word(in_i, "in") else { error_at(toks[j].at, "expected `for i in a..b`"); return; }
                    var dots = -1;
                    for t in next(in_i + 1)..ob { if dots < 0 && is_punct(t, '.') && is_punct(t + 1, '.') { dots = t; } }
                    if var_index(tok_text(name_i)) >= 0 { error_at(toks[name_i].at, str("`", tok_text(name_i), "` declared twice in a resumable fn")); }
                    synth(tok_text(name_i), "i64");
                    var endname: u8[..32] = [];
                    format(endname, "okay_end", fresh_vars);
                    fresh_vars++;
                    synth(endname, "i64");
                    extract(next(in_i + 1), ob - 1);
                    format(body, " ", tok_text(name_i), " = ");
                    mark(tok_text(name_i));
                    mark(endname);
                    if dots >= 0 { format(body, "("); copy_tokens(next(in_i + 1), dots - 1, false); format(body, ")"); }
                    else { format(body, "0"); }
                    format(body, "; ", endname, " = (");
                    if dots >= 0 { copy_tokens(next(dots + 2), ob - 1, false); } else { copy_tokens(next(in_i + 1), ob - 1, false); }
                    format(body, ");");
                    let lh = new_label();
                    let lb = new_label();
                    let lc = new_label();
                    let lx = new_label();
                    jump(lh);
                    open(lh);
                    mark(tok_text(name_i));
                    mark(endname);
                    format(body, " if ", tok_text(name_i), " < ", endname, " { at = ", lb, "; } else { at = ", lx,
                        "; } continue; },\n            ");
                    open(lb);
                    loops.push(lx);
                    loops.push(lc);
                    lower(next(ob + 1), cb - 1);
                    loops.resize(loops.len - 2);
                    jump(lc);
                    open(lc);
                    format(body, " ", tok_text(name_i), " += 1;");
                    mark(tok_text(name_i));
                    jump(lh);
                    open(lx);
                } else if is_punct(j, '{') {
                    lower(next(j + 1), closing(j, '{', '}') - 1);
                } else if is_word(j, "match") {
                    // the scrutinee's stops before it; a stop in an arm: not yet
                    let ob = open_brace(next(j + 1));
                    extract(next(j + 1), ob - 1);
                    if has_stop(ob, e) {
                        error_at(toks[j].at, "a stop inside a `match` arm: a resumable fn stops in its body, in if, while, for and loop");
                    }
                    format(body, " ");
                    copy_tokens(j, e, true);
                } else {
                    // an expression statement, a return: its stops before it
                    extract(j, e);
                    format(body, " ");
                    copy_tokens(j, e, true);
                }
                j = next(e + 1);
            }
        }

        // the parameters: the first fields
        var i = next(d.lp + 1);
        while i < d.rp {
            let name_i = i;
            let colon = next(i + 1);
            guard toks[name_i].kind == K_IDENT && is_punct(colon, ':') else { error_at(toks[i].at, "a parameter `name: T`"); return; }
            let t0 = next(colon + 1);
            var e = t0;
            var depth = 0;
            while e < d.rp && !(depth == 0 && is_punct(e, ',')) {
                if is_punct(e, '[') || is_punct(e, '<') || is_punct(e, '(') { depth++; }
                if is_punct(e, ']') || is_punct(e, '>') || is_punct(e, ')') { depth--; }
                e++;
            }
            var last = e - 1;
            while last > t0 && toks[last].kind == K_SPACE { last--; }
            add_var(span_of(name_i), Span { at: toks[t0].at, len: toks[last].at + toks[last].len - toks[t0].at });
            i = if e < d.rp { next(e + 1) } else { d.rp };
        }
        let n_params = vars.len;

        // the body, from block 0
        format(body, "0 => {");
        lower(next(d.open + 1), d.close - 1);
        if has_ret { format(body, " abort(\"okay: resumable fn ", n, " ended without a value\"); },\n"); }
        else { format(body, " return ", pname, ".Done {}; },\n"); }

        // a variable's name and type as written (the loops' made-up ones, i64)
        // kept by the frame: a parameter, a variable a stop binds, one used in two blocks or in a block entered again
        // after a stop (a lowered loop's); the others are the machine's locals, not copied at each stop
        fn kept(v: i64) -> bool {
            if v < n_params || vmulti[v] == 1 { return true; }
            for q in stop_bind { if q == v { return true; } }
            let b = vblock[v];
            return b >= 0 && b < loopy.len && loopy[b] == 1;
        }
        fn frame(l: i64) {
            format(mout, pname, "_k { at: ", l);
            for v in vars.len { if kept(v) { format(mout, ", "); vname(v, mout); format(mout, ": "); vname(v, mout); } }
            format(mout, " }");
        }
        // every once/many operation of its effects is a step's variant: a resumable fn calling this one finds its own
        fn used(o: i64) -> bool { effs[ops[o].effect].kind != TAIL && set_has(d.set, ops[o].effect) }

        seg_start.push(mout.len);
        seg_line.push(line_of(toks[d.kw].at));
        format(mout, "\n// resumable fn ", n, " (", path, ":", line_of(toks[d.kw].at), "): its frame, its steps, its blocks\n");
        format(mout, "struct ", pname, "_k { at: i64");
        for v in vars.len { if kept(v) { format(mout, ", "); vname(v, mout); format(mout, ": "); vtype(v, mout); } }
        format(mout, " }\n");
        for o in ops.len { if used(o) { format(mout, "struct ", pname, "_", text(ops[o].name), " { k: ", pname, "_k }\n"); } }
        format(mout, "enum ", pname, " { Done { ");
        if has_ret { format(mout, "v: ", text(d.ret), " "); }
        format(mout, "}");
        for o in ops.len {
            if !used(o) { continue; }
            format(mout, ", ");
            cap_to(mout, text(ops[o].name));
            format(mout, " { ");
            each_param(ops[o].params) { pn, ty => format(mout, pn, ": ", ty, ", "); };
            format(mout, "k: ", pname, "_", text(ops[o].name), " }");
        }
        format(mout, " }\n");
        // the machine: the frame's fields locals, the blocks
        format(mout, "fn run_", n, "<OkayCx>(cx: OkayCx&, k: ", pname, "_k) -> ", pname, " {\n    ");
        let saved = out.len;
        write_check(d.set, " ");
        mout.append(out[saved..]);
        out.resize(saved);
        format(mout, "\n    var at = k.at;");
        for v in vars.len {
            format(mout, " var ");
            vname(v, mout);
            if kept(v) { format(mout, " = k."); vname(v, mout); }
            else { format(mout, ": "); vtype(v, mout); format(mout, " = default<"); vtype(v, mout); format(mout, ">()"); }
            format(mout, ";");
        }
        format(mout, "\n    loop {\n        match at {\n            ");
        var b = 0;
        while b < body.len {
            if body[b] == 1 {
                var l = 0;
                b++;
                while body[b] != 2 { l = l * 10 + (body[b] - '0'); b++; }
                frame(l);
            } else if body[b] == 3 {
                var l = 0;
                b++;
                while body[b] != 4 { l = l * 10 + (body[b] - '0'); b++; }
                seg_start.push(mout.len);          // the newline's own position: the line after it is l
                seg_line.push(l);
                mout.append("\n                ");
            } else {
                mout.push(body[b]);
            }
            b++;
        }
        // after the blocks, the declaration's line again
        seg_start.push(mout.len);
        seg_line.push(line_of(toks[d.kw].at));
        format(mout, "\n            _ => { abort(\"okay: resumable fn ", n, ": no such block\"); },\n        }\n    }\n}\n");
        // the first step
        format(mout, "fn ", n, "<OkayCx>(cx: OkayCx&");
        if !d.no_params { format(mout, ", ", src[toks[d.lp].at + 1..toks[d.rp].at]); }
        format(mout, ") -> ", pname, " { return run_", n, "(cx, ", pname, "_k { at: 0");
        for v in vars.len {
            if !kept(v) { continue; }
            format(mout, ", ");
            vname(v, mout);
            format(mout, ": ");
            if v < n_params { vname(v, mout); } else { format(mout, "default<"); vtype(v, mout); format(mout, ">()"); }
        }
        format(mout, " }); }\n");
        // the others: the operation's value into the variable its stop binds, the machine run on
        for o in ops.len {
            if !used(o) { continue; }
            let op = ops[o];
            format(mout, "fn resume<OkayCx>(cx: OkayCx&, k: ", pname, "_", text(op.name));
            if op.ret.len > 0 { format(mout, ", v: ", text(op.ret)); }
            format(mout, ") -> ", pname, " { var f = k.k;");
            if op.ret.len > 0 {
                format(mout, " match f.at {");
                for q in stop_at.len {
                    if stop_op[q] == o && stop_bind[q] >= 0 {
                        format(mout, " ", stop_at[q], " => { f.");
                        vname(stop_bind[q], mout);
                        format(mout, " = v; },");
                    }
                }
                format(mout, " _ => {}, }");
            }
            format(mout, " return run_", n, "(cx, f); }\n");
        }
    }

    fn copy_plain(from: i64, to: i64) { for t in from..to + 1 { mout.append(tok_text(t)); } }

    // A HANDLER: one function for the steps of any resumable fn with its effects — a loop over the steps, a clause
    // for each: `resume(k, x)` last in a clause the loop going on with the rest's next step (no stack), anywhere
    // else this handler run on the rest — a deep handler — its value the handler's for that rest
    fn write_handler(h: HDecl) {
        let hn = text(h.name);
        let has_ret = h.ret.len > 0;
        var pnames: u8[>..] = [];
        each_param(h.params) { pn, ty => format(pnames, ", ", pn); };
        // a clause's body: `resume(k, …)` rewritten; `tail_from`: the tail resume's token (-1: none)
        fn copy_body(from: i64, to: i64, kname: u8[:], tail_at: i64) {
            var t = from;
            while t <= to {
                if is_word(t, "resume") && is_punct(next(t + 1), '(') {
                    let lp = next(t + 1);
                    let rp = closing(lp, '(', ')');
                    let a = next(lp + 1);
                    if t == tail_at { format(mout, "step = resume(cx, "); }
                    else { format(mout, hn, "(cx, resume(cx, "); }
                    copy_plain(a, rp - 1);
                    if t == tail_at { format(mout, "); continue;"); }
                    else { format(mout, ")", pnames, ")"); }
                    t = rp + 1;
                    // a tail resume's `;` is the loop's now
                    if t - 1 == closing(next(tail_at + 1), '(', ')') && is_punct(next(t), ';') { t = next(t) + 1; }
                    continue;
                }
                mout.append(tok_text(t));
                t++;
            }
        }
        // the last statement of a clause, if it is `resume(…)`: its token
        fn tail_resume(c: Clause) -> i64 {
            var e = c.close - 1;
            while e > c.open && toks[e].kind == K_SPACE { e--; }
            if is_punct(e, ';') { e--; while e > c.open && toks[e].kind == K_SPACE { e--; } }
            guard is_punct(e, ')') else { return -1; }
            // the call this `)` closes
            var depth = 0;
            var t = e;
            while t > c.open {
                if is_punct(t, ')') { depth++; }
                if is_punct(t, '(') { depth--; if depth == 0 { break; } }
                t--;
            }
            var name = t - 1;
            while name > c.open && toks[name].kind == K_SPACE { name--; }
            guard is_word(name, "resume") else { return -1; }
            // it starts a statement: after `{`, `;` or `}`
            var before = name - 1;
            while before > c.open && toks[before].kind == K_SPACE { before--; }
            if before == c.open || is_punct(before, ';') || is_punct(before, '}') { return name; }
            return -1;
        }
        fn clause_end(c: Clause, tail: i64) {
            if tail >= 0 { return; }
            if has_ret { format(mout, " } "); } else { format(mout, " } return;"); }
        }
        seg_start.push(mout.len);
        seg_line.push(line_of(toks[h.from].at));
        format(mout, "\n// handler ", hn, " (", path, ":", line_of(toks[h.from].at), ")\n");
        format(mout, "recursive fn ", hn, "<OkayCx, OkayStep>(cx: OkayCx&, start: OkayStep");
        if h.params.len > 0 { format(mout, ", ", text(h.params)); }
        format(mout, ")");
        if has_ret { format(mout, " -> ", text(h.ret)); }
        format(mout, " {\n    var step = start;\n    loop {\n        match step {\n");
        for q in h.first..h.first + h.n {
            let c = clauses[q];
            let tail = tail_resume(c);
            if c.op < 0 {
                format(mout, "            Done okay_d => {");
                if c.n_names > 0 { format(mout, " let ", text(cnames[c.first_name]), " = okay_d.v;"); }
            } else {
                let op = ops[c.op];
                format(mout, "            ");
                if text(op.name)[0] >= 'a' && text(op.name)[0] <= 'z' { mout.push(text(op.name)[0] - 32); } else { mout.push(text(op.name)[0]); }
                mout.append(text(op.name)[1..]);
                format(mout, " okay_o => {");
                var i = 0;
                each_param(op.params) { pn, ty =>
                    if i < c.n_names { format(mout, " let ", text(cnames[c.first_name + i]), " = okay_o.", pn, ";"); }
                    i++;
                };
                if c.n_names > 0 { format(mout, " let ", text(cnames[c.first_name + c.n_names - 1]), " = okay_o.k;"); }
            }
            if tail < 0 { if has_ret { format(mout, " return {"); } else { format(mout, " {"); } }
            let kname = if c.n_names > 0 { text(cnames[c.first_name + c.n_names - 1]) } else { "" };
            copy_body(next(c.open + 1), c.close - 1, kname, tail);
            clause_end(c, tail);
            format(mout, " },\n");
        }
        format(mout, "        }\n    }\n}\n");
    }

    fn write_out() {
        var i = 0;
        while i < toks.len {
            var done = false;
            for e in effs.len {
                if i == effs[e].from {
                    // the declaration kept as a comment
                    format(out, "// ");
                    for j in effs[e].from..effs[e].to + 1 {
                        let t = tok_text(j);
                        for c in t { if c == '\n' { format(out, "\n// "); } else { out.push(c); } }
                    }
                    i = effs[e].to + 1;
                    done = true;
                }
            }
            for k in sets.len {
                if !done && i == sets[k].from { write_requires(k); i = sets[k].to + 1; done = true; }
            }
            for w in fwds.len {
                if !done && i == fwds[w].from { write_forward(fwds[w]); i = fwds[w].to + 1; done = true; }
            }
            for h in hdecls {
                if !done && i == h.from {
                    for t in h.from..h.to + 1 { for c in tok_text(t) { if c == '\n' { out.push('\n'); } } }
                    write_handler(h);
                    i = h.to + 1;
                    done = true;
                }
            }
            for f in fns.len {
                let d = fns[f];
                if done { break; }
                if d.resumable {
                    if i == d.kw {
                        // the resumable fn written at the end; its lines kept as empty ones
                        for t in d.kw..d.close + 1 { for c in tok_text(t) { if c == '\n' { out.push('\n'); } } }
                        write_resumable(d);
                        i = d.close + 1;
                        done = true;
                    }
                    continue;
                }
                if i == d.name_i && d.gt < 0 { format(out, tok_text(i), "<OkayCx>"); i++; done = true; }
                else if i == d.gt { format(out, ", OkayCx>"); i++; done = true; }
                else if i == d.lp {
                    format(out, "(cx: OkayCx&");
                    if !d.no_params { format(out, ", "); }
                    i++;
                    done = true;
                }
                else if i >= d.bang_from && i <= d.bang_to { i++; done = true; }
                else if i == d.open {
                    format(out, "{ ");
                    write_check(d.set, " ");
                    i++;
                    done = true;
                }
            }
            for p in passes {
                if !done && i == p {
                    format(out, "(cx");
                    if !is_punct(next(i + 1), ')') { format(out, ", "); }
                    i++;
                    done = true;
                }
            }
            if !done {
                out.append(tok_text(i));
                i++;
            }
        }
    }

    lex();
    parse();
    check();
    write_out();          // even with errors: the resumable fns are analysed there, their errors reported too
    if errors > 0 { return false; }
    // the line map: the source's own lines as they are, each written-out part's its declaration's
    let base = out.len;
    var line = 1;
    lines.push(0);
    lines.push(1);
    for i in base { if out[i] == '\n' { line++; lines.push(line); } }
    var seg = 0;
    for i in mout.len {
        while seg + 1 < seg_start.len && seg_start[seg + 1] <= i { seg++; }
        if mout[i] == '\n' { lines.push(if seg < seg_line.len { seg_line[seg] } else { line }); }
    }
    lines.push(line);
    out.append(mout);
    // at the end, so that every line of the output is the line of the source it came from: an error Goose reports
    // in the output names the source's line
    format(out, "\n// written by okgc from ", path, ": do not edit, its lines are the source's\n");
    guard write_file(out_path, out) else {
        print("okgc: cannot write ", out_path);
        return false;
    }
    return true;
}

extern fn okay_system(cmd: const u8[:]) -> i32;

// a word for the shell, in single quotes
fn quote(out: u8[>..]&, w: u8[:]) {
    out.push('\'');
    for c in w { if c == '\'' { out.append("'\\''"); } else { out.push(c); } }
    out.push('\'');
}

// the compiler's messages with the output's lines named as the source's: `out.goose:N` becomes `in.okg:M`
fn mapped(msgs: u8[:], out_path: u8[:], in_path: u8[:], lines: i64[:]) {
    var i = 0;
    var text: u8[>..] = [];
    while i < msgs.len {
        if i + out_path.len < msgs.len && msgs[i..i + out_path.len] == out_path && msgs[i + out_path.len] == ':' {
            var j = i + out_path.len + 1;
            var n = 0;
            while j < msgs.len && msgs[j] >= '0' && msgs[j] <= '9' { n = n * 10 + (msgs[j] - '0'); j++; }
            if j > i + out_path.len + 1 {
                text.append(in_path);
                format(text, ":", if n < lines.len { lines[n] } else { n });
                i = j;
                continue;
            }
        }
        text.push(msgs[i]);
        i++;
    }
    write_stderr(text);
}

fn main() {
    let a = args();
    let usage = "usage: okgc input.okg output.goose | okgc run input.okg [args…] | okgc build input.okg -o program";
    guard a.len >= 3 else {
        print(usage);
        exit(2);
    }
    let mode = if a[1] == "run" || a[1] == "build" { a[1] } else { "" };
    let input = if mode.len > 0 { a[2] } else { a[1] };
    var src: u8[>..] = [];
    guard read_file(input, src) else {
        print("okgc: cannot read ", input);
        exit(2);
    }
    var lines: i64[>..] = [];
    if mode.len == 0 {
        guard a.len == 3 else { print(usage); exit(2); }
        if !compile(input, src, a[2], lines) { exit(1); }
        return;
    }
    // run or build: the output beside, in .okgc/, the compiler run on it, its messages mapped back
    make_dir(".okgc");
    var base_at = 0;
    for i in input.len { if input[i] == '/' { base_at = i + 1; } }
    var out_path: u8[>..] = [];
    format(out_path, ".okgc/", input[base_at..]);
    if out_path.len > 4 && out_path[out_path.len - 4..] == ".okg" { out_path.resize(out_path.len - 4); }
    out_path.append(".goose");
    if !compile(input, src, out_path, lines) { exit(1); }
    var goose: u8[>..] = [];
    if !env("GOOSE", goose) { goose.append("goose"); }
    var cmd: u8[>..] = [];
    quote(cmd, goose);
    if mode == "build" {
        guard a.len == 5 && a[3] == "-o" else { print(usage); exit(2); }
        format(cmd, " build ");
        quote(cmd, out_path);
        format(cmd, " -o ");
        quote(cmd, a[4]);
    } else {
        format(cmd, " ");
        quote(cmd, out_path);
        if a.len > 3 {
            format(cmd, " --");
            for k in 3..a.len { format(cmd, " "); quote(cmd, a[k]); }
        }
    }
    format(cmd, " 2> .okgc/messages.txt");
    let status = okay_system(cmd);
    var msgs: u8[>..] = [];
    if read_file(".okgc/messages.txt", msgs) { mapped(msgs, out_path, input, lines); }
    if status != 0 { exit(status); }
}
