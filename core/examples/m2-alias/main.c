// M2 alias-retain harness (docs/decisions/0017-heap-alias-retain.md). Calls
// both real dcc-produced functions repeatedly and checks the arena's
// free-list count (`dc_free_top`, core/backend's M2 arena, docs/decisions/
// 0015) returns to baseline (64) after every single call. Before the
// aliasing Retain fix, `makeAliasAndReadValue` double-releases the same
// arena slot -- with only 64 slots, that corrupts the free list well before
// 1000 iterations (a slot pushed onto the free list twice gets handed out
// twice by a later Alloc, so two live objects would alias one slot and
// stomp each other's fields -- this harness's own value check catches that
// even if dc_free_top's count happens to look right).
#include <stdint.h>

extern uint32_t dc_free_top;
extern uint64_t makeAliasAndReadValue(uint64_t v);
extern uint64_t makeAliasBranch(uint64_t v);

int main(void) {
    if (dc_free_top != 64) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t result = makeAliasAndReadValue(i * 7);
        if (result != i * 7) return 2;      /* alias construction/read wrong */
        if (dc_free_top != 64) return 3;    /* leaked or double-freed */
    }

    /* Exercise both branches of makeAliasBranch: v < 500 takes the aliasing
       path, v >= 500 takes the no-alias path -- both must free exactly once. */
    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t v = (i % 2 == 0) ? (i % 500) : (500 + (i % 500));
        uint64_t result = makeAliasBranch(v);
        if (result != v) return 4;          /* branch construction/read wrong */
        if (dc_free_top != 64) return 5;    /* leaked or double-freed */
    }

    return 0;
}
