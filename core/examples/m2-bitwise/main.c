// M2 bitwise-operator harness (docs/decisions/0030-bitwise-operators.md).
// Unlike Port I/O, these are ordinary instructions -- real execution and
// an exact expected-value check, not a disassembly-only structural one.
#include <stdint.h>

extern uint64_t andU64(uint64_t a, uint64_t b);
extern uint64_t orU64(uint64_t a, uint64_t b);
extern uint64_t xorU64(uint64_t a, uint64_t b);
extern uint64_t shlU64(uint64_t a, uint64_t b);
extern uint64_t shrU64(uint64_t a, uint64_t b);
extern uint32_t andU32(uint32_t a, uint32_t b);
extern uint16_t andU16(uint16_t a, uint16_t b);
extern uint8_t  andU8(uint8_t a, uint8_t b);

int main(void) {
    for (uint64_t a = 0; a < 300; a++) {
        for (uint64_t b = 0; b < 300; b += 7) {
            if (andU64(a, b) != (a & b)) return 1;
            if (orU64(a, b) != (a | b)) return 2;
            if (xorU64(a, b) != (a ^ b)) return 3;
        }
    }

    for (uint64_t a = 0; a < 64; a++) {
        for (uint64_t shift = 0; shift < 20; shift++) {
            if (shlU64(a, shift) != (a << shift)) return 4;
            uint64_t wide = a * 1000000ULL;
            if (shrU64(wide, shift) != (wide >> shift)) return 5;
        }
    }

    if (andU32(0xF0F0F0F0u, 0x0FF00FF0u) != (0xF0F0F0F0u & 0x0FF00FF0u)) return 6;
    if (andU16(0xFF00u, 0x0FF0u) != (uint16_t)(0xFF00u & 0x0FF0u)) return 7;
    if (andU8(0xF0u, 0x0Fu) != (uint8_t)(0xF0u & 0x0Fu)) return 8;

    return 0;
}
