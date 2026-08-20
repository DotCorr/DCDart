// M2 comparison/equality-operator harness (docs/decisions/0035-complete-
// integer-operators.md). Like m2-bitwise and unlike m2-port, compares are
// ordinary unprivileged instructions, so this is real execution checked
// against exact expected values, not a disassembly-only structural check.
//
// EVERY expected value below is written out as a literal. The equivalent C
// expression is deliberately NOT used as the oracle: C's `<` on uint8_t
// operands promotes both sides to int and would therefore agree with a
// DCDart backend that had wrongly emitted a SIGNED compare, which is
// exactly the bug class the max-value cases exist to catch.
//
// Return codes, so a failure names the operator and width that broke:
//    1- 4  ordering at u64  (lt, le, gt, ge)
//    5- 8  ordering at u32  (lt, le, gt, ge)
//    9-12  ordering at u16  (lt, le, gt, ge)
//   13-16  ordering at u8   (lt, le, gt, ge)
//   17-20  unsigned-vs-signed discrimination at u64/u32/u16/u8: 0 vs the
//          width's maximum, whose top bit is set. These are the cases a
//          signed predicate (slt instead of ult) gets backwards.
//   21-28  equality at u64/u32/u16/u8 (eq then ne for each width)
//   29-32  equality at each width's maximum and max-1
//   33     eqElseU64      34  neElseU64
//   35     stepsUntilEqual (`!=` as a loop condition)
//   36     advanceWhileEqual (`==` as a loop condition)
//   40     clampU64       41  clampU8
//   42     cmp3U64        43  cmp3U16
//   44     max3U32        45  gcdU64        46  countBelowU64
#include <stdint.h>

extern uint64_t ltU64(uint64_t a, uint64_t b);
extern uint64_t leU64(uint64_t a, uint64_t b);
extern uint64_t gtU64(uint64_t a, uint64_t b);
extern uint64_t geU64(uint64_t a, uint64_t b);

extern uint32_t ltU32(uint32_t a, uint32_t b);
extern uint32_t leU32(uint32_t a, uint32_t b);
extern uint32_t gtU32(uint32_t a, uint32_t b);
extern uint32_t geU32(uint32_t a, uint32_t b);

extern uint16_t ltU16(uint16_t a, uint16_t b);
extern uint16_t leU16(uint16_t a, uint16_t b);
extern uint16_t gtU16(uint16_t a, uint16_t b);
extern uint16_t geU16(uint16_t a, uint16_t b);

extern uint8_t ltU8(uint8_t a, uint8_t b);
extern uint8_t leU8(uint8_t a, uint8_t b);
extern uint8_t gtU8(uint8_t a, uint8_t b);
extern uint8_t geU8(uint8_t a, uint8_t b);

extern uint64_t eqU64(uint64_t a, uint64_t b);
extern uint64_t neU64(uint64_t a, uint64_t b);
extern uint32_t eqU32(uint32_t a, uint32_t b);
extern uint32_t neU32(uint32_t a, uint32_t b);
extern uint16_t eqU16(uint16_t a, uint16_t b);
extern uint16_t neU16(uint16_t a, uint16_t b);
extern uint8_t  eqU8(uint8_t a, uint8_t b);
extern uint8_t  neU8(uint8_t a, uint8_t b);

extern uint64_t eqElseU64(uint64_t a, uint64_t b);
extern uint64_t neElseU64(uint64_t a, uint64_t b);
extern uint64_t stepsUntilEqual(uint64_t start, uint64_t target);
extern uint64_t advanceWhileEqual(uint64_t a, uint64_t b, uint64_t limit);

extern uint64_t clampU64(uint64_t v, uint64_t lo, uint64_t hi);
extern uint8_t  clampU8(uint8_t v, uint8_t lo, uint8_t hi);
extern uint64_t cmp3U64(uint64_t a, uint64_t b);
extern uint16_t cmp3U16(uint16_t a, uint16_t b);
extern uint32_t max3U32(uint32_t a, uint32_t b, uint32_t c);
extern uint64_t gcdU64(uint64_t a, uint64_t b);
extern uint64_t countBelowU64(uint64_t n, uint64_t pivot);

#define U64MAX 18446744073709551615ULL
#define U32MAX 4294967295u
#define U16MAX 65535u
#define U8MAX  255u

// One row of the ordering table: the four expected results for (a, b), all
// written out by hand. `base` is the return code of the `lt` check; the
// other three are base+1, base+2, base+3.
#define ORD(SUF, TY, A, B, ELT, ELE, EGT, EGE, BASE)      \
    do {                                                  \
        if (lt##SUF((TY)(A), (TY)(B)) != (TY)(ELT)) return (BASE);     \
        if (le##SUF((TY)(A), (TY)(B)) != (TY)(ELE)) return (BASE) + 1; \
        if (gt##SUF((TY)(A), (TY)(B)) != (TY)(EGT)) return (BASE) + 2; \
        if (ge##SUF((TY)(A), (TY)(B)) != (TY)(EGE)) return (BASE) + 3; \
    } while (0)

#define EQNE(SUF, TY, A, B, EEQ, ENE, BASE)               \
    do {                                                  \
        if (eq##SUF((TY)(A), (TY)(B)) != (TY)(EEQ)) return (BASE);     \
        if (ne##SUF((TY)(A), (TY)(B)) != (TY)(ENE)) return (BASE) + 1; \
    } while (0)

int main(void) {
    // -----------------------------------------------------------------
    // Ordering at u64 — codes 1-4. Equal operands, off-by-one on each
    // side, zero, and the type maximum.
    // -----------------------------------------------------------------
    ORD(U64, uint64_t, 0,            0,            0, 1, 0, 1, 1);
    ORD(U64, uint64_t, 0,            1,            1, 1, 0, 0, 1);
    ORD(U64, uint64_t, 1,            0,            0, 0, 1, 1, 1);
    ORD(U64, uint64_t, 5,            5,            0, 1, 0, 1, 1);
    ORD(U64, uint64_t, 5,            6,            1, 1, 0, 0, 1);
    ORD(U64, uint64_t, 6,            5,            0, 0, 1, 1, 1);
    ORD(U64, uint64_t, U64MAX,       U64MAX,       0, 1, 0, 1, 1);
    ORD(U64, uint64_t, U64MAX - 1,   U64MAX,       1, 1, 0, 0, 1);
    ORD(U64, uint64_t, U64MAX,       U64MAX - 1,   0, 0, 1, 1, 1);

    // -----------------------------------------------------------------
    // Ordering at u32 — codes 5-8.
    // -----------------------------------------------------------------
    ORD(U32, uint32_t, 0,            0,            0, 1, 0, 1, 5);
    ORD(U32, uint32_t, 0,            1,            1, 1, 0, 0, 5);
    ORD(U32, uint32_t, 1,            0,            0, 0, 1, 1, 5);
    ORD(U32, uint32_t, 5,            5,            0, 1, 0, 1, 5);
    ORD(U32, uint32_t, 5,            6,            1, 1, 0, 0, 5);
    ORD(U32, uint32_t, 6,            5,            0, 0, 1, 1, 5);
    ORD(U32, uint32_t, U32MAX,       U32MAX,       0, 1, 0, 1, 5);
    ORD(U32, uint32_t, U32MAX - 1,   U32MAX,       1, 1, 0, 0, 5);
    ORD(U32, uint32_t, U32MAX,       U32MAX - 1,   0, 0, 1, 1, 5);
    // 0x80000000 is the smallest u32 with the top bit set: the first value
    // a signed 32-bit compare would call negative.
    ORD(U32, uint32_t, 0x7FFFFFFFu,  0x80000000u,  1, 1, 0, 0, 5);
    ORD(U32, uint32_t, 0x80000000u,  0x7FFFFFFFu,  0, 0, 1, 1, 5);

    // -----------------------------------------------------------------
    // Ordering at u16 — codes 9-12.
    // -----------------------------------------------------------------
    ORD(U16, uint16_t, 0,            0,            0, 1, 0, 1, 9);
    ORD(U16, uint16_t, 0,            1,            1, 1, 0, 0, 9);
    ORD(U16, uint16_t, 1,            0,            0, 0, 1, 1, 9);
    ORD(U16, uint16_t, 5,            5,            0, 1, 0, 1, 9);
    ORD(U16, uint16_t, 5,            6,            1, 1, 0, 0, 9);
    ORD(U16, uint16_t, 6,            5,            0, 0, 1, 1, 9);
    ORD(U16, uint16_t, U16MAX,       U16MAX,       0, 1, 0, 1, 9);
    ORD(U16, uint16_t, U16MAX - 1,   U16MAX,       1, 1, 0, 0, 9);
    ORD(U16, uint16_t, U16MAX,       U16MAX - 1,   0, 0, 1, 1, 9);
    ORD(U16, uint16_t, 0x7FFFu,      0x8000u,      1, 1, 0, 0, 9);
    ORD(U16, uint16_t, 0x8000u,      0x7FFFu,      0, 0, 1, 1, 9);

    // -----------------------------------------------------------------
    // Ordering at u8 — codes 13-16.
    // -----------------------------------------------------------------
    ORD(U8, uint8_t, 0,           0,           0, 1, 0, 1, 13);
    ORD(U8, uint8_t, 0,           1,           1, 1, 0, 0, 13);
    ORD(U8, uint8_t, 1,           0,           0, 0, 1, 1, 13);
    ORD(U8, uint8_t, 5,           5,           0, 1, 0, 1, 13);
    ORD(U8, uint8_t, 5,           6,           1, 1, 0, 0, 13);
    ORD(U8, uint8_t, 6,           5,           0, 0, 1, 1, 13);
    ORD(U8, uint8_t, U8MAX,       U8MAX,       0, 1, 0, 1, 13);
    ORD(U8, uint8_t, U8MAX - 1,   U8MAX,       1, 1, 0, 0, 13);
    ORD(U8, uint8_t, U8MAX,       U8MAX - 1,   0, 0, 1, 1, 13);
    ORD(U8, uint8_t, 0x7Fu,       0x80u,       1, 1, 0, 0, 13);
    ORD(U8, uint8_t, 0x80u,       0x7Fu,       0, 0, 1, 1, 13);

    // -----------------------------------------------------------------
    // Codes 17-20 — the load-bearing unsigned-vs-signed cases, called out
    // separately from the tables above so a failure here says exactly
    // "this width used a signed predicate". Under `ult`, 0 < MAX is true;
    // under `slt`, MAX reads as -1 and every one of these flips.
    // -----------------------------------------------------------------
    if (ltU64(0, U64MAX) != 1) return 17;
    if (leU64(0, U64MAX) != 1) return 17;
    if (gtU64(0, U64MAX) != 0) return 17;
    if (geU64(0, U64MAX) != 0) return 17;
    if (ltU64(U64MAX, 0) != 0) return 17;
    if (leU64(U64MAX, 0) != 0) return 17;
    if (gtU64(U64MAX, 0) != 1) return 17;
    if (geU64(U64MAX, 0) != 1) return 17;

    if (ltU32(0, U32MAX) != 1) return 18;
    if (leU32(0, U32MAX) != 1) return 18;
    if (gtU32(0, U32MAX) != 0) return 18;
    if (geU32(0, U32MAX) != 0) return 18;
    if (ltU32(U32MAX, 0) != 0) return 18;
    if (leU32(U32MAX, 0) != 0) return 18;
    if (gtU32(U32MAX, 0) != 1) return 18;
    if (geU32(U32MAX, 0) != 1) return 18;

    if (ltU16(0, U16MAX) != 1) return 19;
    if (leU16(0, U16MAX) != 1) return 19;
    if (gtU16(0, U16MAX) != 0) return 19;
    if (geU16(0, U16MAX) != 0) return 19;
    if (ltU16(U16MAX, 0) != 0) return 19;
    if (leU16(U16MAX, 0) != 0) return 19;
    if (gtU16(U16MAX, 0) != 1) return 19;
    if (geU16(U16MAX, 0) != 1) return 19;

    if (ltU8(0, U8MAX) != 1) return 20;
    if (leU8(0, U8MAX) != 1) return 20;
    if (gtU8(0, U8MAX) != 0) return 20;
    if (geU8(0, U8MAX) != 0) return 20;
    if (ltU8(U8MAX, 0) != 0) return 20;
    if (leU8(U8MAX, 0) != 0) return 20;
    if (gtU8(U8MAX, 0) != 1) return 20;
    if (geU8(U8MAX, 0) != 1) return 20;

    // -----------------------------------------------------------------
    // Equality and inequality — codes 21-28. The EqualsCall path.
    // -----------------------------------------------------------------
    EQNE(U64, uint64_t, 0,          0,          1, 0, 21);
    EQNE(U64, uint64_t, 0,          1,          0, 1, 21);
    EQNE(U64, uint64_t, 1,          0,          0, 1, 21);
    EQNE(U64, uint64_t, 5,          5,          1, 0, 21);
    EQNE(U64, uint64_t, 5,          6,          0, 1, 21);
    EQNE(U64, uint64_t, 6,          5,          0, 1, 21);
    EQNE(U64, uint64_t, 0,          U64MAX,     0, 1, 21);
    EQNE(U64, uint64_t, U64MAX,     0,          0, 1, 21);

    EQNE(U32, uint32_t, 0,          0,          1, 0, 23);
    EQNE(U32, uint32_t, 0,          1,          0, 1, 23);
    EQNE(U32, uint32_t, 1,          0,          0, 1, 23);
    EQNE(U32, uint32_t, 5,          5,          1, 0, 23);
    EQNE(U32, uint32_t, 5,          6,          0, 1, 23);
    EQNE(U32, uint32_t, 0,          U32MAX,     0, 1, 23);
    EQNE(U32, uint32_t, U32MAX,     0,          0, 1, 23);

    EQNE(U16, uint16_t, 0,          0,          1, 0, 25);
    EQNE(U16, uint16_t, 0,          1,          0, 1, 25);
    EQNE(U16, uint16_t, 1,          0,          0, 1, 25);
    EQNE(U16, uint16_t, 5,          5,          1, 0, 25);
    EQNE(U16, uint16_t, 5,          6,          0, 1, 25);
    EQNE(U16, uint16_t, 0,          U16MAX,     0, 1, 25);
    EQNE(U16, uint16_t, U16MAX,     0,          0, 1, 25);

    EQNE(U8, uint8_t, 0,        0,        1, 0, 27);
    EQNE(U8, uint8_t, 0,        1,        0, 1, 27);
    EQNE(U8, uint8_t, 1,        0,        0, 1, 27);
    EQNE(U8, uint8_t, 5,        5,        1, 0, 27);
    EQNE(U8, uint8_t, 5,        6,        0, 1, 27);
    EQNE(U8, uint8_t, 0,        U8MAX,    0, 1, 27);
    EQNE(U8, uint8_t, U8MAX,    0,        0, 1, 27);

    // -----------------------------------------------------------------
    // Codes 29-32 — equality AT the maximum and off-by-one from it. A
    // compare done at the wrong width (e.g. an 8-bit value compared as
    // 64-bit garbage, or a 64-bit value truncated to 32) shows up here
    // first: 255 == 255 must hold and 255 == 254 must not.
    // -----------------------------------------------------------------
    if (eqU64(U64MAX, U64MAX) != 1) return 29;
    if (neU64(U64MAX, U64MAX) != 0) return 29;
    if (eqU64(U64MAX, U64MAX - 1) != 0) return 29;
    if (neU64(U64MAX, U64MAX - 1) != 1) return 29;
    if (eqU64(U64MAX - 1, U64MAX) != 0) return 29;
    if (neU64(U64MAX - 1, U64MAX) != 1) return 29;

    if (eqU32(U32MAX, U32MAX) != 1) return 30;
    if (neU32(U32MAX, U32MAX) != 0) return 30;
    if (eqU32(U32MAX, U32MAX - 1) != 0) return 30;
    if (neU32(U32MAX, U32MAX - 1) != 1) return 30;
    if (eqU32(U32MAX - 1, U32MAX) != 0) return 30;
    if (neU32(U32MAX - 1, U32MAX) != 1) return 30;

    if (eqU16(U16MAX, U16MAX) != 1) return 31;
    if (neU16(U16MAX, U16MAX) != 0) return 31;
    if (eqU16(U16MAX, U16MAX - 1) != 0) return 31;
    if (neU16(U16MAX, U16MAX - 1) != 1) return 31;
    if (eqU16(U16MAX - 1, U16MAX) != 0) return 31;
    if (neU16(U16MAX - 1, U16MAX) != 1) return 31;

    if (eqU8(U8MAX, U8MAX) != 1) return 32;
    if (neU8(U8MAX, U8MAX) != 0) return 32;
    if (eqU8(U8MAX, U8MAX - 1) != 0) return 32;
    if (neU8(U8MAX, U8MAX - 1) != 1) return 32;
    if (eqU8(U8MAX - 1, U8MAX) != 0) return 32;
    if (neU8(U8MAX - 1, U8MAX) != 1) return 32;

    // -----------------------------------------------------------------
    // Codes 33-34 — equality with a real else-branch. 7 and 9 rather than
    // 1 and 0 so a branch that fell through to the wrong arm cannot land
    // on the right answer by accident. neElseU64 is the exact inverse of
    // eqElseU64: a lowering that dropped `!=`'s negation passes 33 and
    // fails 34.
    // -----------------------------------------------------------------
    if (eqElseU64(5, 5) != 7) return 33;
    if (eqElseU64(5, 6) != 9) return 33;
    if (eqElseU64(6, 5) != 9) return 33;
    if (eqElseU64(0, 0) != 7) return 33;
    if (eqElseU64(0, U64MAX) != 9) return 33;
    if (eqElseU64(U64MAX, U64MAX) != 7) return 33;

    if (neElseU64(5, 5) != 9) return 34;
    if (neElseU64(5, 6) != 7) return 34;
    if (neElseU64(6, 5) != 7) return 34;
    if (neElseU64(0, 0) != 9) return 34;
    if (neElseU64(0, U64MAX) != 7) return 34;
    if (neElseU64(U64MAX, U64MAX) != 9) return 34;

    // -----------------------------------------------------------------
    // Code 35 — `!=` as a while condition. Counts start..target, so the
    // answer is target - start; 0 when they already match (body never
    // runs).
    // -----------------------------------------------------------------
    if (stepsUntilEqual(0, 0) != 0) return 35;
    if (stepsUntilEqual(5, 5) != 0) return 35;
    if (stepsUntilEqual(0, 1) != 1) return 35;
    if (stepsUntilEqual(0, 10) != 10) return 35;
    if (stepsUntilEqual(100, 200) != 100) return 35;
    if (stepsUntilEqual(U64MAX - 3, U64MAX) != 3) return 35;

    // -----------------------------------------------------------------
    // Code 36 — `==` as a while condition. Equal on entry: one iteration,
    // then x no longer matches, so 1. Unequal on entry: body never runs,
    // so 0.
    // -----------------------------------------------------------------
    if (advanceWhileEqual(5, 5, 10) != 1) return 36;
    if (advanceWhileEqual(0, 0, 10) != 1) return 36;
    if (advanceWhileEqual(U64MAX - 1, U64MAX - 1, 10) != 1) return 36;
    if (advanceWhileEqual(5, 6, 10) != 0) return 36;
    if (advanceWhileEqual(6, 5, 10) != 0) return 36;
    if (advanceWhileEqual(0, U64MAX, 10) != 0) return 36;

    // -----------------------------------------------------------------
    // Code 40 — clamp into [lo, hi]. The interesting rows are v == lo and
    // v == hi, which come out wrong if `<`/`>` were lowered as `<=`/`>=`
    // or vice versa.
    // -----------------------------------------------------------------
    if (clampU64(15, 10, 20) != 15) return 40;
    if (clampU64(5, 10, 20) != 10) return 40;
    if (clampU64(25, 10, 20) != 20) return 40;
    if (clampU64(10, 10, 20) != 10) return 40;
    if (clampU64(20, 10, 20) != 20) return 40;
    if (clampU64(9, 10, 20) != 10) return 40;
    if (clampU64(21, 10, 20) != 20) return 40;
    if (clampU64(7, 7, 7) != 7) return 40;
    if (clampU64(0, 10, 20) != 10) return 40;
    if (clampU64(U64MAX, 10, 20) != 20) return 40;
    if (clampU64(0, 0, U64MAX) != 0) return 40;
    if (clampU64(U64MAX, 0, U64MAX) != U64MAX) return 40;

    // -----------------------------------------------------------------
    // Code 41 — the same clamp at u8, where the top of the range is 255.
    // -----------------------------------------------------------------
    if (clampU8(128, 0, 255) != 128) return 41;
    if (clampU8(0, 1, 254) != 1) return 41;
    if (clampU8(255, 1, 254) != 254) return 41;
    if (clampU8(1, 1, 254) != 1) return 41;
    if (clampU8(254, 1, 254) != 254) return 41;
    if (clampU8(255, 0, 255) != 255) return 41;
    if (clampU8(0, 0, 255) != 0) return 41;

    // -----------------------------------------------------------------
    // Code 42 — three-way compare at u64: 0 below, 1 equal, 2 above. The
    // one place an ordering compare and an equality compare have to agree
    // with each other inside a single function.
    // -----------------------------------------------------------------
    if (cmp3U64(1, 2) != 0) return 42;
    if (cmp3U64(2, 2) != 1) return 42;
    if (cmp3U64(3, 2) != 2) return 42;
    if (cmp3U64(0, 0) != 1) return 42;
    if (cmp3U64(0, U64MAX) != 0) return 42;
    if (cmp3U64(U64MAX, 0) != 2) return 42;
    if (cmp3U64(U64MAX, U64MAX) != 1) return 42;
    if (cmp3U64(U64MAX - 1, U64MAX) != 0) return 42;
    if (cmp3U64(U64MAX, U64MAX - 1) != 2) return 42;

    // -----------------------------------------------------------------
    // Code 43 — three-way compare at u16.
    // -----------------------------------------------------------------
    if (cmp3U16(7, 7) != 1) return 43;
    if (cmp3U16(0, U16MAX) != 0) return 43;
    if (cmp3U16(U16MAX, 0) != 2) return 43;
    if (cmp3U16(U16MAX, U16MAX) != 1) return 43;
    if (cmp3U16(U16MAX - 1, U16MAX) != 0) return 43;
    if (cmp3U16(U16MAX, U16MAX - 1) != 2) return 43;

    // -----------------------------------------------------------------
    // Code 44 — max of three u32. Nested ordering compares with a mutable
    // local; ties must resolve to the equal value either way.
    // -----------------------------------------------------------------
    if (max3U32(1, 2, 3) != 3) return 44;
    if (max3U32(3, 2, 1) != 3) return 44;
    if (max3U32(2, 3, 1) != 3) return 44;
    if (max3U32(0, 0, 0) != 0) return 44;
    if (max3U32(5, 5, 5) != 5) return 44;
    if (max3U32(U32MAX, 0, 0) != U32MAX) return 44;
    if (max3U32(0, U32MAX, 0) != U32MAX) return 44;
    if (max3U32(0, 0, U32MAX) != U32MAX) return 44;
    if (max3U32(U32MAX, U32MAX - 1, U32MAX - 2) != U32MAX) return 44;

    // -----------------------------------------------------------------
    // Code 45 — subtractive GCD: `!=` and `>` in one loop, no division.
    // A wrong predicate either hangs or returns garbage.
    // -----------------------------------------------------------------
    if (gcdU64(12, 18) != 6) return 45;
    if (gcdU64(18, 12) != 6) return 45;
    if (gcdU64(1, 1) != 1) return 45;
    if (gcdU64(2, 1) != 1) return 45;
    if (gcdU64(17, 5) != 1) return 45;
    if (gcdU64(100, 75) != 25) return 45;
    if (gcdU64(270, 192) != 6) return 45;
    if (gcdU64(1000, 35) != 5) return 45;
    // Equal operands: the loop body must never run at all.
    if (gcdU64(U64MAX, U64MAX) != U64MAX) return 45;

    // -----------------------------------------------------------------
    // Code 46 — `<` inside a loop body rather than as the loop's own
    // condition. countBelowU64(n, pivot) is min(n, pivot) the long way.
    // -----------------------------------------------------------------
    if (countBelowU64(10, 3) != 3) return 46;
    if (countBelowU64(3, 10) != 3) return 46;
    if (countBelowU64(0, 5) != 0) return 46;
    if (countBelowU64(5, 0) != 0) return 46;
    if (countBelowU64(5, 5) != 5) return 46;
    if (countBelowU64(100, 50) != 50) return 46;

    return 0;
}
