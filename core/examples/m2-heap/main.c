// M2 exit criterion harness: "allocation-heavy programs run leak-free under
// dc-test --leakcheck." Calls the real dcc-produced function 1000 times and
// checks the arena's free-list count (`dc_free_top`, a real symbol in the
// object file -- core/backend's M2 arena, docs/decisions/0015) returns to
// its starting value (64, full capacity) after every single call. If any
// allocation were leaked (or double-freed), this would drift or crash well
// before 1000 iterations given the arena only has 64 slots.
#include <stdint.h>

extern uint32_t dc_free_top;
extern uint64_t makeBoxAndReadValue(uint64_t v);

int main(void) {
    if (dc_free_top != 64) return 1; /* not at baseline before any call */

    for (uint64_t i = 0; i < 1000; i++) {
        uint64_t result = makeBoxAndReadValue(i * 7);
        if (result != i * 7) return 2;      /* field construction/read wrong */
        if (dc_free_top != 64) return 3;    /* leaked (or double-freed) */
    }

    return 0;
}
