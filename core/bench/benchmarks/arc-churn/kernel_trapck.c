/* core/bench/benchmarks/arc-churn/kernel_trapck.c
 *
 * `arc-churn`, in C, with DCDart's TRAPPING arithmetic semantics but STILL NO
 * ALLOCATOR AND NO REFCOUNT. Diagnostic second baseline only.
 *
 * That combination is the point: DCDart-vs-this isolates the cost of ARC plus
 * allocation with the arithmetic semantics held equal, which is the closest
 * this tree can currently get to the quantity M3 actually asks about. It is
 * still a microbenchmark and still not evidence about the gate -- see
 * manifest.sh.
 */
#include <stdint.h>
#include "trapping.h"

struct Cell {
    uint64_t v;
};

uint64_t benchKernel(uint64_t n) {
    uint64_t acc = 0;
    uint64_t x = 1;
    for (uint64_t i = 0; i < n; i = add_ck(i, 1)) {
        struct Cell c;
        c.v = add_ck(x, i);
        x = mod_ck(c.v, 1000003);
        acc = add_ck(acc, x);
    }
    return acc;
}
