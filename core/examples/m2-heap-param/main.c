// M2 heap-typed-signature harness (docs/decisions/0019-heap-typed-
// signatures.md). Two things checked, deliberately kept separate:
//
// 1. Borrowed parameters (makeAndReadViaCall -> readBoxValue) run 1000
//    real cycles checked against dc_free_top every time -- this path is
//    fully leak-test-loopable because the passed object's own lifecycle
//    never leaves the caller's scope.
// 2. Returning a heap pointer (makeBox) transfers ownership OUT,
//    unreleased -- there is no "consuming" parameter convention yet
//    (docs/known-gaps.md GAP-0017 remains open on this point), so this
//    harness only proves construction/return/read correctness over a
//    BOUNDED number of calls (60 of the arena's 64 slots, leaving
//    headroom) rather than claiming a full alloc/free cycle that doesn't
//    exist yet. Do not read the passing bounded loop as "leak-free" for
//    this specific function -- see the ADR for exactly what is and isn't
//    proven.
#include <stdint.h>

extern uint32_t dc_free_top;
extern uint64_t readBoxValue(void *b);
extern uint64_t makeAndReadViaCall(uint64_t v);
extern void *makeBox(uint64_t v);

int main(void) {
    if (dc_free_top != 64) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t r = makeAndReadViaCall(i * 3);
        if (r != i * 3) return 2;          /* borrowed-call construction/read wrong */
        if (dc_free_top != 64) return 3;   /* borrowed call disturbed the refcount */
    }

    for (uint64_t i = 0; i < 60; i++) {
        void *b = makeBox(i * 5);
        if (dc_free_top != 64 - (i + 1)) return 4; /* ownership didn't transfer out as expected */
        uint64_t v = readBoxValue(b);
        if (v != i * 5) return 5;                  /* returned pointer reads back wrong */
    }

    return 0;
}
