// okay-goose's lanes: values the C compiler cannot see through (Rust's black_box, Zig's doNotOptimizeAway) — an
// empty asm the value goes through, no call. Included by `okgc build bench/lanes.okg -o … --include bench/opaque.h`.
static inline int64_t okay_opaque(int64_t x) { __asm__ volatile("" : "+r"(x)); return x; }
static inline void okay_keep(int64_t x) { __asm__ volatile("" : : "r"(x)); }
