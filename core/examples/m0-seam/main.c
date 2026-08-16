// M0 exit criterion (ROADMAP.md): a C main links against add.o and returns 5.
#include <stdint.h>

extern uint64_t add(uint64_t a, uint64_t b);

int main(void) {
    return (int)add(2, 3);
}
