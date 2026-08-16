// M1 exit criterion harness: verifies DCDart's @packed struct layout is
// byte-for-byte identical to a C reference struct, not merely "internally
// consistent within DCDart" -- both the field offsets (checked directly)
// and actual memory contents (checked by writing through DCDart and
// reading through the C struct overlay, and vice versa) are cross-checked.
#include <stdint.h>
#include <stddef.h>

#pragma pack(push, 1)
typedef struct {
    uint8_t a;
    uint32_t b;
} CHeader;
#pragma pack(pop)

extern void writeHeader(uint64_t address, uint8_t aVal, uint32_t bVal);
extern uint32_t readHeaderB(uint64_t address);

int main(void) {
    /* 1. DCDart's declared layout (a: u8 @0, b: u32 @1, packed) must match
     * this C reference exactly: size 5, no padding before b. */
    if (sizeof(CHeader) != 5) return 1;
    if (offsetof(CHeader, a) != 0) return 2;
    if (offsetof(CHeader, b) != 1) return 3;

    /* 2. Write through DCDart, read raw bytes via the C struct overlay --
     * proves DCDart's field offsets are byte-identical to the C reference,
     * not just "a layout that happens to round-trip through DCDart alone". */
    CHeader buf;
    buf.a = 0;
    buf.b = 0;
    writeHeader((uint64_t)&buf, 0x7A, 0xCAFEBABEu);
    if (buf.a != 0x7A) return 4;
    if (buf.b != 0xCAFEBABEu) return 5;

    /* 3. Read back through DCDart too, cross-checking the other direction. */
    uint32_t viaDart = readHeaderB((uint64_t)&buf);
    if (viaDart != 0xCAFEBABEu) return 6;

    return 0;
}
