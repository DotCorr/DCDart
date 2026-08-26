// M2 recursion harness (docs/decisions/0026-recursion.md). At recursion
// depth n, up to n Box objects are simultaneously alive: EVERY recursive
// call happens while computing the CURRENT frame's own return expression
// (`v + sumBoxValues(n - u64(1))`), which evaluates before that frame's
// own Release fires -- so the whole call chain descends all the way to
// the base case, allocating a Box at every level, BEFORE any of them
// start releasing (in LIFO order, as the recursion unwinds).
//
// The n <= 60 bound is historical: it was 60 of the old fixed arena's 64
// slots (ADR-0015), left with headroom. The segregated size-class heap
// (docs/decisions/0058) holds 65,536 objects in this size class, so the
// bound no longer has anything to do with capacity -- what this target
// still proves is that a chain of simultaneously-live objects is released
// exactly once each as the recursion unwinds, which `dc_heap_live` (the
// heap's live-object count) returning to ZERO after every call asserts
// directly, rather than by the old proxy of "every slot is free again".
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t sumBoxValues(uint64_t n);

static uint64_t expected_sum(uint64_t n) {
    return n * (n + 1) / 2;
}

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t n = 0; n <= 60; n++) {
        uint64_t result = sumBoxValues(n);
        if (result != expected_sum(n)) return 2;   /* recursion/arithmetic wrong */
        if (dc_heap_live != 0) return 3;           /* leaked or double-freed across the recursive chain */
    }

    return 0;
}
