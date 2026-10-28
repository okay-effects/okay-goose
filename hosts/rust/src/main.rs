//! okay-goose's wire against okay-rust: a Goose program's effects answered by Rust handlers, a resumable fn's stops
//! answered by Rust, and a Rust program's effects answered by a Goose shop — each side seeing only operations
//! (a name and a record) and answers (a plain value), a line of JSON each on the child's stdin and stdout.
//!
//!   okay-goose-host path/to/wire        (the binary of examples/wire.okg)

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use okay::host::{drive, remote, start};
use okay::typed::*;
use okay::wire::serve;
use okay::Data;

// the same effects as examples/wire.okg: an operation's name and its fields are the wire's
okay::effect! { pub enum Stock: Plain, wire { Reserve(item: String) -> bool = reserve; } }
okay::effect! { pub enum Pay: Plain, wire { Charge(user: String, cents: i64) -> i64 = charge; } }
okay::effect! { pub enum Log: Plain, wire { Line(line: String) -> () = log; } }
okay::effect! { pub enum Approve: Plain, wire { Approve(cents: i64) -> bool = approve; } }

// JSON: the wire's text, Data both ways

fn json(d: &Data, out: &mut String) {
    match d {
        Data::Null => out.push_str("null"),
        Data::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Data::Int(n) => out.push_str(&n.to_string()),
        Data::Float(f) => out.push_str(&f.to_string()),
        Data::Str(s) => {
            out.push('"');
            for c in s.chars() {
                match c {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        Data::List(xs) => {
            out.push('[');
            for (i, x) in xs.iter().enumerate() {
                if i > 0 { out.push(','); }
                json(x, out);
            }
            out.push(']');
        }
        Data::Dict(kv) => {
            out.push('{');
            for (i, (k, v)) in kv.iter().enumerate() {
                if i > 0 { out.push(','); }
                json(&Data::Str(k.clone()), out);
                out.push(':');
                json(v, out);
            }
            out.push('}');
        }
    }
}

fn parse(s: &str) -> Result<Data, String> {
    fn value(b: &[u8], i: &mut usize) -> Result<Data, String> {
        while *i < b.len() && b[*i].is_ascii_whitespace() { *i += 1; }
        match b.get(*i) {
            Some(b'{') => {
                *i += 1;
                let mut kv = vec![];
                loop {
                    while b[*i].is_ascii_whitespace() { *i += 1; }
                    if b[*i] == b'}' { *i += 1; return Ok(Data::Dict(kv)); }
                    let Data::Str(k) = value(b, i)? else { return Err("a key".into()) };
                    while b[*i].is_ascii_whitespace() { *i += 1; }
                    *i += 1; // :
                    kv.push((k, value(b, i)?));
                    while b[*i].is_ascii_whitespace() { *i += 1; }
                    if b[*i] == b',' { *i += 1; }
                }
            }
            Some(b'[') => {
                *i += 1;
                let mut xs = vec![];
                loop {
                    while b[*i].is_ascii_whitespace() { *i += 1; }
                    if b[*i] == b']' { *i += 1; return Ok(Data::List(xs)); }
                    xs.push(value(b, i)?);
                    while b[*i].is_ascii_whitespace() { *i += 1; }
                    if b[*i] == b',' { *i += 1; }
                }
            }
            Some(b'"') => {
                *i += 1;
                let mut s = String::new();
                while b[*i] != b'"' {
                    if b[*i] == b'\\' {
                        *i += 1;
                        s.push(match b[*i] { b'n' => '\n', b't' => '\t', c => c as char });
                    } else {
                        s.push(b[*i] as char);
                    }
                    *i += 1;
                }
                *i += 1;
                Ok(Data::Str(s))
            }
            Some(b't') => { *i += 4; Ok(Data::Bool(true)) }
            Some(b'f') => { *i += 5; Ok(Data::Bool(false)) }
            Some(b'n') => { *i += 4; Ok(Data::Null) }
            Some(_) => {
                let start = *i;
                while *i < b.len() && (b[*i] == b'-' || b[*i] == b'.' || b[*i] == b'e' || b[*i].is_ascii_digit()) { *i += 1; }
                let t = std::str::from_utf8(&b[start..*i]).unwrap();
                if t.contains('.') || t.contains('e') { t.parse().map(Data::Float).map_err(|e| e.to_string()) }
                else { t.parse().map(Data::Int).map_err(|e| e.to_string()) }
            }
            None => Err("json: nothing".into()),
        }
    }
    value(s.as_bytes(), &mut 0)
}

fn field<'a>(d: &'a Data, k: &str) -> Option<&'a Data> {
    match d { Data::Dict(kv) => kv.iter().find(|(key, _)| key == k).map(|(_, v)| v), _ => None }
}

// THE CHILD: the Goose program, one line of JSON a message each way

struct Goose { child: Child, input: ChildStdin, output: BufReader<ChildStdout> }

impl Goose {
    fn start(exe: &str, mode: &str) -> Goose {
        let mut child = Command::new(exe).arg(mode).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn()
            .unwrap_or_else(|e| panic!("cannot start {exe}: {e}"));
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Goose { child, input, output }
    }
    fn send(&mut self, d: &Data) {
        let mut s = String::new();
        json(d, &mut s);
        writeln!(self.input, "{s}").unwrap();
        self.input.flush().unwrap();
    }
    fn receive(&mut self) -> Data {
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        parse(line.trim()).unwrap_or_else(|e| panic!("from goose: {e}: {line}"))
    }
}

/// a Goose program run as a guest: each operation it asks answered by `answer`, its value at its end
fn host(exe: &str, mode: &str, mut answer: impl FnMut(&str, &Data) -> Result<Data, String>) -> Data {
    let mut g = Goose::start(exe, mode);
    loop {
        let m = g.receive();
        if let Some(v) = field(&m, "done") {
            let _ = g.child.wait();
            return v.clone();
        }
        let Some(Data::Str(name)) = field(&m, "op") else { panic!("from goose: {m:?}") };
        let args = field(&m, "args").cloned().unwrap_or(Data::Dict(vec![]));
        println!("  goose asks: {name} {args:?}");
        let reply = match answer(name, &args) {
            Ok(v) => Data::Dict(vec![("ok".into(), v)]),
            Err(e) => Data::Dict(vec![("fail".into(), Data::Str(e))]),
        };
        g.send(&reply);
    }
}

okay::needs! {
    /// the business code in Rust: its effects answered wherever the context says — here, by a Goose shop
    async fn checkout(cx: [Stock, Pay, Log], user: &str, item: &str, cents: i64) -> i64 {
        if !reserve(cx, item.to_string()).await {
            log(cx, "out of stock".into()).await;
            return -1;
        }
        let receipt = charge(cx, user.to_string(), cents).await;
        log(cx, format!("receipt {receipt}")).await;
        receipt
    }
}

fn main() {
    let exe = std::env::args().nth(1).expect("usage: okay-goose-host path/to/wire");

    // 1. a Goose program, its effects answered by Rust handlers — okay-rust's own `serve`
    let stock = serve(|op: Stock| match op { Stock::Reserve(item, r) => r.give(item == "book") });
    let pay = serve(|op: Pay| match op { Pay::Charge(_, cents, r) => r.give(if cents <= 5000 { 7001 } else { -1 }) });
    let log_ = serve(|op: Log| match op { Log::Line(line, r) => { println!("  rust log: {line}"); r.give(()) } });
    println!("1. a Goose checkout, Rust's handlers:");
    let v = host(&exe, "guest", |name, rec| {
        stock(name, rec).or_else(|| pay(name, rec)).or_else(|| log_(name, rec)).unwrap_or_else(|| Err(format!("no {name}")))
    });
    println!("   its value: {v:?}");

    // 2. a Goose resumable fn, each stop answered by Rust: a manager approving up to 200
    let approve_ = serve(|op: Approve| match op { Approve::Approve(cents, r) => r.give(cents <= 200) });
    println!("2. a Goose resumable fn, its stops answered by Rust:");
    let v = host(&exe, "approvals", |name, rec| approve_(name, rec).unwrap_or_else(|| Err(format!("no {name}"))));
    println!("   approved: {v:?}");

    // 3. a Rust program handed out (okay::host), its effects answered by the Goose shop
    println!("3. a Rust checkout, the Goose shop's handlers:");
    let mut g = Goose::start(&exe, "serve");
    let program = |user: &'static str, item: &'static str, cents: i64| {
        start(move |h| async move {
            let cx = Cx(h.outside::<Stock>(), Cx(h.outside::<Pay>(), Cx(h.outside::<Log>(), End)));
            checkout(&cx, user, item, cents).await
        })
    };
    let mut call = |name: &str, args: Vec<Data>| -> Result<Data, String> {
        let rec = args.into_iter().next().unwrap_or(Data::Dict(vec![]));
        g.send(&Data::Dict(vec![("op".into(), Data::Str(name.into())), ("args".into(), rec)]));
        let m = g.receive();
        match (field(&m, "ok"), field(&m, "fail")) {
            (Some(v), _) => Ok(v.clone()),
            (_, Some(Data::Str(e))) => Err(e.clone()),
            _ => Err(format!("from goose: {m:?}")),
        }
    };
    println!("   ann's book: {:?}", drive(program("ann", "book", 300), remote(&mut call)));
    println!("   bob's book: {:?}", drive(program("bob", "book", 300), remote(&mut call)));
}
