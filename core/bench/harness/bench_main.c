/* core/bench/harness/bench_main.c
 *
 * The timing driver. ONE file, linked identically against the DCDart object
 * and against the C object, so that whatever it costs, it costs both sides
 * the same amount.
 *
 * Contract with a benchmark: it exports exactly
 *
 *     uint64_t benchKernel(uint64_t arg);
 *
 * with C linkage, in its own translation unit. The DCDart side gets that for
 * free (a `@bare` function IS a C-ABI symbol). The C side must therefore also
 * live in its own .o and be linked, NOT #included -- see run-bench.sh. That is
 * not a stylistic choice: if the C kernel were in the same TU as this driver,
 * clang would inline it and constant-fold across the call, and DCDart, which
 * physically cannot be inlined into this file, would be racing a competitor
 * that had deleted the race. No -flto, for the same reason.
 *
 * Protocol (stdout, one key per line, parsed by run-bench.sh):
 *
 *     CHECKSUM <decimal>     the kernel's result, so every implementation of
 *                            a benchmark can be proved to compute the same
 *                            thing before any of their times are compared
 *     SAMPLE_NS <decimal>    one timed iteration
 *
 * Every process run performs ONE warmup iteration whose time is discarded,
 * then the requested number of timed iterations. run-bench.sh additionally
 * discards the whole FIRST process run of every configuration, so cold dyld,
 * cold page cache and first-touch faults land outside every reported number.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

extern uint64_t benchKernel(uint64_t arg);

#ifdef CLOCK_MONOTONIC_RAW
#define BENCH_CLOCK CLOCK_MONOTONIC_RAW
#define BENCH_CLOCK_NAME "CLOCK_MONOTONIC_RAW"
#else
#define BENCH_CLOCK CLOCK_MONOTONIC
#define BENCH_CLOCK_NAME "CLOCK_MONOTONIC"
#endif

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(BENCH_CLOCK, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Volatile sink: keeps the result observable so nothing about the call can be
 * elided even in the (impossible here, but cheap to guarantee) case that the
 * linker or a future LTO setting could see through it. */
static volatile uint64_t sink;

int main(int argc, char **argv) {
    uint64_t arg = 0;
    int iters = 1;

    if (argc > 1) arg = strtoull(argv[1], NULL, 10);
    if (argc > 2) iters = atoi(argv[2]);
    if (iters < 1) iters = 1;

    /* Warmup, discarded. */
    uint64_t warm = benchKernel(arg);
    sink = warm;

    uint64_t checksum = warm;
    for (int i = 0; i < iters; i++) {
        uint64_t t0 = now_ns();
        uint64_t r = benchKernel(arg);
        uint64_t t1 = now_ns();
        sink = r;
        if (r != checksum) {
            fprintf(stderr, "bench_main: kernel is not deterministic "
                            "(%llu then %llu) -- this benchmark cannot be "
                            "compared across implementations\n",
                    (unsigned long long)checksum, (unsigned long long)r);
            return 2;
        }
        printf("SAMPLE_NS %llu\n", (unsigned long long)(t1 - t0));
    }

    printf("CHECKSUM %llu\n", (unsigned long long)checksum);
    printf("CLOCK %s\n", BENCH_CLOCK_NAME);
    return 0;
}
