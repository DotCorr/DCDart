/* core/bench/benchmarks/attention-f32/kernel.c
 *
 * The C baseline for `attention-f32`: single-head scaled-dot-product
 * attention, seq=96, d=64, f32 throughout. The IDENTICAL algorithm,
 * loop nests and arithmetic order as bench.dart, so every f32 value --
 * scores, softmax weights, output -- is bit-exact across the two sides
 * and the checksum (a modular fold of the output's raw IEEE bit patterns)
 * can demand equality rather than tolerance.
 *
 * EXP IS NOT LIBM'S. `exp_neg` below is the same range-reduced degree-6
 * polynomial bench.dart implements, statement for statement: DCDart ships
 * no transcendentals (GAP-0063 item 1) and implements exp as a polynomial
 * kernel in the language, so the matched baseline must run THAT
 * approximation, not expf -- libm is a different algorithm with different
 * rounding on almost every input, and the bit-exact checksum would refuse
 * the pair. Float constants are double literals cast to float, matching
 * DCDart's f32(lit) two-step rounding exactly. The (uint32_t) cast of
 * z*log2(e) matches DCDart's saturating toU32trunc because the operand is
 * in [0, ~126) by construction, where the two conversions agree.
 *
 * d=64 keeps the attention scale exact: 1/sqrt(64) = 0.125.
 *
 * Inputs are deterministic: matmul-f32's LCG, converted and scaled through
 * exact power-of-two arithmetic, re-seeded per round so no round's work
 * can be hoisted or cached across the repeat loop. The bit fold reads f32
 * storage as u32 through a union (C11 type punning) rather than memcpy:
 * under this harness's mandatory -fno-builtin, memcpy would be a real
 * libc CALL per element -- an artificial C-side handicap in a loop the
 * DCDart side runs as one u32 load.
 *
 * malloc is not NULL-checked, deliberately: DCDart traps on OOM, so a
 * baseline branching on every allocation would carry a check the DCDart
 * side does not have (same convention as string-pass).
 */

#include <stdint.h>
#include <stdlib.h>

/* FP CONTRACTION IS OFF, and it is load-bearing. clang's default
 * (-ffp-contract=on) fuses `a*b + c` into fmadd -- ONE rounding where
 * DCDart's emitted fmul+fadd round TWICE -- and the two sides then differ
 * by 1-2 ulp in exp_neg's Horner chain and the accumulations, which the
 * bit-exact checksum refuses (observed, not hypothesized: the mismatch was
 * measured before this pragma existed). The harness's flag list is fixed
 * (equal on both sides by construction), so the C11 pragma is the only
 * per-benchmark route. CONSEQUENCE, stated where the number will be read:
 * this C baseline foregoes real fmadd instructions, so attention-f32
 * under-prices DCDart's missing FP contraction relative to matmul-f32,
 * whose all-exact arithmetic lets its C baseline keep contraction. Read
 * the pair together; the manifest note says the same thing. */
#pragma STDC FP_CONTRACT OFF

/* Same LCG fill as matmul-f32: values (x % 256 - 128) / 64, exact in f32. */
static void fill_buf(float *dst, uint64_t n, uint64_t seed) {
    uint64_t x = seed;
    for (uint64_t i = 0; i < n; i++) {
        x = (x * 1103515245 + 12345) % 2147483648u;
        float v = (float)(uint32_t)(x % 256);
        dst[i] = (v - 128.0f) * 0.015625f;
    }
}

/* exp(x) for x <= 0 -- bench.dart's expNeg, statement for statement.
 * z = -x = k*ln2 + r, r in [0, ln2); e^x = 2^-k / e^r, with e^r from a
 * degree-6 Horner polynomial and 2^-k from k exact halvings. */
static float exp_neg(float x) {
    float z = -x;
    if (z >= 87.0f) {
        return 0.0f;
    }
    uint32_t k32 = (uint32_t)(z * (float)1.4426950408889634);
    float r = z - (float)k32 * (float)0.6931471805599453;
    float p = (float)0.001388888888888889;
    p = p * r + (float)0.008333333333333333;
    p = p * r + (float)0.041666666666666664;
    p = p * r + (float)0.16666666666666666;
    p = p * r + 0.5f;
    p = p * r + 1.0f;
    p = p * r + 1.0f;
    float pw = 1.0f;
    uint64_t k = k32;
    for (uint64_t i = 0; i < k; i++) {
        pw = pw * 0.5f;
    }
    return pw / p;
}

/* S[i,j] = 0.125 * sum_p Q[i,p] * K[j,p]; QK^T as a dot of rows. */
static void scores_qkt(const float *q, const float *kbuf, float *s,
                       uint64_t seq, uint64_t d) {
    for (uint64_t i = 0; i < seq; i++) {
        for (uint64_t j = 0; j < seq; j++) {
            float acc = 0.0f;
            for (uint64_t p = 0; p < d; p++) {
                acc = acc + q[i * d + p] * kbuf[j * d + p];
            }
            s[i * seq + j] = acc * 0.125f;
        }
    }
}

/* In-place row softmax with max subtraction; f32 row sum, matching
 * bench.dart exactly. */
static void softmax_rows(float *s, uint64_t rows, uint64_t cols) {
    for (uint64_t r = 0; r < rows; r++) {
        float *row = s + r * cols;

        float mx = row[0];
        for (uint64_t j = 1; j < cols; j++) {
            if (mx < row[j]) {
                mx = row[j];
            }
        }

        float sum = 0.0f;
        for (uint64_t j = 0; j < cols; j++) {
            float e = exp_neg(row[j] - mx);
            row[j] = e;
            sum = sum + e;
        }

        for (uint64_t j = 0; j < cols; j++) {
            row[j] = row[j] / sum;
        }
    }
}

/* O[i,j] = sum_p P[i,p] * V[p,j]; i-p-j order with P[i,p] hoisted. */
static void attn_v(const float *s, const float *v, float *o,
                   uint64_t seq, uint64_t d) {
    for (uint64_t i = 0; i < seq; i++) {
        for (uint64_t j = 0; j < d; j++) {
            o[i * d + j] = 0.0f;
        }
        for (uint64_t p = 0; p < seq; p++) {
            float pv = s[i * seq + p];
            for (uint64_t j = 0; j < d; j++) {
                o[i * d + j] = o[i * d + j] + pv * v[p * d + j];
            }
        }
    }
}

/* matmul-f32's bit fold: raw f32 bit patterns rolled modularly into u64. */
static uint64_t fold_bits(const float *buf, uint64_t n, uint64_t acc) {
    for (uint64_t i = 0; i < n; i++) {
        union { float f; uint32_t u; } pun;
        pun.f = buf[i];
        acc = (acc * 31 + pun.u) % 1000000007;
    }
    return acc;
}

uint64_t benchKernel(uint64_t rounds) {
    const uint64_t seq = 96, d = 64;
    float *q = malloc(seq * d * 4);
    float *kbuf = malloc(seq * d * 4);
    float *v = malloc(seq * d * 4);
    float *s = malloc(seq * seq * 4);
    float *o = malloc(seq * d * 4);

    uint64_t acc = 0;
    for (uint64_t r = 0; r < rounds; r++) {
        fill_buf(q, seq * d, r * 3 + 1);
        fill_buf(kbuf, seq * d, r * 3 + 2);
        fill_buf(v, seq * d, r * 3 + 3);
        scores_qkt(q, kbuf, s, seq, d);
        softmax_rows(s, seq, seq);
        attn_v(s, v, o, seq, d);
        acc = fold_bits(o, seq * d, acc);
    }

    free(q);
    free(kbuf);
    free(v);
    free(s);
    free(o);
    return acc;
}
