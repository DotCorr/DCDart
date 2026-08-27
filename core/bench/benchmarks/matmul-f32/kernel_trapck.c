/* core/bench/benchmarks/matmul-f32/kernel_trapck.c
 *
 * `matmul-f32` in C with DCDart's TRAPPING arithmetic on the INTEGER
 * operations. Derived line-by-line from THIS benchmark's kernel.c -- the
 * only differences are *_ck routings (diff the two files to check; nothing
 * else may differ, or the attribution table lies).
 *
 * THE ASYMMETRY THIS FILE CANNOT REMOVE, per neon/ROADMAP.md N2's caveat:
 * FLOATING-POINT ARITHMETIC DOES NOT TRAP, in DCDart or anywhere else
 * (ADR-0065: IEEE semantics, no overflow checks), so every FMul/FAdd below
 * stays plain and only the u64 index/LCG/checksum arithmetic is routed
 * through trapping.h. On this float-dominated kernel the Ctrap/C delta is
 * therefore expected to be much smaller than on fib-shaped integer code --
 * that is a property of the workload, not a flattering baseline choice, and
 * the manifest says so where the numbers will be read.
 *
 * Loop-header increments stay plain, matching the convention of every
 * existing kernel_trapck.c in this tree (string-pass, tree-traversal,
 * hashmap); all other integer arithmetic -- index expressions, block
 * bounds, the LCG, the seeds, the checksum fold -- is routed.
 *
 * (Original notes, true of both files: identical loop nest and order as
 * bench.dart so the f32 accumulation is bit-exact across sides; inputs from
 * the shared LCG with exact power-of-two scaling; union type punning for
 * the bit fold because -fno-builtin makes memcpy a real call; malloc not
 * NULL-checked, matching DCDart's trap-on-OOM.)
 */

#include <stdint.h>
#include <stdlib.h>
#include "trapping.h"

/* Identical recurrence to bench.dart's fillBuf. Values are
 * (x % 256 - 128) / 64, exact in f32, in [-2, 2). */
static void fill_buf(float *dst, uint64_t n, uint64_t seed) {
    uint64_t x = seed;
    for (uint64_t i = 0; i < n; i++) {
        x = mod_ck(add_ck(mul_ck(x, 1103515245), 12345), 2147483648u);
        float v = (float)(uint32_t)mod_ck(x, 256);
        dst[i] = (v - 128.0f) * 0.015625f;
    }
}

static void zero_buf(float *dst, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) dst[i] = 0.0f;
}

/* C[i,j] += A[i,p] * B[p,j], blocked (block 32; 96 divides evenly, no edge
 * blocks). i-p-j inner order with a[i,p] hoisted -- the standard row-major
 * form, and bench.dart's exact loop nest. */
static void matmul_blocked(const float *a, const float *b, float *c,
                           uint64_t m, uint64_t k, uint64_t n) {
    const uint64_t blk = 32;
    for (uint64_t ii = 0; ii < m; ii += blk) {
        uint64_t i_end = add_ck(ii, blk);
        for (uint64_t kk = 0; kk < k; kk += blk) {
            uint64_t p_end = add_ck(kk, blk);
            for (uint64_t jj = 0; jj < n; jj += blk) {
                uint64_t j_end = add_ck(jj, blk);
                for (uint64_t i = ii; i < i_end; i++) {
                    for (uint64_t p = kk; p < p_end; p++) {
                        float av = a[add_ck(mul_ck(i, k), p)];
                        for (uint64_t j = jj; j < j_end; j++) {
                            c[add_ck(mul_ck(i, n), j)] =
                                c[add_ck(mul_ck(i, n), j)]
                                + av * b[add_ck(mul_ck(p, n), j)];
                        }
                    }
                }
            }
        }
    }
}

/* string-pass's rolling hash, over the output's raw f32 bit patterns. */
static uint64_t fold_bits(const float *buf, uint64_t n, uint64_t acc) {
    for (uint64_t i = 0; i < n; i++) {
        union { float f; uint32_t u; } pun;
        pun.f = buf[i];
        acc = mod_ck(add_ck(mul_ck(acc, 31), pun.u), 1000000007);
    }
    return acc;
}

uint64_t benchKernel(uint64_t rounds) {
    const uint64_t m = 96, k = 96, n = 96;
    float *a = malloc(m * k * 4);
    float *b = malloc(k * n * 4);
    float *c = malloc(m * n * 4);

    uint64_t acc = 0;
    for (uint64_t r = 0; r < rounds; r++) {
        fill_buf(a, mul_ck(m, k), add_ck(mul_ck(r, 2), 1));
        fill_buf(b, mul_ck(k, n), add_ck(mul_ck(r, 2), 2));
        zero_buf(c, mul_ck(m, n));
        matmul_blocked(a, b, c, m, k, n);
        acc = fold_bits(c, mul_ck(m, n), acc);
    }

    free(a);
    free(b);
    free(c);
    return acc;
}
