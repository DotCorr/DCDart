// M2 alias-retain harness (docs/decisions/0017-heap-alias-retain.md). Calls
// both real dcc-produced functions repeatedly and checks the heap's
// live-object count (`dc_heap_live`, core/backend's segregated size-class
// heap, docs/decisions/0058) is back at ZERO after every single call.
// Before the aliasing Retain fix, `makeAliasAndReadValue` double-releases
// the same block -- which pushes that block onto its size class's free list
// twice, so a later pair of Allocs hands the SAME memory out twice and two
// live objects stomp each other's fields. Both halves of that are caught
// here: the double push drives `dc_heap_live` below zero (it is unsigned,
// so it wraps to a huge number) on the very first iteration, and this
// harness's own value check catches the aliasing even if the count happened
// to look right.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t makeAliasAndReadValue(uint64_t v);
extern uint64_t makeAliasBranch(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t result = makeAliasAndReadValue(i * 7);
        if (result != i * 7) return 2;      /* alias construction/read wrong */
        if (dc_heap_live != 0) return 3;    /* leaked or double-freed */
    }

    /* Exercise both branches of makeAliasBranch: v < 500 takes the aliasing
       path, v >= 500 takes the no-alias path -- both must free exactly once. */
    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t v = (i % 2 == 0) ? (i % 500) : (500 + (i % 500));
        uint64_t result = makeAliasBranch(v);
        if (result != v) return 4;          /* branch construction/read wrong */
        if (dc_heap_live != 0) return 5;    /* leaked or double-freed */
    }

    return 0;
}
