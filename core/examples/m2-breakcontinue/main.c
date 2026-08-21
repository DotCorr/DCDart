#include <stdint.h>
#include <stdio.h>
#include "loopctl.h"
static int fails = 0;
static void ck(const char *n, uint64_t got, uint64_t want) {
    if (got != want) { printf("  FAIL %s: got %llu want %llu\n", n,
        (unsigned long long)got, (unsigned long long)want); fails++; }
}
int main(void) {
    /* assign-then-break: the exit must see the ASSIGNED value */
    ck("firstMatch(10,4)", firstMatch(10, 4), 4);
    ck("firstMatch(10,0)", firstMatch(10, 0), 0);
    ck("firstMatch(10,9)", firstMatch(10, 9), 9);
    ck("firstMatch(5,99)", firstMatch(5, 99), 999);   /* never matches */
    /* continue */
    ck("sumEvens(10)", sumEvens(10), 2 + 4 + 6 + 8 + 10);
    ck("sumEvens(7)", sumEvens(7), 2 + 4 + 6);
    ck("sumEvens(1)", sumEvens(1), 0);
    ck("sumEvens(0)", sumEvens(0), 0);
    /* break leaves only the INNER loop: 2 hits per row */
    ck("breakInner(3,5)", breakInner(3, 5), 6);
    ck("breakInner(4,1)", breakInner(4, 1), 4);
    ck("breakInner(0,9)", breakInner(0, 9), 0);
    /* both in one loop: evens below 7 */
    ck("bothInOne(20)", bothInOne(20), 2 + 4 + 6);
    ck("bothInOne(3)", bothInOne(3), 2);
    printf(fails ? "BREAKCONT: %d FAILURES\n" : "BREAKCONT: all correct\n", fails);
    return fails != 0;
}
