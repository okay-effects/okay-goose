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
// many times (once, many: in a machine fn its operations are where the program stops, the rest a value)
let TAIL = 0;
let ONCE = 1;
let MANY = 2;
struct EffDecl { name: Span, kind: i64, first_op: i64, n_ops: i64, from: i64, to: i64 }
struct MVar { name: Span, ty: Span }                 // a variable a machine fn's rest may need: a frame's field
// a machine fn's stop: the operation, the name its value is bound to (len 0: none), its arguments' parentheses,
// the statement's tokens, the variables known before it (vars[..nvars]: the frame's fields)
struct Point { op: i64, bind: Span, args_lp: i64, args_rp: i64, stmt_from: i64, stmt_to: i64, nvars: i64 }
struct SetDecl { name: Span, first: i64, n: i64, from: i64, to: i64 }  // members[first..first+n]: effects
struct Fwd { ty: Span, field: Span, set: i64, first_ex: i64, n_ex: i64, from: i64, to: i64 }
// a function with effects: `fn name<…>(params) -> A ! F + G { body }` — its set (anonymous, named by its effects'
// text), and the tokens the writer changes: after the name (or the generics' `>`) the context's type parameter, at
// `(` the context, `! F + G` dropped, at `{` the check that the context has every operation
struct FnDecl { name: Span, name_i: i64, set: i64, gt: i64, lp: i64, rp: i64, no_params: bool, bang_from: i64,
                bang_to: i64, open: i64, close: i64, machine: bool, kw: i64, ret: Span }

fn is_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

// The whole run over one file: false when it found errors (printed, nothing written).
fn compile(path: const u8[:], src: u8[:], out_path: const u8[:]) -> bool {
    var toks: Tok[>..] = [];
    var ops: OpDecl[>..] = [];
    var effs: EffDecl[>..] = [];
    var sets: SetDecl[>..] = [];
    var members: i64[>..] = [];
    var fwds: Fwd[>..] = [];
    var excepts: Span[>..] = [];
    var fns: FnDecl[>..] = [];
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
                while i < src.len && (is_alpha(src[i]) || is_digit(src[i]) || src[i] == '.') { i++; }
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
    fn parse_fn(from: i64, machine: bool, kw: i64) -> i64 {
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
            if machine { error_at(toks[kw].at, "a machine fn says its effects: `-> A ! F + G`"); }
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
                          bang_from: bang, bang_to: last, open: open, close: close, machine: machine, kw: kw,
                          ret: ret });
        return close + 1;
    }

    // the top level: the four forms found, everything else passed by
    fn parse() {
        var i = next(0);
        while i < toks.len {
            if is_word(i, "effect") { i = next(parse_effect(i)); }
            else if is_word(i, "effects") { i = next(parse_set(i)); }
            else if is_word(i, "forward") { i = next(parse_forward(i)); }
            else if is_word(i, "machine") && is_word(next(i + 1), "fn") { i = next(parse_fn(next(i + 1), true, i)); }
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
                    else if !d.machine {
                        error_at(toks[i].at, str("`", tok_text(i), "` keeps the rest of the program (",
                            text(effs[ops[o].effect].name), " is not tail): it is called in a machine fn"));
                    }
                } else if g >= 0 {
                    if d.machine && fns[g].machine {
                        error_at(toks[i].at, str("a machine fn calling a machine fn (`", tok_text(i), "`): not yet"));
                    }
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

    // MACHINE FNS: the program cut at each operation that keeps the rest; each rest a frame — a variant naming where
    // it stops, its fields the variables it needs —, each piece a function: the first `name(cx, …)`, the others
    // `resume(cx, k, v)` by the frame's variant, `v` of the operation's type. Its steps a value: `Done`, or an
    // operation with its arguments and its rest `k`, flat — copied to resume again, written out as bytes
    var mout: u8[>..] = [];

    fn is_control(i: i64, set: i64) -> i64 {
        if toks[i].kind != K_IDENT || !is_punct(next(i + 1), '(') { return -1; }
        let o = find_op(span_of(i));
        if o < 0 || effs[ops[o].effect].kind == TAIL || !set_has(set, ops[o].effect) { return -1; }
        return o;
    }

    fn write_machine(d: FnDecl) {
        var vars: MVar[>..] = [];
        var points: Point[>..] = [];
        // the parameters: the first variables
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
            vars.push(MVar { name: span_of(name_i), ty: Span { at: toks[t0].at, len: toks[last].at + toks[last].len - toks[t0].at } });
            i = if e < d.rp { next(e + 1) } else { d.rp };
        }
        // the statements: each stop found, each variable bound
        var j = next(d.open + 1);
        while j < d.close {
            let st = j;
            var e = j;
            var depth = 0;
            loop {
                if e >= d.close { break; }
                if is_punct(e, '{') || is_punct(e, '(') || is_punct(e, '[') { depth++; }
                if is_punct(e, '}') || is_punct(e, ')') || is_punct(e, ']') {
                    depth--;
                    if depth == 0 && is_punct(e, '}') && !is_word(next(e + 1), "else") { break; }
                }
                if depth == 0 && is_punct(e, ';') { break; }
                e++;
            }
            var stop = -1;
            var bind = Span { at: 0, len: 0 };
            var call = -1;
            var plain_name = Span { at: 0, len: 0 };
            var plain_ty = Span { at: 0, len: 0 };
            if is_word(st, "let") || is_word(st, "var") {
                let name_i = next(st + 1);
                var eq = next(name_i + 1);
                if is_punct(eq, ':') {
                    let t0 = next(eq + 1);
                    var t = t0;
                    while t < e && !is_punct(t, '=') { t++; }
                    var last = t - 1;
                    while last > t0 && toks[last].kind == K_SPACE { last--; }
                    plain_ty = Span { at: toks[t0].at, len: toks[last].at + toks[last].len - toks[t0].at };
                    eq = t;
                }
                let rhs = next(eq + 1);
                let o = is_control(rhs, d.set);
                if o >= 0 && next(closing(next(rhs + 1), '(', ')') + 1) == e {
                    stop = o;
                    bind = span_of(name_i);
                    call = rhs;
                } else {
                    plain_name = span_of(name_i);
                }
            } else {
                let o = is_control(st, d.set);
                if o >= 0 && next(closing(next(st + 1), '(', ')') + 1) == e { stop = o; call = st; }
            }
            if stop < 0 {
                for t in st..e + 1 {
                    if t < d.close && is_control(t, d.set) >= 0 {
                        error_at(toks[t].at, str("`", tok_text(t), "` inside a statement: a machine fn stops only at ",
                            "`let x = op(…);` or `op(…);` in its body (if and loops: not yet)"));
                    }
                }
                if plain_name.len > 0 { vars.push(MVar { name: plain_name, ty: plain_ty }); }
            } else {
                let lp = next(call + 1);
                points.push(Point { op: stop, bind: bind, args_lp: lp, args_rp: closing(lp, '(', ')'), stmt_from: st,
                                    stmt_to: e, nvars: vars.len });
                if bind.len > 0 { vars.push(MVar { name: bind, ty: ops[stop].ret }); }
            }
            j = next(e + 1);
        }
        // every variable in a frame has a type
        for p in points {
            for v in p.nvars {
                if vars[v].ty.len == 0 {
                    error_at(vars[v].name.at, str("`", text(vars[v].name), "` lives across a stop of a machine fn: ",
                        "give it a type (`let ", text(vars[v].name), ": T = …`)"));
                    return;
                }
            }
        }
        var pname: u8[>..] = [];
        let n = text(d.name);
        if n[0] >= 'a' && n[0] <= 'z' { pname.push(n[0] - 32); } else { pname.push(n[0]); }
        pname.append(n[1..]);
        let has_ret = d.ret.len > 0 && text(d.ret) != "()";

        fn cap(s: u8[:]) {
            if s[0] >= 'a' && s[0] <= 'z' { mout.push(s[0] - 32); } else { mout.push(s[0]); }
            mout.append(s[1..]);
        }
        fn used(o: i64) -> bool {
            for p in points { if p.op == o { return true; } }
            return false;
        }
        fn fields(nv: i64) {
            for v in nv {
                if v > 0 { format(mout, ", "); }
                format(mout, text(vars[v].name), ": ", text(vars[v].name));
            }
        }
        // tokens copied: the context passed, each `return x;` the program's `Done`
        fn copy_tokens(from: i64, to: i64) {
            var close_at = -1;
            var t = from;
            while t <= to && t < toks.len {
                var passed = false;
                for q in passes { if q == t { passed = true; } }
                if passed {
                    format(mout, "(cx");
                    if !is_punct(next(t + 1), ')') { format(mout, ", "); }
                    t++;
                    continue;
                }
                if t == close_at { format(mout, ") }"); }
                if is_word(t, "return") {
                    let v = next(t + 1);
                    if is_punct(v, ';') { format(mout, "return ", pname, ".Done {}"); t = v; continue; }
                    format(mout, "return ", pname, ".Done { v: (");
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
                mout.append(tok_text(t));
                t++;
            }
        }
        // the stop's step: the operation's arguments by its parameters' names, and the rest
        fn write_stop(k: i64) {
            let p = points[k];
            let op = ops[p.op];
            format(mout, " return ", pname, ".");
            cap(text(op.name));
            format(mout, " { ");
            var a = next(p.args_lp + 1);
            each_param(op.params) { pn, ty =>
                var e = a;
                var dp = 0;
                while e < p.args_rp && !(dp == 0 && is_punct(e, ',')) {
                    if is_punct(e, '(') || is_punct(e, '[') { dp++; }
                    if is_punct(e, ')') || is_punct(e, ']') { dp--; }
                    e++;
                }
                format(mout, pn, ": (");
                copy_tokens(a, e - 1);
                format(mout, "), ");
                a = if e < p.args_rp { next(e + 1) } else { p.args_rp };
            };
            format(mout, "k: ", pname, "_", text(op.name), ".At", k, " { ");
            fields(p.nvars);
            format(mout, " } };");
        }
        // the piece after stop k-1 (k == 0: from the start), to stop k or the end
        fn write_piece(k: i64) {
            let from = if k == 0 { d.open + 1 } else { points[k - 1].stmt_to + 1 };
            let to = if k < points.len { points[k].stmt_from - 1 } else { d.close - 1 };
            copy_tokens(from, to);
            if k < points.len { write_stop(k); }
            else if !has_ret { format(mout, " return ", pname, ".Done {};"); }
        }

        format(mout, "\n// machine fn ", n, " (", path, ":", line_of(toks[d.kw].at), "): its rests and its steps\n");
        for o in ops.len {
            if !used(o) { continue; }
            format(mout, "enum ", pname, "_", text(ops[o].name), " {");
            var first = true;
            for k in points.len {
                if points[k].op != o { continue; }
                if !first { format(mout, ","); }
                first = false;
                format(mout, " At", k, " { ");
                for v in points[k].nvars {
                    if v > 0 { format(mout, ", "); }
                    format(mout, text(vars[v].name), ": ", text(vars[v].ty));
                }
                format(mout, " }");
            }
            format(mout, " }\n");
        }
        format(mout, "enum ", pname, " { Done { ");
        if has_ret { format(mout, "v: ", text(d.ret), " "); }
        format(mout, "}");
        for o in ops.len {
            if !used(o) { continue; }
            format(mout, ", ");
            cap(text(ops[o].name));
            format(mout, " { ");
            each_param(ops[o].params) { pn, ty => format(mout, pn, ": ", ty, ", "); };
            format(mout, "k: ", pname, "_", text(ops[o].name), " }");
        }
        format(mout, " }\n");
        // the first piece
        format(mout, "fn ", n, "<OkayCx>(cx: OkayCx&");
        if !d.no_params { format(mout, ", ", src[toks[d.lp].at + 1..toks[d.rp].at]); }
        format(mout, ") -> ", pname, " { ");
        let saved = out.len;
        write_check(d.set, " ");
        // write_check writes to out: moved here
        mout.append(out[saved..]);
        out.resize(saved);
        write_piece(0);
        format(mout, " }\n");
        // the others: resumed by the frame's variant, with the operation's value
        for k in points.len {
            let p = points[k];
            let op = ops[p.op];
            format(mout, "fn resume<OkayCx>(cx: OkayCx&, k: ", pname, "_", text(op.name), ".At", k);
            if op.ret.len > 0 { format(mout, ", v: ", text(op.ret)); }
            format(mout, ") -> ", pname, " {");
            for v in p.nvars { format(mout, " var ", text(vars[v].name), " = k.", text(vars[v].name), ";"); }
            if p.bind.len > 0 { format(mout, " var ", text(p.bind), " = v;"); }
            write_piece(k + 1);
            format(mout, " }\n");
        }
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
            for f in fns.len {
                let d = fns[f];
                if done { break; }
                if d.machine {
                    if i == d.kw {
                        // the machine fn written at the end; its lines kept as empty ones
                        for t in d.kw..d.close + 1 { for c in tok_text(t) { if c == '\n' { out.push('\n'); } } }
                        write_machine(d);
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
    write_out();          // even with errors: the machine fns are analysed there, their errors reported too
    if errors > 0 { return false; }
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

fn main() {
    let a = args();
    guard a.len == 3 else {
        print("usage: okgc input.okg output.goose");
        exit(2);
    }
    var src: u8[>..] = [];
    guard read_file(a[1], src) else {
        print("okgc: cannot read ", a[1]);
        exit(2);
    }
    if !compile(a[1], src, a[2]) { exit(1); }
}
