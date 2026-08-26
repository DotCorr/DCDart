/* core/bench/benchmarks/collatz/kernel_trapck.c
 *
 * `collatz`, in C, with DCDart's TRAPPING arithmetic semantics. Diagnostic
 * second baseline only -- see ../../harness/trapping.h.
 *
 * `>>` and `&` are not checked in DCDart either (no overflow is possible), so
 * they are spelled plainly here, exactly as the emitted IR has them.
 */
#include <stdint.h>
#include "trapping.h"

static uint64_t collatzSteps(uint64_t start) {
    uint64_t n = start;
    uint64_t steps = 0;
    while (1 < n) {
        if ((n & 1) < 1) {
            n = n >> 1;
        } else {
            n = add_ck(add_ck(add_ck(n, n), n), 1);
        }
        steps = add_ck(steps, 1);
    }
    return steps;
}

uint64_t benchKernel(uint64_t arg) {
    uint64_t total = 0;
    for (uint64_t i = 1; i < add_ck(arg, 1); i = add_ck(i, 1)) {
        total = add_ck(total, collatzSteps(i));
    }
    return total;
}
