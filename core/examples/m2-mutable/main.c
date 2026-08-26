// M2 scalar-reassignment harness (docs/decisions/0027-scalar-
// reassignment.md). Pure scalar arithmetic, no heap involved -- no
// `dc_heap_live` check needed (the heap globals, docs/decisions/0058, are
// only emitted for a module that actually allocates, so the symbol does not
// even exist here), just correctness.
#include <stdint.h>

extern uint64_t mutateStraightLine(uint64_t v);
extern uint64_t mutateInBranch(uint64_t v);

int main(void) {
    for (uint64_t v = 0; v < 200; v++) {
        if (mutateStraightLine(v) != v + 2) return 1;
    }

    for (uint64_t v = 0; v < 200; v++) {
        uint64_t expected = (v < 10) ? v + 100 : v;
        if (mutateInBranch(v) != expected) return 2;
    }

    return 0;
}
