/* main_libc.c -- harness for the DCDart-calls-REAL-LIBC direction
 * (docs/decisions/0038-extern-symbols-and-linking.md).
 *
 * Ordinary hosted link: this file + dcc's object + the system libc. No
 * -nostdlib, no entry stub. Unlike main.c's companion `c_side.c`, nothing
 * here supplies the symbols DCDart calls -- libc does.
 *
 * Expected values are stated as constants, hand-derived, not recomputed by
 * calling the same libc function this program is testing.
 *
 * Exit 0 = all correct; other codes identify the first failing check.
 */
#include <stdint.h>
#include <stdio.h>

extern uint32_t lowestSetBit(uint32_t mask);
extern uint32_t upper(uint32_t c);
extern uint32_t shout(void);
extern uint32_t sumLowestSetBits(uint32_t upTo);

int main(void) {
    /* 1 -- ffs, hand-derived. ffs returns a 1-BASED bit index, 0 for zero.
     *   0      -> 0
     *   1      -> 1   (bit 0)
     *   40     -> 4   (40 = 0b101000, lowest set bit is bit 3)
     *   1024   -> 11  (bit 10)
     *   96     -> 6   (96 = 0b1100000, lowest set bit is bit 5)
     *   0x80000000 is avoided: it is negative as a C int (see the
     *   signedness note in libc_calls.dart). */
    if (lowestSetBit(0) != 0) return 1;
    if (lowestSetBit(1) != 1) return 1;
    if (lowestSetBit(40) != 4) return 1;
    if (lowestSetBit(1024) != 11) return 1;
    if (lowestSetBit(96) != 6) return 1;

    /* 2 -- toupper. Letters change, everything else passes through. */
    if (upper('a') != 'A') return 2;
    if (upper('z') != 'Z') return 2;
    if (upper('A') != 'A') return 2;
    if (upper('7') != '7') return 2;
    if (upper(' ') != ' ') return 2;

    /* 3 -- sum of ffs(i) for i in 1..16, hand-derived:
     *   i : 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
     *   ffs 1 2 1 3 1 2 1 4 1  2  1  3  1  2  1  5
     *   sum = 1+2+1+3+1+2+1+4+1+2+1+3+1+2+1+5 = 31 */
    if (sumLowestSetBits(16) != 31) return 3;
    if (sumLowestSetBits(0) != 0) return 3;
    if (sumLowestSetBits(1) != 1) return 3;

    /* 4 -- putchar, checked by RETURN value here; the run.sh harness checks
     * the actual bytes on stdout separately, which is the part that proves
     * the side effect left this process.
     * 'D'+'C'+'D'+'A'+'R'+'T'+'\n' = 68+67+68+65+82+84+10 = 444 */
    fflush(stdout);
    if (shout() != 444) return 4;
    fflush(stdout);

    return 0;
}
