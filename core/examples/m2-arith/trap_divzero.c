// M2 arithmetic TRAP harness (docs/decisions/0035-complete-integer-
// operators.md's "`*` traps on overflow like `+`/`-`", docs/decisions/
// 0036-division-and-remainder.md's "Both TRAP on a zero divisor").
//
// Separate from main.c on purpose: a trap KILLS the process, so a trapping
// call can never share a binary with the value checks -- the first trap would
// take the whole suite's exit code with it. Each run of this program performs
// exactly ONE trapping call and is EXPECTED to be killed by a signal.
//
// The mode is selected by argc so one tiny source covers all three trap
// kinds without argument parsing (no strings in @bare DCDart, and this file
// stays deliberately trivial):
//
//   argc == 1  ->  divU64(n, 0)   integer division by zero
//   argc == 2  ->  remU64(n, 0)   remainder by zero
//   argc >= 3  ->  mulU64(...)    multiplication overflowing u64
//
// A `return` from any of these means the trap did NOT fire, and the caller
// (tests/conformance/m2-arith/run.sh) fails the run: it asserts the process
// was KILLED BY A SIGNAL, never that it returned some particular code. The
// return values below are distinct only so a non-trapping regression is
// diagnosable; none of them is ever an accepted outcome.
//
// `volatile` on the operands is not decoration: without it the host C
// compiler is free to constant-fold the arguments, and while it cannot fold
// away the call to an external DCDart function, keeping the values opaque
// makes it unambiguous that a runtime-computed zero reaches the callee --
// the same situation real code hits.
#include <stdint.h>

extern uint64_t divU64(uint64_t a, uint64_t b);
extern uint64_t remU64(uint64_t a, uint64_t b);
extern uint64_t mulU64(uint64_t a, uint64_t b);

int main(int argc, char **argv) {
    (void)argv;

    volatile uint64_t zero = 0;
    volatile uint64_t numerator = 1071;
    volatile uint64_t big = 0x8000000000000000ull;  // 2^63
    volatile uint64_t three = 3;
    volatile uint64_t sink = 0;

    if (argc == 1) {
        sink = divU64(numerator, zero);
        return sink == 0 ? 40 : 41;   // reached => `~/` did not trap
    }
    if (argc == 2) {
        sink = remU64(numerator, zero);
        return sink == 0 ? 42 : 43;   // reached => `%` did not trap
    }
    sink = mulU64(big, three);        // 2^63 * 3 does not fit in u64
    return sink == 0 ? 44 : 45;       // reached => `*` did not trap
}
