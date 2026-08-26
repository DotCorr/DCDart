// M2 heap-typed-signature harness (docs/decisions/0019-heap-typed-
// signatures.md). Two things checked, deliberately kept separate:
//
// 1. Borrowed parameters (makeAndReadViaCall -> readBoxValue) run 1000
//    real cycles checked against `dc_heap_live` every time -- this path is
//    fully leak-test-loopable because the passed object's own lifecycle
//    never leaves the caller's scope.
// 2. Returning a heap pointer (makeBox) transfers ownership OUT,
//    unreleased -- there is no "consuming" parameter convention yet
//    (docs/known-gaps.md GAP-0017 remains open on this point), so this
//    harness only proves construction/return/read correctness over a
//    BOUNDED number of calls (60) rather than claiming a full alloc/free
//    cycle that doesn't exist yet. The bound is there because this loop
//    LEAKS BY DESIGN -- one object stays live per iteration and nothing
//    can release it -- not because the heap is small; it is now 65,536
//    objects deep in this size class (docs/decisions/0058). Do not read
//    the passing bounded loop as "leak-free" for this specific function --
//    see the ADR for exactly what is and isn't proven.
//
// `dc_heap_live` (docs/decisions/0058) is the heap's live-object count: a
// real symbol in the object file, incremented by Alloc and decremented when
// a block goes back on its size class's free list. Zero means nothing is
// live; the second loop's check is the DIRECT form of "ownership transferred
// out and stayed out" -- after the i-th call exactly i+1 objects are live.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t readBoxValue(void *b);
extern uint64_t makeAndReadViaCall(uint64_t v);
extern void *makeBox(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t r = makeAndReadViaCall(i * 3);
        if (r != i * 3) return 2;          /* borrowed-call construction/read wrong */
        if (dc_heap_live != 0) return 3;   /* borrowed call disturbed the refcount */
    }

    for (uint64_t i = 0; i < 60; i++) {
        void *b = makeBox(i * 5);
        if (dc_heap_live != i + 1) return 4; /* ownership didn't transfer out as expected */
        uint64_t v = readBoxValue(b);
        if (v != i * 5) return 5;            /* returned pointer reads back wrong */
    }

    return 0;
}
