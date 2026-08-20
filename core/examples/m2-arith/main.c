// M2 multiply/divide/remainder harness: docs/decisions/0035-complete-integer-
// operators.md and docs/decisions/0036-division-and-remainder.md. Every
// operator here is an ordinary unprivileged instruction, so this is a
// real-execution, exact-expected-value check, not the disassembly-only
// structural check Port I/O needed.
//
// Two kinds of check, deliberately both present:
//
//   * The isolated operators are swept over ranges and compared against C's
//     OWN `*`, `/`, `%` on the identically-sized unsigned type. That is an
//     independent implementation (the host compiler's), not a restatement of
//     what DCDart did.
//   * The composed algorithms are compared against HARD-CODED literals --
//     gcd(1071,462)==21, digitSum(9875)==29, isPrime(7919)==1 and so on --
//     computed outside this file and outside DCDart. Re-implementing gcd in C
//     to check DCDart's gcd would only prove the two agree, so it is not done
//     here.
//
// Every operand is chosen so nothing traps: no zero divisors, and no product
// that overflows its width (`*` traps on overflow, spec §4.1). The trap
// paths are proved separately by trap_divzero.c, which cannot share a binary
// with these checks because a trap kills the process.
//
// Return code 0 means every check passed; any other value identifies the
// first check that failed (see the comment on each `return`).
#include <stdint.h>

extern uint64_t mulU64(uint64_t a, uint64_t b);
extern uint32_t mulU32(uint32_t a, uint32_t b);
extern uint16_t mulU16(uint16_t a, uint16_t b);
extern uint8_t  mulU8(uint8_t a, uint8_t b);

extern uint64_t divU64(uint64_t a, uint64_t b);
extern uint64_t remU64(uint64_t a, uint64_t b);
extern uint32_t divU32(uint32_t a, uint32_t b);
extern uint32_t remU32(uint32_t a, uint32_t b);
extern uint8_t  divU8(uint8_t a, uint8_t b);
extern uint8_t  remU8(uint8_t a, uint8_t b);

extern uint64_t gcd(uint64_t x, uint64_t y);
extern uint32_t gcdU32(uint32_t x, uint32_t y);
extern uint64_t digitSum(uint64_t n);
extern uint64_t isPrime(uint64_t n);
extern uint64_t powMod(uint64_t base, uint64_t exp, uint64_t m);
extern uint64_t lcm(uint64_t a, uint64_t b);
extern uint64_t sumProperDivisors(uint64_t n);

int main(void) {
    // -- 1..4: multiplication swept at every width, against C's own `*`. ----
    // Ranges are bounded so no product overflows its width and traps.
    for (uint64_t a = 0; a < 300; a++) {
        for (uint64_t b = 0; b < 300; b += 7) {
            if (mulU64(a, b) != a * b) return 1;
        }
    }
    // 59911 * 59820 == 3.58e9, comfortably under 2^32: a sweep whose top
    // corner overflowed would trap and kill this binary, not fail a check.
    for (uint32_t a = 0; a < 60000u; a += 331u) {
        for (uint32_t b = 0; b < 60000u; b += 997u) {
            if (mulU32(a, b) != (uint32_t)(a * b)) return 2;
        }
    }
    for (uint32_t a = 0; a < 256u; a++) {
        for (uint32_t b = 0; b < 256u; b++) {
            if (mulU16((uint16_t)a, (uint16_t)b) != (uint16_t)(a * b)) return 3;
        }
    }
    for (uint32_t a = 0; a < 16u; a++) {
        for (uint32_t b = 0; b < 16u; b++) {
            if (mulU8((uint8_t)a, (uint8_t)b) != (uint8_t)(a * b)) return 4;
        }
    }

    // -- 5..10: division and remainder, against C's own `/` and `%`. --------
    // Divisor starts at 1 everywhere: 0 traps, which is trap_divzero.c's job.
    for (uint64_t a = 0; a < 4000; a += 13) {
        for (uint64_t b = 1; b < 400; b += 3) {
            if (divU64(a, b) != a / b) return 5;
            if (remU64(a, b) != a % b) return 6;
        }
    }
    for (uint32_t a = 0; a < 4000000u; a += 100003u) {
        for (uint32_t b = 1; b < 5000u; b += 71u) {
            if (divU32(a, b) != a / b) return 7;
            if (remU32(a, b) != a % b) return 8;
        }
    }
    for (uint32_t a = 0; a < 256u; a++) {
        for (uint32_t b = 1; b < 256u; b++) {
            if (divU8((uint8_t)a, (uint8_t)b) != (uint8_t)(a / b)) return 9;
            if (remU8((uint8_t)a, (uint8_t)b) != (uint8_t)(a % b)) return 10;
        }
    }

    // -- 11: multiplication at the top of each width's range. ---------------
    // The sweeps above never leave the low bits, so these pin the wide cases:
    // a full-width u64 product, and the largest product each narrower type
    // can hold without overflowing.
    if (mulU64(4294967291ull, 4294967291ull) != 18446744030759878681ull) return 11;
    if (mulU64(1234567890123ull, 13ull) != 16049382571599ull) return 11;
    if (mulU64(0ull, 18446744073709551615ull) != 0ull) return 11;
    if (mulU64(1ull, 18446744073709551615ull) != 18446744073709551615ull) return 11;
    if (mulU32(65535u, 65535u) != 4294836225u) return 11;
    if (mulU16(255u, 257u) != 65535u) return 11;
    if (mulU8(15u, 17u) != 255u) return 11;

    // -- 12..13: Euclid's gcd, at u64 and u32. ------------------------------
    if (gcd(1071ull, 462ull) != 21ull) return 12;
    if (gcd(462ull, 1071ull) != 21ull) return 12;
    if (gcd(270ull, 192ull) != 6ull) return 12;
    if (gcd(17ull, 5ull) != 1ull) return 12;
    if (gcd(123456789ull, 987654321ull) != 9ull) return 12;
    if (gcd(0ull, 7ull) != 7ull) return 12;   // first iteration is 0 % 7
    if (gcd(7ull, 0ull) != 7ull) return 12;   // loop body never runs
    if (gcd(13ull, 13ull) != 13ull) return 12;
    if (gcdU32(4294967295u, 1234567u) != 1u) return 13;
    if (gcdU32(65536u, 49152u) != 16384u) return 13;
    if (gcdU32(1071u, 462u) != 21u) return 13;

    // -- 14: digit sum, the `~/ 10` and `% 10` pair. ------------------------
    if (digitSum(9875ull) != 29ull) return 14;
    if (digitSum(0ull) != 0ull) return 14;
    if (digitSum(7ull) != 7ull) return 14;
    if (digitSum(1000000ull) != 1ull) return 14;
    if (digitSum(999999999999999999ull) != 162ull) return 14;
    if (digitSum(18446744073709551615ull) != 87ull) return 14;  // u64 max

    // -- 15: primality by trial division, the `i * i <= n` bound. -----------
    if (isPrime(0ull) != 0ull) return 15;
    if (isPrime(1ull) != 0ull) return 15;
    if (isPrime(2ull) != 1ull) return 15;
    if (isPrime(3ull) != 1ull) return 15;
    if (isPrime(4ull) != 0ull) return 15;
    if (isPrime(7919ull) != 1ull) return 15;       // 1000th prime
    if (isPrime(7917ull) != 0ull) return 15;       // 3 * 7 * 13 * 29
    if (isPrime(104729ull) != 1ull) return 15;     // 10000th prime
    if (isPrime(104730ull) != 0ull) return 15;
    if (isPrime(1000003ull) != 1ull) return 15;
    if (isPrime(1000001ull) != 0ull) return 15;    // 101 * 9901

    // -- 16: modular exponentiation -- *, ~/ and % composed in one loop. ----
    if (powMod(2ull, 10ull, 1000ull) != 24ull) return 16;
    if (powMod(3ull, 13ull, 497ull) != 444ull) return 16;
    if (powMod(7ull, 0ull, 13ull) != 1ull) return 16;
    if (powMod(5ull, 117ull, 19ull) != 1ull) return 16;
    if (powMod(1234567ull, 89ull, 1000000007ull) != 534172268ull) return 16;
    if (powMod(123ull, 456ull, 1ull) != 0ull) return 16;  // acc starts 1 % 1

    // -- 17: lcm -- a `~/` result fed into a `*` across a sibling call. -----
    if (lcm(4ull, 6ull) != 12ull) return 17;
    if (lcm(21ull, 6ull) != 42ull) return 17;
    if (lcm(1071ull, 462ull) != 23562ull) return 17;
    if (lcm(123456ull, 789012ull) != 8117355456ull) return 17;
    if (lcm(0ull, 5ull) != 0ull) return 17;
    if (lcm(5ull, 0ull) != 0ull) return 17;

    // -- 18: sum of proper divisors -- perfect numbers are the check. -------
    if (sumProperDivisors(1ull) != 0ull) return 18;
    if (sumProperDivisors(6ull) != 6ull) return 18;      // perfect
    if (sumProperDivisors(28ull) != 28ull) return 18;    // perfect
    if (sumProperDivisors(8128ull) != 8128ull) return 18;// perfect
    if (sumProperDivisors(12ull) != 16ull) return 18;    // abundant
    if (sumProperDivisors(97ull) != 1ull) return 18;     // prime
    if (sumProperDivisors(10000ull) != 14211ull) return 18;

    return 0;
}
