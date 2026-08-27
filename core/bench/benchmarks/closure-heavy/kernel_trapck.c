/* core/bench/benchmarks/closure-heavy/kernel_trapck.c
 *
 * `closure-heavy` in C with DCDart's TRAPPING arithmetic semantics. This is
 * the GATE baseline (ADR-0059): the <= 10% bar is measured against this so
 * the ratio isolates ARC + environment allocation rather than also charging
 * DCDart for arithmetic semantics C does not have.
 *
 * Identical to kernel.c in every other respect -- same stack contexts, same
 * function-pointer table, same window, same checksum. Value-path arithmetic
 * (stage math, gain derivation, selector mods, the checksum fold) is routed
 * through trapping.h; loop counters stay plain, following the precedent set
 * by tree-traversal's trapck (allocation and control bookkeeping are not the
 * source program's value arithmetic). Shifts, xor and mask cannot trap and
 * are unchanged.
 */

#include <stdint.h>
#include <stddef.h>
#include "trapping.h"

#define P 1000000007ull
#define Q 1000003ull

struct gain {
    uint64_t value;
};

struct env {
    uint64_t a;
    uint64_t b;
    const struct gain *g;
};

typedef uint64_t (*stage_fn)(const struct env *e, uint64_t v);

static uint64_t st_add(const struct env *e, uint64_t v) {
    return mod_ck(add_ck(add_ck(v, e->a), e->b), P);
}

static uint64_t st_mul_fold(const struct env *e, uint64_t v) {
    uint64_t m = mod_ck(v, Q);
    return mod_ck(add_ck(mul_ck(m, mod_ck(e->a, Q)), e->b), P);
}

static uint64_t st_mix(const struct env *e, uint64_t v) {
    return mod_ck(add_ck(add_ck(v ^ e->a, v >> 7), e->b), P);
}

static uint64_t st_gain(const struct env *e, uint64_t v) {
    if (e->g) {
        return mod_ck(add_ck(add_ck(v, e->g->value), e->a), P);
    }
    return mod_ck(add_ck(v, e->b), P);
}

static const stage_fn stage_table[4] = { st_add, st_mul_fold, st_mix, st_gain };

static stage_fn pick_stage(uint64_t sel) {
    return stage_table[sel & 3];
}

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
        struct gain g = { mod_ck(mul_ck(r, 2654435761ull), Q) };
        struct env prev;
        int has_prev = 0;
        for (uint64_t i = 0; i < 1024; i++) {
            uint64_t s1 = mod_ck(x ^ i, 4);
            uint64_t s2 = mod_ck(x >> 3, 4);
            uint64_t s3 = mod_ck(x >> 6, 4);
            struct env e1 = { mod_ck(x, Q), mod_ck(i, Q), NULL };
            struct env e2 = { mod_ck(add_ck(x, i), Q), mod_ck(r, Q), &g };
            struct env e3 = { mod_ck(add_ck(x, r), Q), i, &g };
            x = pipeline3(pick_stage(s1), &e1,
                          pick_stage(s2), &e2,
                          pick_stage(s3), &e3, x);
            if (has_prev) {
                x = apply_stage(pick_stage(mod_ck(x >> 9, 4)), &prev, x);
            }
            prev = e3;
            has_prev = 1;
            acc = mod_ck(add_ck(acc, x), P);
        }
    }
    return acc;
}
