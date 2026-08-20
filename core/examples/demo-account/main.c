// Ordinary hosted C program, same as demo-collatz/main.c -- no
// -ffreestanding, no -nostdlib. Reads the real {tag, payload} Result
// struct DCDart returns across the C ABI directly.
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint64_t tag; // 0 = Ok, 1 = Err
    uint64_t payload;
} DCResult;

extern DCResult openAndWithdrawTwice(uint64_t initial, uint64_t amount);
extern uint64_t drainAccount(uint64_t initial, uint64_t amount);

static void printResult(const char *label, DCResult r) {
    if (r.tag == 0) {
        printf("%s = Ok(%llu)\n", label, (unsigned long long)r.payload);
    } else {
        printf("%s = Err(%llu)\n", label, (unsigned long long)r.payload);
    }
}

int main(void) {
    printf("DCDart Account demo\n");
    printf("====================\n");
    printResult("openAndWithdrawTwice(100, 30)", openAndWithdrawTwice(100, 30));
    printResult("openAndWithdrawTwice(50, 30)", openAndWithdrawTwice(50, 30));
    printf("drainAccount(100, 30) = %llu withdrawals\n",
           (unsigned long long)drainAccount(100, 30));
    printf("drainAccount(1000, 7) = %llu withdrawals\n",
           (unsigned long long)drainAccount(1000, 7));
    return 0;
}
