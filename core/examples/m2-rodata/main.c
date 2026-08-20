/* Conformance harness for static read-only data (ADR-0040).
 *
 * Reads DCDart's `@rodata` tables the way the real consumer does -- by
 * address and stride through a raw pointer -- and checks every value against
 * a hard-coded expectation. Declarations come from the generated header
 * (ADR-0034), so a wrong emitted type is a compile error here rather than
 * silent ABI corruption. */
#include <stdint.h>
#include <stdio.h>
#include "rodata.h"

static int fails = 0;

static void ck(const char *name, uint64_t got, uint64_t want) {
    if (got != want) {
        printf("  FAIL %s: got %llu (0x%llx) want %llu (0x%llx)\n", name,
               (unsigned long long)got, (unsigned long long)got,
               (unsigned long long)want, (unsigned long long)want);
        fails++;
    }
}

int main(void) {
    /* u64 table, read at stride 8. If a length word or class pointer were
     * emitted in front of element 0, every one of these would be shifted --
     * which is exactly why they are checked by value rather than by eye. */
    ck("baseAt(0)", baseAt(0), 0x100000);
    ck("baseAt(1)", baseAt(1), 0x200000);
    ck("baseAt(2)", baseAt(2), 0x400000);
    ck("baseAt(3)", baseAt(3), 0x800000);

    ck("lengthAt(0)", lengthAt(0), 0x100000);
    ck("lengthAt(1)", lengthAt(1), 0x200000);
    ck("lengthAt(2)", lengthAt(2), 0x400000);
    ck("lengthAt(3)", lengthAt(3), 0x1000000);

    /* u32 table -- proves the element width comes from the DECLARED type,
     * not from the values. Every value here also fits in a u8, so a
     * compiler emitting the wrong width would still produce plausible
     * numbers at index 0 and garbage afterwards. */
    ck("typeAt(0)", typeAt(0), 1);
    ck("typeAt(1)", typeAt(1), 2);
    ck("typeAt(2)", typeAt(2), 1);
    ck("typeAt(3)", typeAt(3), 1);

    /* u8 table -- the tightest stride, where any hidden padding shows up. */
    ck("flagAt(0)", flagAt(0), 0xDE);
    ck("flagAt(1)", flagAt(1), 0xAD);
    ck("flagAt(2)", flagAt(2), 0xBE);
    ck("flagAt(3)", flagAt(3), 0xEF);

    /* A real loop over static data: sum the lengths of type-1 regions.
     * 0x100000 + 0x400000 + 0x1000000 = 0x1500000 = 22020096. */
    ck("totalUsable", totalUsable(), 0x1500000);

    /* Two distinct tables must have two distinct addresses. This is the
     * identity property `final` (rather than `const`) exists to buy: the
     * frontend canonicalizes identical `const` declarations into ONE object,
     * and a linker may merge byte-identical `unnamed_addr` globals. Either
     * would make this return 0. */
    ck("tablesAreDistinct", tablesAreDistinct(), 1);

    /* Internal relocations: the directory holds the ADDRESSES of the other
     * three tables, filled in by the linker. Dereferencing through it must
     * reach the same values the direct accessors return. */
    ck("viaDirectory(0,0)", viaDirectory(0, 0), 0x100000);
    ck("viaDirectory(0,3)", viaDirectory(0, 3), 0x800000);
    ck("viaDirectory(1,3)", viaDirectory(1, 3), 0x1000000);

    printf(fails ? "RODATA: %d FAILURES\n" : "RODATA: all correct\n", fails);
    return fails != 0;
}
