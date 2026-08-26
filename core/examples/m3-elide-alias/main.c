/* GAP-0054 / ADR-0063 harness.
 *
 * READ THIS BEFORE ADDING A LEAK CHECK AND CALLING IT SUFFICIENT: the bug
 * this target exists for does not leak. Deleting a retain/release pair is
 * refcount-neutral, so `dc_heap_live` returned to zero on every call while
 * `aliasBug` was reading freed memory. The leak assertion below is still
 * here -- it is what catches the OPPOSITE mistake, a fix that over-retains
 * -- but it is not what catches the miscompilation. The VALUE assertions
 * are.
 *
 * The number to know is 198. `aliasBug` allocates a Node holding 198 after
 * the premature free, which takes the just-freed slot off the free list and
 * writes 198 over the payload that `got` still points at. Before the fix
 * this program returned 198; the correct answer is 110. If this ever prints
 * 198 again, pass 3 has regressed to eliding across an aliasing Release.
 */
#include <stdint.h>
#include <stdio.h>

extern uint64_t dc_heap_live;

extern uint64_t aliasBug(uint64_t v);
extern uint64_t aliasBugNullable(uint64_t v);
extern uint64_t stillElided(uint64_t v);
extern uint64_t releaseThroughDestructor(uint64_t v);

static int check(const char *name, uint64_t got, uint64_t want, int code) {
    if (got != want) {
        printf("FAIL %s: got %llu, want %llu%s\n", name,
               (unsigned long long)got, (unsigned long long)want,
               got == 198 ? "  <-- 198 is the recycled slot: the ARC pair was elided across an aliasing Release (GAP-0054)" : "");
        return code;
    }
    return 0;
}

int main(void) {
    int rc;

    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    /* Many iterations, not one: the arena is small and a premature free
     * only becomes a visibly wrong value once the slot is handed back out.
     * Repeating also proves the pair is balanced rather than merely lucky
     * on the first pass through a fresh heap. */
    for (uint64_t i = 0; i < 1000; i++) {
        if ((rc = check("aliasBug", aliasBug(110), 110, 2))) return rc;
        if (dc_heap_live != 0) return 3;

        if ((rc = check("aliasBugNullable", aliasBugNullable(110), 110, 4))) return rc;
        if (dc_heap_live != 0) return 5;

        if ((rc = check("stillElided", stillElided(110), 110, 6))) return rc;
        if (dc_heap_live != 0) return 7;

        if ((rc = check("releaseThroughDestructor", releaseThroughDestructor(110), 110, 8))) return rc;
        if (dc_heap_live != 0) return 9;
    }

    /* Vary the payload so a fix that happened to make 110 appear for an
     * unrelated reason (a constant folded through, a slot that always holds
     * 110) does not pass. */
    for (uint64_t v = 0; v < 512; v++) {
        if ((rc = check("aliasBug/varied", aliasBug(v), v, 10))) return rc;
        if ((rc = check("releaseThroughDestructor/varied", releaseThroughDestructor(v), v, 11))) return rc;
        if (dc_heap_live != 0) return 12;
    }

    return 0;
}
