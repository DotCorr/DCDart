// M2 weak-reference harness (docs/decisions/0023-weak-references.md).
// Two things checked, both over real, UNBOUNDED cycles:
//
// 1. Dangling: makeDanglingWeak's Box dies before the caller even sees
//    the weak reference (naive release-at-return, ADR-0016 -- see the
//    .dart file's own comment on why this is the only way to force early
//    death with the primitives built so far). Checks the exact "zombie
//    block" mechanics (docs/decisions/0023): the block stays reserved
//    (strong==0, weak==1, NOT on a free list) until readWeak drops the
//    weak reference too, at which point it finally frees.
// 2. Alive: weakLoadWhileAlive proves the opposite path of the identical
//    mechanism -- a weak reference to a still-alive object correctly
//    retains and returns the live pointer.
//
// The counter read here is `dc_heap_live` (docs/decisions/0058): the heap's
// LIVE-object count, incremented by Alloc and decremented only when a block
// is pushed onto its size class's free list. That last detail is what makes
// it the right instrument for the zombie check -- a zombie is precisely a
// block that has been Released but NOT pushed back, so it still counts as
// live. The checks below are therefore exact counts (1 = the zombie or the
// returned strong reference is the one and only live object), not baselines.
// Read the direction carefully: the count goes UP for a held object, where
// the old fixed-arena harness watched a free-slot count go DOWN.
#include <stdint.h>

extern uint64_t dc_heap_live;
extern uint64_t dropBox(void *b);
extern void *makeDanglingWeak(uint64_t v);
extern void *readWeak(void *w);
extern void *weakLoadWhileAlive(uint64_t v);

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 500; i++) {
        void *w = makeDanglingWeak(i);
        if (dc_heap_live != 1) return 2;   /* zombie block: Box died, but weak ref still holds it reserved */

        void *result = readWeak(w);
        if (result != 0) return 3;         /* should be dead -- must nil out */
        if (dc_heap_live != 0) return 4;   /* zombie block must finally free once weak also drops */
    }

    for (uint64_t i = 0; i < 500; i++) {
        void *result = weakLoadWhileAlive(i * 3);
        if (result == 0) return 5;         /* should be alive */
        if (dc_heap_live != 1) return 6;   /* one object held by the returned strong reference */

        uint64_t v = dropBox(result);
        if (v != i * 3) return 7;
        if (dc_heap_live != 0) return 8;   /* fully released now */
    }

    return 0;
}
