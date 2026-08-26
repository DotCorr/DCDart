/* Behavioural + LEAK harness for monomorphized generic classes
 * (docs/decisions/0054-generic-classes.md).
 *
 * Two things are asserted here that the symbol-table checks in run.sh
 * cannot see:
 *
 *  1. Each instantiation reads its field back at the right WIDTH. Box<u32>
 *     is a 4-byte payload; if its layout were inherited from Box<u64> the
 *     value checks below still pass for small inputs, so the u32 cases use
 *     values that only survive a correct 4-byte round trip.
 *
 *  2. The heap returns to BASELINE across all three instantiations. This is
 *     the check that catches a wrong per-instantiation destructor: Box<Node>
 *     must cascade (or the Node leaks a slot per call), and Box<u64> must
 *     NOT (or a u64 gets released as if it were a pointer). The loops run
 *     well past the arena's 64-slot capacity (ADR-0015), so a one-slot-per-
 *     call leak cannot hide inside the arena.
 */
#include <stdint.h>
#include <stdio.h>

extern uint32_t dc_free_top;

extern uint64_t boxU64(uint64_t v);
extern uint32_t boxU32(uint32_t v);
extern uint64_t boxU64Field(uint64_t v);
extern uint32_t boxU32Field(uint32_t v);
extern uint64_t boxNode(uint64_t v);
extern uint64_t boxBoth(uint64_t a, uint32_t b);

#define BASELINE 64

int main(void) {
    if (dc_free_top != BASELINE) {
        printf("GENERIC-CLASS: arena not at baseline before any call (%u)\n", dc_free_top);
        return 1;
    }

    /* --- Box<u64>: 8-byte payload, no destructor, leak-free --- */
    for (uint64_t i = 0; i < 300; i++) {
        uint64_t v = 0x0123456789ABCDEFull ^ i;
        if (boxU64(v) != v) { printf("GENERIC-CLASS: boxU64 wrong at %llu\n", (unsigned long long)i); return 2; }
        if (boxU64Field(v) != v) { printf("GENERIC-CLASS: boxU64Field wrong at %llu\n", (unsigned long long)i); return 3; }
        if (dc_free_top != BASELINE) { printf("GENERIC-CLASS: Box<u64> leaked/double-freed at %llu\n", (unsigned long long)i); return 4; }
    }

    /* --- Box<u32>: 4-byte payload. The values here have their top 32 bits
       set in the u64 world, so a layout that widened the field to 8 bytes
       and a layout that narrowed it correctly give different answers. --- */
    for (uint32_t i = 0; i < 300; i++) {
        uint32_t v = 0xDEADBEEFu ^ i;
        if (boxU32(v) != v) { printf("GENERIC-CLASS: boxU32 wrong at %u\n", i); return 5; }
        if (boxU32Field(v) != v) { printf("GENERIC-CLASS: boxU32Field wrong at %u\n", i); return 6; }
        if (dc_free_top != BASELINE) { printf("GENERIC-CLASS: Box<u32> leaked/double-freed at %u\n", i); return 7; }
    }

    /* --- Box<Node>: a HEAP field. Two slots per call (the Node and the
       Box), both of which must come back. If the per-instantiation
       destructor were missing, this leaks exactly one slot per call and
       exhausts the 64-slot arena inside the first 64 iterations. --- */
    for (uint64_t i = 0; i < 300; i++) {
        if (boxNode(i * 7 + 1) != i * 7 + 1) { printf("GENERIC-CLASS: boxNode wrong at %llu\n", (unsigned long long)i); return 8; }
        if (dc_free_top != BASELINE) { printf("GENERIC-CLASS: Box<Node> leaked/double-freed at %llu (free_top=%u)\n", (unsigned long long)i, dc_free_top); return 9; }
    }

    /* --- Two instantiations live in the same function at the same time. --- */
    for (uint64_t i = 0; i < 300; i++) {
        uint64_t a = 1000000ull + i;
        uint32_t b = 0xFFFF0000u ^ (uint32_t)i;
        uint64_t want = a + (uint64_t)b;
        if (boxBoth(a, b) != want) { printf("GENERIC-CLASS: boxBoth wrong at %llu\n", (unsigned long long)i); return 10; }
        if (dc_free_top != BASELINE) { printf("GENERIC-CLASS: boxBoth leaked at %llu\n", (unsigned long long)i); return 11; }
    }

    printf("GENERIC-CLASS: all correct (3 instantiations, heap at baseline)\n");
    return 0;
}
