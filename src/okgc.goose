// okgc — okay-goose's front end, v0: effects declared and checked, plain Goose out.
//
// It reads Goose with four additions and writes plain Goose:
//
//   effect Pay { charge(user: u8[:], cents: i64) -> bool; refund(id: i64); }
//   effects App = Pay + Log;                          // a set of effects (of effects or of sets)
//   fn checkout<C>(cx: C& / App, ...) { ... }         // a function's effects: what it may ask of cx
//   forward Limited<H> to inner for App except charge;   // a wrapper's operations passed on to a field
//
// Checked at definition: a function with effects calls on its context only operations of its set, and calls
// another function with effects only if that one's set is in its own. Written out: `requires_App(cx)` at the top
// of such a function (a context lacking an operation is an error naming it), the forwarding functions, the rest of
// the text as it was.
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
struct EffDecl { name: Span, first_op: i64, n_ops: i64, from: i64, to: i64 }
struct SetDecl { name: Span, first: i64, n: i64, from: i64, to: i64 }  // members[first..first+n]: effects
struct Fwd { ty: Span, field: Span, set: i64, first_ex: i64, n_ex: i64, from: i64, to: i64 }
struct FnDecl { name: Span, set: i64, param: Span, row_from: i64, row_to: i64, open: i64, close: i64 }

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
        let open = next(name_i + 1);
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
        effs.push(EffDecl { name: span_of(name_i), first_op: first, n_ops: ops.len - first, from: from, to: close });
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

    // fn name...(…, cx: T / Set, …) … { body }: a function with effects; any other fn is passed by
    fn parse_fn(from: i64) -> i64 {
        let name_i = next(from + 1);
        var lp = next(name_i + 1);
        if is_punct(lp, '<') { lp = next(closing(lp, '<', '>') + 1); }
        guard is_punct(lp, '(') else { return from + 1; }
        let rp = closing(lp, '(', ')');
        var row_from = -1;
        var set = -1;
        var param = Span { at: 0, len: 0 };
        var i = lp + 1;
        var last_name = Span { at: 0, len: 0 };
        while i < rp {
            if toks[i].kind == K_IDENT && is_punct(next(i + 1), ':') { last_name = span_of(i); }
            if is_punct(i, '/') {
                let s = next(i + 1);
                if toks[s].kind == K_IDENT && find_set(span_of(s)) >= 0 {
                    row_from = i;
                    set = find_set(span_of(s));
                    param = last_name;
                    i = s;
                }
            }
            i++;
        }
        var open = rp + 1;
        while open < toks.len && !is_punct(open, '{') && !is_punct(open, ';') { open++; }
        guard is_punct(open, '{') else { return open + 1; }
        let close = closing(open, '{', '}');
        if set >= 0 {
            fns.push(FnDecl { name: span_of(name_i), set: set, param: param, row_from: row_from,
                              row_to: next(row_from + 1), open: open, close: close });
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
            else if is_word(i, "fn") || is_word(i, "recursive") {
                let f = if is_word(i, "recursive") { next(i + 1) } else { i };
                i = next(parse_fn(f));
            }
            else { i = next(i + 1); }
        }
    }

    // CHECKING: each function with effects calls on its context only operations of its set, and functions with
    // effects whose sets are in its own
    fn check() {
        for f in fns.len {
            let d = fns[f];
            let set_name = text(sets[d.set].name);
            for i in d.open..d.close {
                // name(cx …  or  cx.name(
                var callee = -1;
                if toks[i].kind == K_IDENT && is_punct(next(i + 1), '(') {
                    let a = next(next(i + 1) + 1);
                    if a < toks.len && toks[a].kind == K_IDENT && tok_text(a) == text(d.param) { callee = i; }
                }
                if toks[i].kind == K_IDENT && tok_text(i) == text(d.param) && is_punct(i + 1, '.') {
                    let m = i + 2;
                    if m < toks.len && toks[m].kind == K_IDENT && is_punct(next(m + 1), '(') { callee = m; }
                }
                if callee < 0 { continue; }
                let o = find_op(span_of(callee));
                if o >= 0 && !set_has(d.set, ops[o].effect) {
                    error_at(toks[callee].at, str("`", text(d.name), "` (effects ", set_name, ") calls `",
                        tok_text(callee), "` of ", text(effs[ops[o].effect].name), ", which ", set_name,
                        " does not have"));
                }
                let g = find_fn(span_of(callee));
                if o < 0 && g >= 0 {
                    let gs = sets[fns[g].set];
                    for m in gs.first..gs.first + gs.n {
                        if !set_has(d.set, members[m]) {
                            error_at(toks[callee].at, str("`", text(d.name), "` (effects ", set_name,
                                ") calls `", tok_text(callee), "` (effects ", text(gs.name), "), which needs ",
                                text(effs[members[m]].name)));
                        }
                    }
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

    fn write_requires(k: i64) {
        let st = sets[k];
        format(out, "fn requires_", text(st.name), "<C>(cx: C&) {\n    if false {\n");
        for m in st.first..st.first + st.n {
            let e = effs[members[m]];
            for o in e.first_op..e.first_op + e.n_ops {
                format(out, "        ", text(ops[o].name), "(cx");
                each_param(ops[o].params) { name, ty => format(out, ", default<", ty, ">()"); };
                format(out, ");\n");
            }
        }
        format(out, "    }\n}");
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
                if !first { format(out, "\n"); }
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
                if !done && i == fns[f].row_from { i = fns[f].row_to + 1; done = true; }
                if !done && i == fns[f].open {
                    format(out, "{ requires_", text(sets[fns[f].set].name), "(", text(fns[f].param), ");");
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
    if errors > 0 { return false; }
    format(out, "// written by okgc from ", path, ": do not edit\n");
    write_out();
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
