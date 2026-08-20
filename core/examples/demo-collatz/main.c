// A normal, ordinary hosted C program -- no -ffreestanding, no -nostdlib,
// no hand-written _start.S like the conformance harnesses use. This is
// the point: a DCDart @bare object file is a plain C-ABI object file. It
// links into a completely normal C program with real libc, real printf,
// real argv, exactly like any other .o would.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern uint64_t collatzSteps(uint64_t start);
extern uint64_t sumCollatzSteps(uint64_t upTo);

int main(int argc, char **argv) {
    uint64_t n = 27; // the famous one: takes 111 steps
    if (argc > 1) {
        n = strtoull(argv[1], NULL, 10);
    }

    printf("DCDart Collatz demo\n");
    printf("====================\n");
    printf("collatzSteps(%llu) = %llu steps to reach 1\n",
           (unsigned long long)n, (unsigned long long)collatzSteps(n));

    uint64_t range = 1000;
    printf("sum of collatzSteps(1..%llu) = %llu\n",
           (unsigned long long)range,
           (unsigned long long)sumCollatzSteps(range));

    return 0;
}
