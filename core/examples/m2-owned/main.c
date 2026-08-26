// M2 @owned-parameter harness (docs/decisions/0021-owned-parameters.md).
// Two UNBOUNDED leak-free loops -- unlike every earlier M2 heap-signature
// target (m2-heap-param, m2-heap-field), which had to stop at a bounded
// call count because nothing could release a reference it didn't itself
// construct. @owned is exactly that missing release mechanism, so both
// loops below must return `dc_heap_live` (the heap's live-object count,
// docs/decisions/0058) to ZERO on every single call: one object is
// constructed per iteration and exactly one release must retire it.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern void *makeBox(uint64_t v);
extern uint64_t dropBoxAndReadValue(void *b);
extern uint64_t makeAndDropViaCall(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    /* Path 1: C constructs, then directly hands ownership to a consuming
       function -- no DCDart-side caller ever retains (there isn't one),
       matching @owned's contract exactly: exactly one strong reference
       exists throughout, and dropBoxAndReadValue's own Release frees it. */
    for (uint64_t i = 0; i < 500; i++) {
        void *b = makeBox(i * 3);
        uint64_t v = dropBoxAndReadValue(b);
        if (v != i * 3) return 2;
        if (dc_heap_live != 0) return 3; /* leaked or double-freed */
    }

    /* Path 2: a DCDart function keeps its own local alive across a call
       that ALSO takes ownership -- exercises the caller-side Retain
       (ADR-0021) that keeps both references independently correct. A
       missing caller-side Retain over-releases and drives the count below
       zero; a spurious one leaves it above. */
    for (uint64_t i = 0; i < 500; i++) {
        uint64_t v = makeAndDropViaCall(i * 7);
        if (v != i * 7) return 4;
        if (dc_heap_live != 0) return 5; /* leaked or double-freed */
    }

    return 0;
}
