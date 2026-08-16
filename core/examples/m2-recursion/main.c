// M2 recursion harness (docs/decisions/0026-recursion.md). At recursion
// depth n, up to n Box objects are simultaneously alive: EVERY recursive
// call happens while computing the CURRENT frame's own return expression
// (`v + sumBoxValues(n - u64(1))`), which evaluates before that frame's
// own Release fires -- so the whole call chain descends all the way to
// the base case, allocating a Box at every level, BEFORE any of them
// start releasing (in LIFO order, as the recursion unwinds). Bounded to
// n <= 60 (of the 64-slot arena, docs/decisions/0015) on purpose, leaving
// headroom, rather than exhausting it.
#include <stdint.h>

extern uint32_t dc_free_top;
extern uint64_t sumBoxValues(uint64_t n);

static uint64_t expected_sum(uint64_t n) {
    return n * (n + 1) / 2;
}

int main(void) {
    if (dc_free_top != 64) return 1; /* not at baseline before any call */

    for (uint64_t n = 0; n <= 60; n++) {
        uint64_t result = sumBoxValues(n);
        if (result != expected_sum(n)) return 2;   /* recursion/arithmetic wrong */
        if (dc_free_top != 64) return 3;            /* leaked or double-freed across the recursive chain */
    }

    return 0;
}
