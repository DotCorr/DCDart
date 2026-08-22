#include <stdint.h>
#include <stdio.h>
#include "list.h"
static int fails = 0;
static void ck(const char *n, uint64_t got, uint64_t want) {
    if (got != want) { printf("  FAIL %s: got %llu want %llu\n", n,
        (unsigned long long)got, (unsigned long long)want); fails++; }
}
int main(void) {
    ck("buildAndSum(0)", buildAndSum(0), 0);
    ck("buildAndSum(1)", buildAndSum(1), 0);
    ck("buildAndSum(5)", buildAndSum(5), 0+1+2+3+4);
    ck("buildAndSum(10)", buildAndSum(10), 45);
    /* the list is built head-first, so the LAST node walked is value 0 */
    ck("lastValue(5)", lastValue(5), 0);
    ck("lastValue(1)", lastValue(1), 0);
    ck("countUpTo(10,3)", countUpTo(10, 3), 3);
    ck("countUpTo(10,99)", countUpTo(10, 99), 10);
    ck("countUpTo(0,5)", countUpTo(0, 5), 0);

    /* THE LEAK CHECK, and the reason this target exists. The M2 arena has 64
     * slots. 500 iterations building a 10-node list allocates 5000 nodes,
     * which is only possible if every one of them is freed. One missing
     * release exhausts the arena within the first few iterations. */
    for (int i = 0; i < 500; i++) {
        if (buildAndSum(10) != 45) {
            printf("  FAIL leak-check failed at iteration %d\n", i);
            fails++;
            break;
        }
    }
    printf(fails ? "LIST: %d FAILURES\n" : "LIST: all correct, leak-free over 500 build/walk cycles\n", fails);
    return fails != 0;
}
