// M2 function-call harness (docs/decisions/0018-function-calls.md). Result
// representation (SysV two-register struct return) matches m1-result/main.c
// exactly -- already verified correct there (docs/known-gaps.md GAP-0007).
#include <stdint.h>

typedef struct {
    uint64_t tag;
    uint64_t payload;
} CResult;

extern uint64_t doubleValue(uint64_t x);
extern uint64_t addAndDouble(uint64_t a, uint64_t b);
extern CResult checkPositive(uint64_t x);
extern CResult validateAndDouble(uint64_t x);

int main(void) {
    for (uint64_t i = 0; i < 500; i++) {
        if (doubleValue(i) != i * 2) return 1;
        if (addAndDouble(i, i + 1) != (i + i + 1) * 2) return 2;
    }

    CResult a = checkPositive(0);   /* x < 1 -> Err(999) */
    if (a.tag != 1 || a.payload != 999) return 3;

    CResult b = checkPositive(42);  /* x >= 1 -> Ok(42) */
    if (b.tag != 0 || b.payload != 42) return 4;

    CResult c = validateAndDouble(0);  /* checkPositive fails -> propagate()'s Err path */
    if (c.tag != 1 || c.payload != 999) return 5;

    for (uint64_t i = 1; i < 500; i++) {
        CResult d = validateAndDouble(i); /* checkPositive ok -> doubled */
        if (d.tag != 0 || d.payload != i * 2) return 6;
    }

    return 0;
}
