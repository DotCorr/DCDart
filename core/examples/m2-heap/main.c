// M2 exit criterion harness: "allocation-heavy programs run leak-free under
// dc-test --leakcheck." Calls the real dcc-produced function 1000 times and
// checks the heap's live-object count (`dc_heap_live`, a real symbol in the
// object file -- core/backend's segregated size-class heap,
// docs/decisions/0058) is back at ZERO after every single call. Alloc
// increments it, returning a block to a free list decrements it, so
// `dc_heap_live == 0` is exactly "nothing is live" -- at any scale and
// across every size class. If any allocation were leaked (or double-freed),
// the count would drift on the very first iteration, not merely once the
// heap filled up.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t makeBoxAndReadValue(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t result = makeBoxAndReadValue(i * 7);
        if (result != i * 7) return 2;      /* field construction/read wrong */
        if (dc_heap_live != 0) return 3;    /* leaked (or double-freed) */
    }

    return 0;
}
