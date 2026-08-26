/* core/bench/benchmarks/collatz/kernel.c
 *
 * The C baseline for `collatz`. Same algorithm as bench.dart, expressed the
 * same way -- including `n >> 1` for the even step and `n + n + n + 1` for the
 * odd one rather than `n / 2` and `3 * n + 1`, so that neither side is handed
 * a different instruction sequence by its source spelling. (DCDart has `*` and
 * `~/` now; the shift-and-add spelling is kept on BOTH sides so the comparison
 * is of code generators, not of which operators each front end happens to
 * fold better.)
 */

#include <stdint.h>

static uint64_t collatzSteps(uint64_t start) {
    uint64_t n = start;
    uint64_t steps = 0;
    while (1 < n) {
        if ((n & 1) < 1) {
            n = n >> 1;
        } else {
            n = n + n + n + 1;
        }
        steps = steps + 1;
    }
    return steps;
}

uint64_t benchKernel(uint64_t arg) {
    uint64_t total = 0;
    for (uint64_t i = 1; i < arg + 1; i++) {
        total = total + collatzSteps(i);
    }
    return total;
}
