// M2 real-loop-control-flow harness (docs/decisions/0028-while-loop.md).
// Pure scalar arithmetic, no heap involved -- no dc_free_top check needed,
// just correctness of both loop-carried-variable threading and a nested
// early-return inside a loop body.
#include <stdint.h>

extern uint64_t sumTo(uint64_t n);
extern uint64_t firstAtLeast(uint64_t n, uint64_t threshold);

int main(void) {
    for (uint64_t n = 0; n < 50; n++) {
        uint64_t expected = n == 0 ? 0 : (n * (n - 1)) / 2;
        if (sumTo(n) != expected) return 1;
    }

    for (uint64_t n = 1; n < 20; n++) {
        for (uint64_t threshold = 0; threshold < 100; threshold += 7) {
            uint64_t total = 0;
            uint64_t expected = n; /* never crossed: loop runs to i == n */
            for (uint64_t i = 0; i < n; i++) {
                total += i;
                if (threshold < total) {
                    expected = i;
                    break;
                }
            }
            if (firstAtLeast(n, threshold) != expected) return 2;
        }
    }

    return 0;
}
