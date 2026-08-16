// M1 exit criterion harness, third clause: "returns Result<u64, Err> through
// ? propagation." Verified: the SysV ABI returns this project's
// `{tag: u64, payload: u64}` Result representation correctly in two
// registers -- confirmed empirically under real Linux/WSL, see
// docs/known-gaps.md GAP-0007 (resolved).
#include <stdint.h>

typedef struct {
    uint64_t tag;
    uint64_t payload;
} CResult;

extern CResult checkPositive(uint64_t value);
extern CResult doubleIfPositive(uint64_t value);
extern CResult alwaysPropagatesErr(uint64_t errCode);

int main(void) {
    CResult r1a = checkPositive(0);        /* value < 1 -> Err(999) */
    if (r1a.tag != 1 || r1a.payload != 999) return 1;

    CResult r1b = checkPositive(42);       /* value >= 1 -> Ok(42) */
    if (r1b.tag != 0 || r1b.payload != 42) return 2;

    CResult r2 = doubleIfPositive(7);      /* .propagate() Ok path -> Ok(7) */
    if (r2.tag != 0 || r2.payload != 7) return 3;

    CResult r3 = alwaysPropagatesErr(555); /* .propagate() Err path -> Err(555) */
    if (r3.tag != 1 || r3.payload != 555) return 4;

    return 0;
}
