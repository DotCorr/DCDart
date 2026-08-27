/* core/bench/benchmarks/attention-f32/kernel_trapck.c
 *
 * `attention-f32` in C with DCDart's TRAPPING arithmetic on the INTEGER
 * operations. Derived line-by-line from THIS benchmark's kernel.c -- the
 * only differences are *_ck routings (diff the two files to check; nothing
 * else may differ, or the attribution table lies).
 *
 * THE ASYMMETRY THIS FILE CANNOT REMOVE, per neon/ROADMAP.md N2's caveat:
 * FLOATING-POINT ARITHMETIC DOES NOT TRAP, in DCDart or anywhere else
 * (ADR-0065: IEEE semantics, no overflow checks), so every FMul/FAdd and
 * the whole exp_neg polynomial below stay plain and only the u64
 * index/LCG/checksum arithmetic is routed through trapping.h. On this
 * float-dominated kernel the Ctrap/C delta is therefore expected to be
 * much smaller than on fib-shaped integer code -- a property of the
 * workload, not a flattering baseline choice; the manifest says so where
 * the numbers will be read.
 *
 * Loop-header increments stay plain, matching the convention of every
 * existing kernel_trapck.c in this tree (string-pass, tree-traversal,
 * hashmap); all other integer arithmetic -- index expressions, row bases,
 * the LCG, the seeds, the checksum fold -- is routed.
 *
 * (Original notes, true of both files: exp is bench.dart's polynomial, not
 * libm's -- see kernel.c's header; d=64 keeps the scale exact at 0.125;
 * inputs from the shared LCG with exact power-of-two scaling; union type
 * punning for the bit fold because -fno-builtin makes memcpy a real call;
 * malloc not NULL-checked, matching DCDart's trap-on-OOM.)
 */

#include <stdint.h>
#include <stdlib.h>
#include "trapping.h"

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
        x = mod_ck(add_ck(mul_ck(x, 1103515245), 12345), 2147483648u);
        float v = (float)(uint32_t)mod_ck(x, 256);
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
                acc = acc + q[add_ck(mul_ck(i, d), p)]
                          * kbuf[add_ck(mul_ck(j, d), p)];
            }
            s[add_ck(mul_ck(i, seq), j)] = acc * 0.125f;
        }
    }
}

/* In-place row softmax with max subtraction; f32 row sum, matching
 * bench.dart exactly. */
static void softmax_rows(float *s, uint64_t rows, uint64_t cols) {
    for (uint64_t r = 0; r < rows; r++) {
        float *row = s + mul_ck(r, cols);

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
            o[add_ck(mul_ck(i, d), j)] = 0.0f;
        }
        for (uint64_t p = 0; p < seq; p++) {
            float pv = s[add_ck(mul_ck(i, seq), p)];
            for (uint64_t j = 0; j < d; j++) {
                o[add_ck(mul_ck(i, d), j)] = o[add_ck(mul_ck(i, d), j)]
                                             + pv * v[add_ck(mul_ck(p, d), j)];
            }
        }
    }
}

/* matmul-f32's bit fold: raw f32 bit patterns rolled modularly into u64. */
static uint64_t fold_bits(const float *buf, uint64_t n, uint64_t acc) {
    for (uint64_t i = 0; i < n; i++) {
        union { float f; uint32_t u; } pun;
        pun.f = buf[i];
        acc = mod_ck(add_ck(mul_ck(acc, 31), pun.u), 1000000007);
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
        fill_buf(q, mul_ck(seq, d), add_ck(mul_ck(r, 3), 1));
        fill_buf(kbuf, mul_ck(seq, d), add_ck(mul_ck(r, 3), 2));
        fill_buf(v, mul_ck(seq, d), add_ck(mul_ck(r, 3), 3));
        scores_qkt(q, kbuf, s, seq, d);
        softmax_rows(s, seq, seq);
        attn_v(s, v, o, seq, d);
        acc = fold_bits(o, mul_ck(seq, d), acc);
    }

    free(q);
    free(kbuf);
    free(v);
    free(s);
    free(o);
    return acc;
}
