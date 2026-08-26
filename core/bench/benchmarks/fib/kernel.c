/* core/bench/benchmarks/fib/kernel.c
 *
 * The C baseline for `fib`. Line-for-line the same algorithm as bench.dart:
 * same recursion, same base case, same argument type.
 *
 * Compiled into its OWN object file with the exact flag list DCDart compiles
 * its emitted IR with (run-bench.sh takes that list from
 * bench/tool/dcbuild.dart, which is itself checked byte-for-byte against
 * `dcc build`). It is never #included into bench_main.c, so clang cannot
 * inline it into the timing loop -- DCDart physically cannot be inlined
 * there, and a baseline that can is not a baseline.
 *
 * DELIBERATELY NOT MATCHED: DCDart's `+` and `-` are checked and trap on
 * overflow; C's are not. Making the C side check too would measure a C
 * nobody writes. The asymmetry is real, it is in DCDart's favour to hide it,
 * so it is stated here and in the manifest instead.
 */

#include <stdint.h>

static uint64_t fib(uint64_t n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

uint64_t benchKernel(uint64_t arg) { return fib(arg); }
