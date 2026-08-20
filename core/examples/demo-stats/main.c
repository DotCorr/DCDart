/* An ordinary hosted C program. C owns the buffer -- allocates it, fills
 * it, frees it. DCDart only ever receives its address and walks it with
 * pointer arithmetic, owning nothing. That is the @bare/C division of
 * responsibility from DCDART_SPEC.md §6, exercised for real.
 *
 * Declarations come from the generated header (dcc --emit-header), not
 * hand-written externs -- see docs/decisions/0034-c-header-emission.md. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "stats.h"

int main(void) {
    enum { N = 10 };
    uint32_t *data = malloc(N * sizeof(uint32_t));
    if (!data) return 2;
    /* 7 19 3 42 8 100 55 1 77 23 -> sum 335, mean 33, max 100,
     * count>20 is {42,100,55,77,23} = 5 */
    static const uint32_t seed[N] = {7, 19, 3, 42, 8, 100, 55, 1, 77, 23};
    for (int i = 0; i < N; i++) data[i] = seed[i];

    uint64_t base = (uint64_t)(uintptr_t)data;
    int fails = 0;

    printf("DCDart stats demo (C owns the buffer, DCDart walks it)\n");
    printf("=======================================================\n");
    printf("elementAt(3)   = %u\n",   elementAt(base, 3));
    printf("sum            = %llu\n", (unsigned long long)sum(base, N));
    printf("mean           = %llu\n", (unsigned long long)mean(base, N));
    printf("maxOf          = %u\n",   maxOf(base, N));
    printf("countAbove(20) = %llu\n", (unsigned long long)countAbove(base, N, 20));

    if (elementAt(base, 3) != 42)     { printf("FAIL elementAt\n");  fails++; }
    if (elementAt(base, 0) != 7)      { printf("FAIL elementAt0\n"); fails++; }
    if (elementAt(base, 9) != 23)     { printf("FAIL elementAt9\n"); fails++; }
    if (sum(base, N) != 335)          { printf("FAIL sum\n");        fails++; }
    if (mean(base, N) != 33)          { printf("FAIL mean\n");       fails++; }
    if (maxOf(base, N) != 100)        { printf("FAIL max\n");        fails++; }
    if (countAbove(base, N, 20) != 5) { printf("FAIL countAbove\n"); fails++; }
    /* mean() must GUARD the zero divisor rather than trap: `~/` traps on a
     * zero divisor (ADR-0036), so an unguarded mean(base, 0) would kill the
     * process instead of returning. */
    if (mean(base, 0) != 0)           { printf("FAIL mean-empty\n"); fails++; }

    free(data);
    printf(fails ? "STATS: %d FAILURES\n" : "STATS: all correct\n", fails);
    return fails != 0;
}
