/* Conformance harness for instance methods (ADR-0043). Declarations come
 * from the generated header, so a wrong receiver type would be a compile
 * error here rather than silent corruption. */
#include <stdint.h>
#include <stdio.h>
#include "methods.h"

static int fails = 0;
static void ck(const char *n, uint64_t got, uint64_t want) {
    if (got != want) {
        printf("  FAIL %s: got %llu want %llu\n", n,
               (unsigned long long)got, (unsigned long long)want);
        fails++;
    }
}

int main(void) {
    ck("net(100,30)", net(100, 30), 70);
    ck("net(30,30)", net(30, 30), 0);
    ck("afterDeposit(100,30,50)", afterDeposit(100, 30, 50), 150);
    /* method calling a method on `this`: (100+50) - 30 */
    ck("netAfterDeposit(100,30,50)", netAfterDeposit(100, 30, 50), 120);
    ck("solvent(100,30)", solvent(100, 30), 1);
    ck("solvent(30,30)", solvent(30, 30), 0);
    /* two live receivers, so the argument must actually vary */
    ck("compareTwo(100,30,50,30)", compareTwo(100, 30, 50, 30), 1);
    ck("compareTwo(50,30,100,30)", compareTwo(50, 30, 100, 30), 0);
    printf(fails ? "METHODS: %d FAILURES\n" : "METHODS: all correct\n", fails);
    return fails != 0;
}
