/* core/bench/benchmarks/matmul-f32/kernel.c
 *
 * The C baseline for `matmul-f32`: blocked 96x96x96 f32 matrix multiply,
 * the IDENTICAL loop nest in the IDENTICAL order as bench.dart, so the f32
 * accumulation is bit-exact across the two sides and the checksum (a modular
 * fold of the output's raw IEEE bit patterns) can demand equality rather
 * than tolerance. Any reassociation on either side is a checksum mismatch.
 *
 * Inputs are deterministic: the same integer LCG as bench.dart, converted
 * u64 % 256 -> u32 -> f32 (exact) and centered/scaled by powers of two
 * (exact), so no decimal-literal rounding question exists anywhere in the
 * data. Refilled per round with a round-dependent seed so no round's work
 * can be hoisted or cached across the repeat loop.
 *
 * FP CONTRACTION STAYS ON (clang's default) in this file, DELIBERATELY,
 * and the checksum still matches bit-exactly. That is not luck: inputs are
 * multiples of 1/64 with |v| < 2, so every product is a multiple of 1/4096
 * below 2^4 and every partial sum of 96 such products stays below 2^24 --
 * ALL intermediate values are exactly representable in f32, and a fused
 * multiply-add (one rounding) equals the unfused pair (two roundings that
 * never round). Keeping contraction keeps this C baseline idiomatic --
 * real fmla instructions in the hot loop -- so the ratio honestly includes
 * DCDart's missing FP contraction (dcc emits fmul+fadd, never fmuladd).
 * Contrast attention-f32, whose inexact values force its C baseline to
 * #pragma STDC FP_CONTRACT OFF; read the pair together.
 *
 * The bit fold reads f32 storage as u32 through a union (C11 type punning,
 * defined behavior) rather than memcpy: under this harness's mandatory
 * -fno-builtin, memcpy would be a real libc CALL per element -- an
 * artificial C-side handicap in a loop the DCDart side runs as one u32
 * load. The union compiles to the same single load.
 *
 * malloc is not NULL-checked, deliberately: DCDart traps on OOM, so a
 * baseline branching on every allocation would carry a check the DCDart
 * side does not have (same convention as string-pass).
 */

#include <stdint.h>
#include <stdlib.h>

/* Identical recurrence to bench.dart's fillBuf. Values are
 * (x % 256 - 128) / 64, exact in f32, in [-2, 2). */
static void fill_buf(float *dst, uint64_t n, uint64_t seed) {
    uint64_t x = seed;
    for (uint64_t i = 0; i < n; i++) {
        x = (x * 1103515245 + 12345) % 2147483648u;
        float v = (float)(uint32_t)(x % 256);
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
        uint64_t i_end = ii + blk;
        for (uint64_t kk = 0; kk < k; kk += blk) {
            uint64_t p_end = kk + blk;
            for (uint64_t jj = 0; jj < n; jj += blk) {
                uint64_t j_end = jj + blk;
                for (uint64_t i = ii; i < i_end; i++) {
                    for (uint64_t p = kk; p < p_end; p++) {
                        float av = a[i * k + p];
                        for (uint64_t j = jj; j < j_end; j++) {
                            c[i * n + j] = c[i * n + j] + av * b[p * n + j];
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
        acc = (acc * 31 + pun.u) % 1000000007;
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
        fill_buf(a, m * k, r * 2 + 1);
        fill_buf(b, k * n, r * 2 + 2);
        zero_buf(c, m * n);
        matmul_blocked(a, b, c, m, k, n);
        acc = fold_bits(c, m * n, acc);
    }

    free(a);
    free(b);
    free(c);
    return acc;
}
