/* core/bench/benchmarks/closure-heavy/kernel.c
 *
 * The C baseline for `closure-heavy`. Same pipeline, same stage arithmetic,
 * same data-driven stage selection, same one-item window, same checksum as
 * bench.dart -- the harness refuses the benchmark if any side's checksum
 * disagrees.
 *
 * THE NATURAL C IDIOM FOR CLOSURE-LIKE CODE IS FUNCTION POINTERS PLUS
 * EXPLICIT CONTEXT STRUCTS, AND THE CONTEXTS LIVE ON THE STACK. That is what
 * qsort_r callers, event-loop callbacks and every C callback API actually
 * do: the "environment" is a struct the caller owns, usually a local,
 * passed by pointer next to the function pointer. A C programmer does NOT
 * heap-allocate a context that provably does not escape the loop iteration
 * -- writing `malloc`/`free` around each env here would be naive C, not
 * idiomatic C, and ADR-0059's fairness rule is that the baseline is the
 * program a competent C programmer would write, not a transliteration of
 * DCDart's shape (the tree-traversal baseline was rewritten 2026-08-27 for
 * exactly this failure in the other direction).
 *
 * THE CONSEQUENCE IS THE MEASUREMENT. DCDart heap-allocates all three
 * environments per item and refcounts the shared Gain through them, because
 * environments-as-heap-objects is what closures ARE under ARC; C keeps the
 * same 40 bytes of state in stack frames and pays nothing. The gap between
 * the two sides is therefore the price of DCDart's closure-environment
 * allocation + ARC traffic -- which is precisely the quantity M3's
 * closure-heavy row exists to price. It is the same asymmetry the
 * tree-traversal arena baseline states in its header: the general
 * allocator's cost measured against what C actually does for the specific
 * workload, strong in C's favour on purpose.
 *
 * WHAT IS IDENTICAL BY CONSTRUCTION: the stage functions' arithmetic, the
 * selection bits, the composition order, the serial data dependency, the
 * window behaviour and the checksum. Both sides call every stage through a
 * function pointer selected from run-time data bits -- `pick_stage`'s table
 * is indexed by a value derived from the pipeline state, so neither compiler
 * can devirtualize the calls (the same guarantee the funcptr conformance
 * target's `dispatch` shape carries).
 */

#include <stdint.h>
#include <stddef.h>

#define P 1000000007ull
#define Q 1000003ull

struct gain {
    uint64_t value;
};

/* A stage's context: two scalars plus an optional pointer to the round's
 * shared gain -- field-for-field what bench.dart's Env captures. */
struct env {
    uint64_t a;
    uint64_t b;
    const struct gain *g;
};

typedef uint64_t (*stage_fn)(const struct env *e, uint64_t v);

static uint64_t st_add(const struct env *e, uint64_t v) {
    return (v + e->a + e->b) % P;
}

static uint64_t st_mul_fold(const struct env *e, uint64_t v) {
    uint64_t m = v % Q;
    return (m * (e->a % Q) + e->b) % P;
}

static uint64_t st_mix(const struct env *e, uint64_t v) {
    return ((v ^ e->a) + (v >> 7) + e->b) % P;
}

static uint64_t st_gain(const struct env *e, uint64_t v) {
    if (e->g) {
        return (v + e->g->value + e->a) % P;
    }
    return (v + e->b) % P;
}

/* Natural C stage selection: a static table indexed by data bits. The index
 * is computed from the run-time pipeline state, so the call through the
 * result cannot be folded to a direct call. */
static const stage_fn stage_table[4] = { st_add, st_mul_fold, st_mix, st_gain };

static stage_fn pick_stage(uint64_t sel) {
    return stage_table[sel & 3];
}

/* The higher-order call, mirrored so both sides route every stage
 * application through a function-pointer parameter. */
static uint64_t apply_stage(stage_fn f, const struct env *e, uint64_t x) {
    return f(e, x);
}

static uint64_t pipeline3(stage_fn f1, const struct env *e1,
                          stage_fn f2, const struct env *e2,
                          stage_fn f3, const struct env *e3,
                          uint64_t x) {
    return apply_stage(f3, e3, apply_stage(f2, e2, apply_stage(f1, e1, x)));
}

uint64_t benchKernel(uint64_t rounds) {
    uint64_t acc = 0;
    uint64_t x = 123456791ull;
    for (uint64_t r = 0; r < rounds; r++) {
        struct gain g = { (r * 2654435761ull) % Q };
        struct env prev;
        int has_prev = 0;
        for (uint64_t i = 0; i < 1024; i++) {
            uint64_t s1 = (x ^ i) % 4;
            uint64_t s2 = (x >> 3) % 4;
            uint64_t s3 = (x >> 6) % 4;
            struct env e1 = { x % Q, i % Q, NULL };
            struct env e2 = { (x + i) % Q, r % Q, &g };
            struct env e3 = { (x + r) % Q, i, &g };
            x = pipeline3(pick_stage(s1), &e1,
                          pick_stage(s2), &e2,
                          pick_stage(s3), &e3, x);
            if (has_prev) {
                x = apply_stage(pick_stage((x >> 9) % 4), &prev, x);
            }
            prev = e3;      /* the one-item window: a struct copy, which is
                             * how C keeps a non-escaping context alive */
            has_prev = 1;
            acc = (acc + x) % P;
        }
    }
    return acc;
}
