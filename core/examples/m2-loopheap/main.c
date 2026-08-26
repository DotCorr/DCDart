// Runtime half of the per-iteration ARC release policy (see loopheap.dart).
//
// WHAT THIS FILE HAS TO PROVE, and why "it ran" would not be it.
//
// A heap local declared in a loop body is a NEW object every iteration. If
// nothing releases the previous one before the variable is overwritten, the
// program leaks exactly one object per iteration -- a leak whose rate is the
// loop's trip count. So two independent assertions are made after EVERY call,
// and each catches a failure the other cannot:
//
//   1. `dc_heap_live` -- the allocator's live-object counter, a real symbol
//      in the object file, incremented on every Alloc and decremented on
//      every free -- is back at its pre-call baseline. This is an exact leak
//      assertion at any heap size, not an approximation: one object still
//      live after the call is a non-zero delta. It catches a DOUBLE free too,
//      since that decrements twice and drives the count BELOW baseline (it
//      wraps, so the equality still fails).
//
//   2. The computed VALUE is correct. A release placed one instruction too
//      early is a use-after-free, not a leak: the block goes back on the free
//      list, `dc_heap_live` stays perfectly balanced, and the next iteration
//      is handed the same memory while the previous iteration is still
//      reading it. Only the arithmetic catches that one.
//
// The loop counts are 1000 rather than something convenient because that is
// the regime where a per-iteration leak stops being subtle: 1000 iterations
// is 1000 allocations with a PEAK of one (two, for `nested`) live object,
// which is only true if every path out of every body released its own.
#include <stdint.h>

extern uint64_t dc_heap_live;

extern uint64_t liveChain(uint64_t n);
extern uint64_t forChain(uint64_t n);
extern uint64_t withContinue(uint64_t n);
extern uint64_t withBreak(uint64_t n, uint64_t stop);
extern uint64_t withReturn(uint64_t n, uint64_t stop);
extern uint64_t nested(uint64_t n);
extern uint64_t lastKept(uint64_t n);

static uint64_t sum_below(uint64_t n) { return n == 0 ? 0 : (n * (n - 1)) / 2; }

/* Captured rather than hardcoded to 0, so that this file keeps meaning the
 * same thing if the counter's baseline ever changes. What is hardcoded is the
 * thing that must be true for the harness to prove anything at all: nothing
 * is live before the first call. */
static uint64_t LIVE_BASELINE;

int main(void) {
    LIVE_BASELINE = dc_heap_live;
    if (LIVE_BASELINE != 0) return 1; /* something allocated before main */

    /* --- 1. Fall-through, 1000 iterations, one object each. ------------- */
    for (uint64_t n = 0; n <= 1000; n += (n < 8 ? 1 : 331)) {
        if (liveChain(n) != sum_below(n)) return 2;
        if (dc_heap_live != LIVE_BASELINE) return 3;
    }
    /* The headline case, spelled out rather than left to the stride above:
     * 1000 iterations, 1000 allocations, peak of ONE live object. */
    if (liveChain(1000) != 499500) return 4;
    if (dc_heap_live != LIVE_BASELINE) return 5;

    /* --- 2. The `for` form: release sits before the update block. ------- */
    for (uint64_t n = 0; n <= 1000; n += (n < 8 ? 1 : 331)) {
        if (forChain(n) != sum_below(n)) return 6;
        if (dc_heap_live != LIVE_BASELINE) return 7;
    }
    if (forChain(1000) != 499500) return 8;
    if (dc_heap_live != LIVE_BASELINE) return 9;

    /* --- 3. `continue`: allocates every iteration, skips half the work.
     * Half of 1000 iterations leave through the continue edge, so a release
     * missing from that path leaks 500 objects on the n == 1000 call, which
     * shows up as a 500-object delta on the live counter below. */
    for (uint64_t n = 0; n <= 1000; n += (n < 8 ? 1 : 331)) {
        uint64_t expected = 0;
        for (uint64_t i = 0; i < n; i += 2) expected += i;
        if (withContinue(n) != expected) return 10;
        if (dc_heap_live != LIVE_BASELINE) return 11;
    }
    if (dc_heap_live != LIVE_BASELINE) return 12;

    /* --- 4. `break`, including 1000 iterations that never break. -------- */
    for (uint64_t n = 0; n <= 200; n++) {
        for (uint64_t stop = 0; stop <= 200; stop += 37) {
            uint64_t limit = stop < n ? stop : n;
            if (withBreak(n, stop) != sum_below(limit)) return 13;
            if (dc_heap_live != LIVE_BASELINE) return 14;
        }
    }
    /* Never breaks: 1000 full iterations. */
    if (withBreak(1000, 100000) != 499500) return 15;
    if (dc_heap_live != LIVE_BASELINE) return 16;
    /* Breaks on the very first iteration, whose object is the one only the
     * break edge can release. */
    if (withBreak(1000, 0) != 0) return 17;
    if (dc_heap_live != LIVE_BASELINE) return 18;

    /* --- 5. `return` out of the body. ----------------------------------- */
    for (uint64_t n = 0; n <= 200; n++) {
        for (uint64_t stop = 0; stop <= 200; stop += 37) {
            uint64_t expected = stop < n ? sum_below(stop) + 1000 : sum_below(n);
            if (withReturn(n, stop) != expected) return 19;
            if (dc_heap_live != LIVE_BASELINE) return 20;
        }
    }
    if (withReturn(1000, 100000) != 499500) return 21;
    if (dc_heap_live != LIVE_BASELINE) return 22;
    if (withReturn(1000, 999) != sum_below(999) + 1000) return 23;
    if (dc_heap_live != LIVE_BASELINE) return 24;

    /* --- 6. Nested: peak live is 2, total allocations 50 + 2500. -------- */
    for (uint64_t n = 0; n <= 50; n++) {
        /* sum over i<n, j<n of (i + j) == 2 * n * sum_below(n) */
        if (nested(n) != 2 * n * sum_below(n)) return 25;
        if (dc_heap_live != LIVE_BASELINE) return 26;
    }

    /* --- 7. The object escapes the iteration through a loop-carried
     * variable. One release too many frees a live object and this reads
     * recycled memory; one too few leaks. 1000 iterations either way. */
    if (lastKept(0) != 777) return 27;
    if (dc_heap_live != LIVE_BASELINE) return 28;
    for (uint64_t n = 1; n <= 1000; n += (n < 8 ? 1 : 331)) {
        if (lastKept(n) != n - 1) return 29;
        if (dc_heap_live != LIVE_BASELINE) return 30;
    }
    if (lastKept(1000) != 999) return 31;
    if (dc_heap_live != LIVE_BASELINE) return 32;

    return 0;
}
