/* core/bench/harness/trapping.h
 *
 * C arithmetic with DCDart's semantics: every operation is checked and traps
 * on overflow (CLAUDE.md "Arithmetic traps by default"; there are no wrapping
 * `&+`/`&-`/`&*` operators in the prelude yet to opt out with).
 *
 * WHY THIS EXISTS. The first thing this harness measured was `fib`, a
 * benchmark with no heap and no ARC, and it came out at ~1.25x C rather than
 * the ~1.0x a self-test is supposed to produce. The instruction is to say so
 * rather than report it, so: it was chased down, and it is neither the harness
 * nor the flags.
 *
 * At -O2 LLVM turns C's `fib(n-1) + fib(n-2)` into ONE recursive call plus a
 * loop (the accumulator-recursion transform). It does not do that to DCDart's,
 * because DCDart's `+` is `llvm.uadd.with.overflow` followed by a branch to
 * `llvm.trap()`, and that is not an associative accumulator LLVM will hoist.
 * Compiling the SAME C source with __builtin_add_overflow/__builtin_trap
 * reproduces DCDart's machine code shape exactly -- two `bl`s, no loop.
 *
 * So the deviation is DCDart's trap semantics, not a measurement error. A
 * benchmark whose C baseline uses different arithmetic semantics is measuring
 * the semantics as much as the compiler, and on a 10% gate that matters.
 *
 * STATUS CHANGED 2026-08-26 (ADR-0059). This file was written as a DIAGNOSTIC
 * second baseline, with the comment "never the gate baseline" and the
 * reasoning that ROADMAP.md M3 says "the same algorithms in C" and the same
 * algorithm in C does not hand-roll overflow checks. That reasoning is sound
 * about what idiomatic C looks like and wrong about what the gate MEASURES.
 *
 * The owner decided: THE GATE BASELINE IS THIS FILE. M3's bar is stated as
 * ARC overhead, and a gate measured against idiomatic C silently charges
 * DCDart 25-50% on integer-heavy code for arithmetic semantics that have
 * nothing to do with ARC. The <= 10% bar is therefore measured against
 * matched semantics, and the trapping-arithmetic cost is published as its own
 * separate number rather than folded in or dropped.
 *
 * `kernel.c` stays, and its number stays published. It is what produces the
 * separate trapping figure, and the day that figure stops being reported this
 * choice becomes indistinguishable from having picked an easier baseline.
 */

#ifndef DCBENCH_TRAPPING_H
#define DCBENCH_TRAPPING_H

#include <stdint.h>

static inline uint64_t add_ck(uint64_t a, uint64_t b) {
    uint64_t r;
    if (__builtin_add_overflow(a, b, &r)) __builtin_trap();
    return r;
}

static inline uint64_t sub_ck(uint64_t a, uint64_t b) {
    uint64_t r;
    if (__builtin_sub_overflow(a, b, &r)) __builtin_trap();
    return r;
}

static inline uint64_t mul_ck(uint64_t a, uint64_t b) {
    uint64_t r;
    if (__builtin_mul_overflow(a, b, &r)) __builtin_trap();
    return r;
}

static inline uint64_t mod_ck(uint64_t a, uint64_t b) {
    if (b == 0) __builtin_trap();
    return a % b;
}

/* Added for `hashmap` (ADR-0061), whose era selector divides. DCDart's `~/`
 * traps on divide-by-zero (ADR-0036) and has no other failure mode for
 * unsigned operands -- there is no INT_MIN/-1 case to guard, since signed
 * division is refused outright (GAP-0024). */
static inline uint64_t div_ck(uint64_t a, uint64_t b) {
    if (b == 0) __builtin_trap();
    return a / b;
}

#endif /* DCBENCH_TRAPPING_H */
