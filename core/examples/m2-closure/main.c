/* Non-capturing closure harness (docs/decisions/0057-non-capturing-closures.md).
 *
 * Every function below was written with its callee INSIDE its own body. The
 * point of the checks is that this makes no observable difference: the values
 * are the ordinary ones, and the heap returns to baseline after the two
 * heap-using paths exactly as it does for the top-level-callee version.
 *
 * Baseline is `dc_heap_live == 0`. `dc_heap_live` (docs/decisions/0058) is the
 * segregated size-class heap's LIVE-object count -- incremented by Alloc,
 * decremented when a block goes back on its size class's free list -- so zero
 * means nothing at all is live, at any scale and in every size class.
 *
 * `viaTopLevel` and `viaClosure` are run against each other rather than only
 * against constants -- they are the same program written two ways, so they
 * must agree for every input, and both must be leak-free. The stronger half of
 * that claim (that they emit the IDENTICAL number of ARC operations) is
 * asserted on the IR by run.sh, because two programs can agree on every value
 * while one of them retains and releases twice as often.
 *
 * No stdio: on Linux/x86-64 this links `-nostdlib` (see
 * tests/conformance/_lib/hosted-link.sh), so the exit code is the whole
 * report. Codes are listed in run.sh's step 4.
 */
#include <stdint.h>

extern uint64_t dc_heap_live;

extern uint64_t twiceSum(uint64_t a, uint64_t b);
extern uint64_t addThree(uint64_t x);
extern uint64_t clampTo(uint64_t x, uint64_t hi);
extern uint64_t factorial(uint64_t n);
extern uint64_t pipeline(uint64_t x);
extern uint64_t viaTopLevel(uint64_t v);
extern uint64_t viaClosure(uint64_t v);
extern uint64_t makeViaTopLevel(uint64_t v);
extern uint64_t makeViaClosure(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    /* Shape 1 -- a named local function, two call sites, one hoisted symbol. */
    for (uint64_t a = 0; a < 40; a++) {
        for (uint64_t b = 0; b < 40; b++) {
            if (twiceSum(a, b) != 2 * a + 2 * b) return 2;
        }
    }

    /* Shape 2 -- an anonymous function expression bound to a final local. */
    for (uint64_t x = 0; x < 200; x++) {
        if (addThree(x) != x + 3) return 3;
    }

    /* Shape 3 -- a block body with a branch inside the hoisted function. */
    for (uint64_t x = 0; x < 30; x++) {
        for (uint64_t hi = 0; hi < 30; hi++) {
            uint64_t want = x > hi ? hi : x;
            if (clampTo(x, hi) != want) return 4;
        }
    }

    /* Shape 4 -- self-recursion inside a local function. 20! is the largest
       factorial that fits in 64 bits, so the loop stops there rather than
       walking into ADR-0009's overflow trap. */
    uint64_t want_fact = 1;
    for (uint64_t n = 0; n <= 20; n++) {
        if (n > 0) want_fact *= n;
        if (factorial(n) != want_fact) return 5;
    }

    /* Shape 5 -- one local function calling an earlier sibling. */
    for (uint64_t x = 0; x < 200; x++) {
        if (pipeline(x) != x + 2) return 6;
    }

    /* Shape 6 -- the ARC pair. Both must agree with each other AND with the
       input, and both must leave the heap exactly as they found it. The
       live count is checked after EVERY call, so a single leaked object per
       call is caught on the first iteration rather than having to accumulate
       until something runs out. */
    for (uint64_t v = 0; v < 500; v++) {
        uint64_t top = viaTopLevel(v);
        if (dc_heap_live != 0) return 7;
        uint64_t clo = viaClosure(v);
        if (dc_heap_live != 0) return 8;
        if (top != v || clo != v) return 9;
    }

    /* Shape 7 -- a local function that CONSTRUCTS the heap object. Ownership
       has to transfer out of it unreleased, exactly as out of a top-level
       function; if it did not, `b` would be retained once too often here and
       one object would leak per call and the live count would climb. */
    for (uint64_t v = 0; v < 500; v++) {
        uint64_t top = makeViaTopLevel(v);
        if (dc_heap_live != 0) return 10;
        uint64_t clo = makeViaClosure(v);
        if (dc_heap_live != 0) return 11;
        if (top != v || clo != v) return 12;
    }

    return 0;
}
