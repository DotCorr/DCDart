// M2 recursion harness (docs/decisions/0026-recursion.md). At recursion
// depth n, up to n Box objects are simultaneously alive: EVERY recursive
// call happens while computing the CURRENT frame's own return expression
// (`v + sumBoxValues(n - u64(1))`), which evaluates before that frame's
// own Release fires -- so the whole call chain descends all the way to
// the base case, allocating a Box at every level, BEFORE any of them
// start releasing (in LIFO order, as the recursion unwinds).
//
// The old n <= 60 bound was 60 of ADR-0015's fixed 64 arena slots, left
// with headroom. The segregated size-class heap (docs/decisions/0058) holds
// 65,536 objects in this class, so that bound stopped meaning anything --
// and ADR-0058 named this target specifically as one that "could not have
// failed differently if the allocator had been far worse than it looked."
//
// So the sweep is kept for density at small depths, where an off-by-one in
// the unwind shows up, and DEEP SPOT CHECKS are added on top. 4000
// simultaneously-live objects is 62x what this could previously hold, and
// it is the first thing in this suite that would notice a heap that works
// at small N and not at large -- the exact property the old arena made
// untestable.
//
// Depths stay well inside the C stack: each frame is small, but the chain
// descends fully before any frame releases, so depth is real stack.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t sumBoxValues(uint64_t n);

static uint64_t expected_sum(uint64_t n) {
    return n * (n + 1) / 2;
}

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t n = 0; n <= 200; n++) {
        uint64_t result = sumBoxValues(n);
        if (result != expected_sum(n)) return 2;   /* recursion/arithmetic wrong */
        if (dc_heap_live != 0) return 3;           /* leaked or double-freed across the recursive chain */
    }

    /* Deep chains: each of these holds n objects alive simultaneously, far
     * beyond anything the old arena could represent. */
    static const uint64_t deep[] = {1000, 2000, 4000};
    for (unsigned i = 0; i < 3; i++) {
        uint64_t n = deep[i];
        uint64_t result = sumBoxValues(n);
        if (result != expected_sum(n)) return 4;   /* deep chain computed wrong */
        if (dc_heap_live != 0) return 5;           /* deep chain leaked or double-freed */
    }

    return 0;
}
