// M2 heap-typed-field harness (docs/decisions/0020-heap-typed-fields.md,
// docs/decisions/0022-destructor-cascade.md). Originally (ADR-0020) this
// harness deliberately asserted a bounded, non-zero per-call leak: without
// a destructor, `BoxHolder`'s own Release freed its own block but could not
// cascade into releasing its `inner` Box field (GAP-0003). ADR-0022 added
// exactly that cascade (a direct destructor call through the object
// header's `cls` field, populated at Alloc time) -- this harness now
// asserts genuine, UNBOUNDED leak-freedom instead, which is the real proof
// that the cascade works: if the destructor under- or over-releases the
// `inner` field even once, `dc_heap_live` (the heap's live-object count,
// docs/decisions/0058) drifts off zero on that very call. Under-release
// leaves it above zero; over-release drives it below (and, being unsigned,
// straight to a huge number).
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t makeHolderAndReadInner(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t r = makeHolderAndReadInner(i * 11);
        if (r != i * 11) return 2;   /* nested construction/read wrong */
        if (dc_heap_live != 0) return 3; /* leaked (destructor under-released) or double-freed (over-released) */
    }

    return 0;
}
