/* core/bench/benchmarks/arc-churn/kernel.c
 *
 * The C baseline for `arc-churn`, and the one baseline in this tree that
 * required a judgement call rather than a transcription. Stating it, because
 * the number this benchmark produces means nothing without it:
 *
 *   DCDart heap-allocates a `Cell` per iteration and releases it. C does not.
 *   C puts the value in a local and never touches an allocator.
 *
 * That is deliberate and it is what "overhead vs C" in ROADMAP.md M3 means. A
 * C programmer writing this loop does not call malloc and does not maintain a
 * reference count; comparing DCDart's ARC against a hand-rolled C refcount
 * would be comparing DCDart against a C nobody writes, and would flatter
 * DCDart by importing its costs into the baseline.
 *
 * The honest consequence is that this benchmark's ratio is a measure of "ARC
 * plus allocation, unamortised, on a loop with nothing else in it". It is not
 * a measure of what M3 is asking about. manifest.sh says so; run-bench.sh
 * excludes it from every geometric mean.
 */

#include <stdint.h>

struct Cell {
    uint64_t v;
};

uint64_t benchKernel(uint64_t n) {
    uint64_t acc = 0;
    uint64_t x = 1;
    for (uint64_t i = 0; i < n; i++) {
        struct Cell c;
        c.v = x + i;
        x = c.v % 1000003;
        acc = acc + x;
    }
    return acc;
}
