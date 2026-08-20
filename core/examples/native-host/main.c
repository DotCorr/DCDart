// An ORDINARY hosted C program -- real <stdio.h>, real printf, real main(),
// linked with plain `clang -o bin main.c native.o`. No -ffreestanding, no
// -nostdlib, no -static, no hand-written _start.S. That is the whole point
// of this target: `dcc build --mode bare --target host` emits a native
// object for THIS machine (Mach-O on macOS, COFF on Windows, ELF on Linux),
// so a @bare DCDart object is just a plain C-ABI .o that drops into any
// normal C program.
//
// Every expectation below is an INDEPENDENTLY KNOWN answer -- either a
// classical constant (the perfect numbers below 10000; pi(10000)) or a
// closed form evaluated here in C with no shared code with the DCDart loop.
// Nothing here asserts merely "it ran".
//
// Exit codes (each identifies exactly which claim broke):
//    0  all correct
//    1  arena not at baseline before any DCDart call
//    2  perfectCount(2,10000) wrong           (must be 4)
//    3  perfectSum(2,10000) wrong             (must be 8658)
//    4  primeCount(10000) wrong               (must be 1229)
//    5  primeSum(10000) wrong                 (must be 5736396)
//    6  sumOfSquares(1000) wrong vs closed form n(n+1)(2n+1)/6
//    7  sumOfSquares disagrees over a swept range 0..200
//    8  gcd/lcm wrong
//    9  digitSum wrong
//   10  modPow32 wrong
//   11  triangleU16 wrong
//   12  gcdU8 wrong
//   13  ARC leak: arena free-list did not return to baseline
#include <stdint.h>
#include <stdio.h>

/* Every one of these is a real @bare DCDart function in native.dart. */
extern uint64_t gcd(uint64_t a, uint64_t b);
extern uint64_t lcm(uint64_t a, uint64_t b);
extern uint64_t sumProperDivisors(uint64_t n);
extern uint64_t isPrime(uint64_t n);
extern uint64_t perfectCount(uint64_t lo, uint64_t hi);
extern uint64_t perfectSum(uint64_t lo, uint64_t hi);
extern uint64_t primeCount(uint64_t limit);
extern uint64_t primeSum(uint64_t limit);
extern uint64_t sumOfSquares(uint64_t n);
extern uint64_t digitSum(uint64_t n);
extern uint32_t modPow32(uint32_t base, uint32_t exp, uint32_t mod);
extern uint16_t triangleU16(uint16_t n);
extern uint8_t  gcdU8(uint8_t a, uint8_t b);

/* The M2 ARC arena's free-list counter -- a real symbol in the object file
 * (core/backend, docs/decisions/0015-m2-minimal-arc-arena.md). 64 = every
 * slot free. Reading it from ordinary C is itself part of the proof that
 * this is a normal native object. */
extern uint32_t dc_free_top;

#define ARENA_SLOTS 64u

/* Closed form for 1^2 + 2^2 + ... + n^2. Shares no code with the DCDart
 * loop that computes the same sum by accumulation. */
static uint64_t sum_squares_closed_form(uint64_t n) {
    return n * (n + 1) * (2 * n + 1) / 6;
}

static int failures = 0;

static void check_u64(const char *label, uint64_t got, uint64_t want) {
    if (got == want) {
        printf("  ok   %-34s = %llu\n", label, (unsigned long long)got);
    } else {
        printf("  FAIL %-34s = %llu (expected %llu)\n", label,
               (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

int main(void) {
    printf("DCDart native-host conformance target\n");
    printf("=====================================\n");
    printf("A @bare DCDart object built with --target host, linked into this\n");
    printf("ordinary C program by plain clang and executed natively.\n\n");

    if (dc_free_top != ARENA_SLOTS) {
        printf("FAIL arena not at baseline before any call: dc_free_top = %u\n",
               dc_free_top);
        return 1;
    }
    printf("ARC arena baseline before any call: dc_free_top = %u\n\n", dc_free_top);

    /* --- perfect numbers: 6, 28, 496, 8128 are the only ones below 10000,
       a classical result, so 4 and 8658 are known independently. --- */
    printf("Perfect numbers below 10000 (classically 6, 28, 496, 8128):\n");
    check_u64("perfectCount(2, 10000)", perfectCount(2, 10000), 4);
    check_u64("perfectSum(2, 10000)", perfectSum(2, 10000), 8658);
    if (perfectCount(2, 10000) != 4) return 2;
    if (perfectSum(2, 10000) != 8658) return 3;

    /* sumProperDivisors is what makes those perfect: spot-check the four. */
    check_u64("sumProperDivisors(6)", sumProperDivisors(6), 6);
    check_u64("sumProperDivisors(28)", sumProperDivisors(28), 28);
    check_u64("sumProperDivisors(496)", sumProperDivisors(496), 496);
    check_u64("sumProperDivisors(8128)", sumProperDivisors(8128), 8128);
    check_u64("sumProperDivisors(12)", sumProperDivisors(12), 16); /* abundant */
    if (sumProperDivisors(6) != 6 || sumProperDivisors(28) != 28 ||
        sumProperDivisors(496) != 496 || sumProperDivisors(8128) != 8128 ||
        sumProperDivisors(12) != 16) {
        return 2;
    }

    /* --- primes: pi(10000) = 1229 is a standard tabulated value. --- */
    printf("\nPrimes below 10000 (pi(10000) = 1229 is tabulated):\n");
    check_u64("primeCount(10000)", primeCount(10000), 1229);
    check_u64("primeSum(10000)", primeSum(10000), 5736396);
    if (primeCount(10000) != 1229) return 4;
    if (primeSum(10000) != 5736396) return 5;
    check_u64("isPrime(7919)", isPrime(7919), 1);  /* the 1000th prime */
    check_u64("isPrime(7917)", isPrime(7917), 0);  /* 3 * 7 * 13 * 29 */
    check_u64("isPrime(1)", isPrime(1), 0);
    if (isPrime(7919) != 1 || isPrime(7917) != 0 || isPrime(1) != 0) return 4;

    /* --- sum of squares vs its closed form, then swept. --- */
    printf("\nSum of squares 1..n vs closed form n(n+1)(2n+1)/6:\n");
    check_u64("sumOfSquares(1000)", sumOfSquares(1000),
              sum_squares_closed_form(1000));
    if (sumOfSquares(1000) != sum_squares_closed_form(1000)) return 6;
    for (uint64_t n = 0; n <= 200; n++) {
        if (sumOfSquares(n) != sum_squares_closed_form(n)) {
            printf("  FAIL sumOfSquares(%llu) = %llu (expected %llu)\n",
                   (unsigned long long)n, (unsigned long long)sumOfSquares(n),
                   (unsigned long long)sum_squares_closed_form(n));
            return 7;
        }
    }
    printf("  ok   sumOfSquares matches the closed form for every n in 0..200\n");

    /* --- gcd / lcm: Euclid's own worked example. --- */
    printf("\nEuclid (gcd(1071, 462) = 21, lcm = 23562):\n");
    check_u64("gcd(1071, 462)", gcd(1071, 462), 21);
    check_u64("lcm(1071, 462)", lcm(1071, 462), 23562);
    check_u64("gcd(17, 5)", gcd(17, 5), 1);
    check_u64("gcd(0, 9)", gcd(0, 9), 9);
    if (gcd(1071, 462) != 21 || lcm(1071, 462) != 23562 ||
        gcd(17, 5) != 1 || gcd(0, 9) != 9) {
        return 8;
    }
    /* lcm divides before multiplying, so a product far past 2^32 -- which a
       naive (a*b)/g would trap on -- still works. */
    check_u64("lcm(4294967295, 4294967294)", lcm(4294967295ULL, 4294967294ULL),
              18446744060824649730ULL);
    if (lcm(4294967295ULL, 4294967294ULL) != 18446744060824649730ULL) return 8;

    /* --- digit sums via ~/ and %. --- */
    printf("\nDecimal digit sums (integer division and remainder):\n");
    check_u64("digitSum(9876543210)", digitSum(9876543210ULL), 45);
    check_u64("digitSum(0)", digitSum(0), 0);
    check_u64("digitSum(18446744073709551615)",
              digitSum(18446744073709551615ULL), 87);
    if (digitSum(9876543210ULL) != 45 || digitSum(0) != 0 ||
        digitSum(18446744073709551615ULL) != 87) {
        return 9;
    }

    /* --- narrower widths. --- */
    printf("\nNarrower widths (u32 modpow, u16 triangle, u8 gcd):\n");
    check_u64("modPow32(3, 100, 65521)", modPow32(3, 100, 65521), 23072);
    check_u64("modPow32(7, 4096, 65521)", modPow32(7, 4096, 65521), 11838);
    check_u64("modPow32(2, 0, 65521)", modPow32(2, 0, 65521), 1);
    if (modPow32(3, 100, 65521) != 23072 || modPow32(7, 4096, 65521) != 11838 ||
        modPow32(2, 0, 65521) != 1) {
        return 10;
    }
    check_u64("triangleU16(300)", triangleU16(300), 44850); /* 300*299/2 */
    if (triangleU16(300) != 44850) return 11;
    for (uint16_t n = 0; n <= 360; n++) {
        uint16_t want = (uint16_t)((uint32_t)n * (uint32_t)(n ? n - 1 : 0) / 2);
        if (triangleU16(n) != want) {
            printf("  FAIL triangleU16(%u) = %u (expected %u)\n",
                   n, triangleU16(n), want);
            return 11;
        }
    }
    printf("  ok   triangleU16 matches n(n-1)/2 for every n in 0..360\n");
    check_u64("gcdU8(252, 105)", gcdU8(252, 105), 21);
    check_u64("gcdU8(255, 128)", gcdU8(255, 128), 1);
    if (gcdU8(252, 105) != 21 || gcdU8(255, 128) != 1) return 12;

    /* --- ARC: every call above allocated two heap objects (a Range and a
       Tally). If any release were missed the 64-slot arena would have been
       exhausted long ago; check it landed back exactly at baseline. --- */
    printf("\nARC arena after all calls: dc_free_top = %u (baseline %u)\n",
           dc_free_top, ARENA_SLOTS);
    if (dc_free_top != ARENA_SLOTS) {
        printf("FAIL ARC leak: arena did not return to baseline\n");
        return 13;
    }
    /* Hammer it: 2000 more allocating calls, checking baseline every time. */
    for (uint64_t i = 0; i < 2000; i++) {
        if (perfectCount(2, 30) != 2) return 2;   /* 6 and 28 */
        if (dc_free_top != ARENA_SLOTS) {
            printf("FAIL ARC leak after %llu repeat calls: dc_free_top = %u\n",
                   (unsigned long long)i, dc_free_top);
            return 13;
        }
    }
    printf("  ok   2000 further allocating calls, arena at baseline every time\n");

    if (failures != 0) {
        printf("\n%d check(s) failed\n", failures);
        return 2;
    }

    printf("\nALL CHECKS PASSED\n");
    return 0;
}
