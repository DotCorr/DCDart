/* core/bench/benchmarks/fib/kernel_trapck.c
 *
 * `fib`, in C, with DCDart's TRAPPING arithmetic semantics. Diagnostic second
 * baseline only -- see ../../harness/trapping.h for why it exists and why the
 * gate is still stated against kernel.c.
 */
#include <stdint.h>
#include "trapping.h"

static uint64_t fib(uint64_t n) {
    if (n < 2) return n;
    return add_ck(fib(sub_ck(n, 1)), fib(sub_ck(n, 2)));
}

uint64_t benchKernel(uint64_t arg) { return fib(arg); }
