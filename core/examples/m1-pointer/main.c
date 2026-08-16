// M1 exit criterion harness. Proves the write actually landed at the given
// address (not just "the function returned the input value") and the
// read-back matches -- a stronger check than round-tripping through a
// return value alone.
#include <stdint.h>

extern uint32_t mmioRoundTrip(uint64_t address, uint32_t value);

int main(void) {
    uint32_t reg = 0;
    uint32_t result = mmioRoundTrip((uint64_t)&reg, 0xDEADBEEFu);
    if (reg != 0xDEADBEEFu) return 1;    /* store through the pointer didn't happen */
    if (result != 0xDEADBEEFu) return 2; /* load through the pointer didn't match */
    return 0;
}
