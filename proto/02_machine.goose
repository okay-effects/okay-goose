// 2. A MACHINE: a program as data, the rest `k` as data. Each bind's rest is a named variant (defunctionalized: no
// closures in data), its body a case function; `among` takes `k` — a copy of the frames — and the `all` handler
// resumes it once for each alternative: a multi-shot continuation, a memcpy each.

// the program, written by hand as the generator would write it from:
//     a <- among(3); b <- among(2); pure(A[a] + B[b])
enum Frame { PickB, Sum { a: i64 } }
enum Node { Pure { v: i64 }, Among { n: i64, then: Frame } }

let A: i64[3] = [1, 2, 3];
let B: i64[2] = [10, 20];

fn start() -> Node { Node.Among { n: 3, then: Frame.PickB } }
fn step(f: Frame.PickB, i: i64) -> Node { Node.Among { n: 2, then: Frame.Sum { a: A[i] } } }
fn step(f: Frame.Sum, i: i64) -> Node { Node.Pure { v: f.a + B[i] } }

// the tables of a run: the frames waiting, the saved rests (a stack shared by the recursion), the values found
struct Run { frames: Frame[>..<]&, saved: Frame[>..<]&, out: i64[>..]&, steps: i64 }

// THE `all` HANDLER: every path's value. A choice takes the rest — the frames now — saves it, and resumes it with
// each alternative: the frames put back as they were, the alternative given to the top one
recursive fn drive(r: Run&, start_node: Node) {
    var node = start_node;
    loop {
        r.steps += 1;
        match node {
            Pure p => {
                if r.frames.len == 0 { r.out.push(p.v); return; }
                let f = r.frames[r.frames.len - 1];
                r.frames.resize(r.frames.len - 1);
                node = step(f, p.v);
            },
            Among c => {
                r.frames.push(c.then);
                // k: the frames, saved above the callers' saved rests
                let mark = r.saved.len;
                for f in r.frames { r.saved.push(f); }
                let n = c.n;
                for i in n {
                    r.frames.resize(0);
                    for j in mark..r.saved.len { r.frames.push(r.saved[j]); }
                    let f = r.frames[r.frames.len - 1];
                    r.frames.resize(r.frames.len - 1);
                    drive(r, step(f, i));
                }
                r.saved.resize(mark);
                return;
            },
        }
    }
}

fn main() {
    var frames: Frame[>..<] = [];
    var saved: Frame[>..<] = [];
    var out: i64[>..] = [];
    var r = Run { frames: frames, saved: saved, out: out, steps: 0 };
    drive(r, start());
    print(out, " in ", r.steps, " steps");
    // the rest is data: it can be written out as bytes
    var k: Frame[>..] = [];
    k.push(Frame.Sum { a: 2 });
    let bytes = k.to_bytes();
    var back, ok = from_bytes<Frame[>..]>(bytes);
    print("k as ", bytes.len, " bytes, back: ", ok, " ", back);
}
