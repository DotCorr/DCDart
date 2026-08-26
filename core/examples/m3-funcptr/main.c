/* Function-pointer / indirect-call harness
 * (docs/decisions/0060-function-pointers-and-indirect-calls.md).
 *
 * Two things are being checked and they are not the same thing.
 *
 * BEHAVIOUR (here): a call through a function pointer computes what the
 * equivalent direct call computes, a pointer selected at run time reaches the
 * function it names, and no path leaks. Baseline is `dc_heap_live == 0` --
 * ADR-0058's segregated size-class heap's LIVE-object count, incremented by
 * Alloc and decremented when a block goes back on its free list, so zero means
 * nothing is live in any size class. Read as uint64_t: it is a 64-bit counter
 * and reading it as 32 bits would silently ignore the high half.
 *
 * ELISION (run.sh): that `viaFuncPtr` -- the SAME program as `viaTopLevel`
 * with the consuming callee reached through a pointer instead of a name --
 * emits the identical ARC instruction counts. That claim cannot be made from
 * here: two programs can agree on every value while one of them retains and
 * releases twice as often, which is exactly what docs/escalations/0008 §3
 * predicted an indirect call would be forced to do.
 *
 * No stdio: on Linux/x86-64 this links `-nostdlib` (see
 * tests/conformance/_lib/hosted-link.sh), so the exit code is the whole
 * report. Codes are listed in run.sh's step 3.
 */
#include <stdint.h>

extern uint64_t dc_heap_live;

extern uint64_t dblTwice(uint64_t x);
extern uint64_t incTwice(uint64_t x);
extern uint64_t localTearOff(uint64_t x);
extern uint64_t dispatch(uint64_t which, uint64_t x);
extern uint64_t viaTopLevel(uint64_t v);
extern uint64_t viaClosure(uint64_t v);
extern uint64_t viaFuncPtr(uint64_t v);
extern uint64_t viaTopFuncPtr(uint64_t v);
extern uint64_t borrowViaFuncPtr(uint64_t v);
extern uint64_t voidCallback(uint64_t v);

/* Shape 1 also has to be callable FROM C, because a DCDart function-pointer
 * parameter is an ordinary C-ABI `ptr` argument (spec §9) and nothing about
 * that should be special. If the calling convention were wrong this is where
 * it shows up, rather than only inside DCDart-to-DCDart calls where both ends
 * would be wrong in the same way and agree. */
extern uint64_t applyTwice(uint64_t (*f)(uint64_t), uint64_t x);
static uint64_t c_square(uint64_t v) { return v * v; }

int main(void) {
    if (dc_heap_live != 0) return 1; /* not at baseline before any call */

    /* Shape 1 -- a function-pointer PARAMETER, called through the value. */
    for (uint64_t x = 0; x < 200; x++) {
        if (dblTwice(x) != 4 * x) return 2;
        if (incTwice(x) != x + 2) return 3;
    }

    /* Shape 1b -- the same DCDart higher-order function, handed a C function
       pointer. 15^2 = 225, 225^2 = 50625; both well inside 64 bits. */
    if (applyTwice(c_square, 15) != 50625) return 4;

    /* Shape 2 -- a LOCAL function torn off into a value and called through
       it. ADR-0057 rejected the tear-off outright. */
    for (uint64_t x = 0; x < 200; x++) {
        if (localTearOff(x) != 3 * x) return 5;
    }

    /* Shape 3 -- a pointer chosen at RUN TIME and returned across a function
       boundary. This is the shape no optimizer can devirtualize inside one
       body, so the object really does contain an indirect branch. */
    for (uint64_t x = 0; x < 200; x++) {
        if (dispatch(0, x) != 2 * x) return 6;
        if (dispatch(1, x) != x + 1) return 7;
    }

    /* Shape 4 -- the elision triple, plus the top-level tear-off spelling.
       All four are the same program. The live count is checked after EVERY
       call, so one leaked object per call is caught on the first iteration
       instead of having to accumulate until something runs out. */
    for (uint64_t v = 0; v < 500; v++) {
        uint64_t a = viaTopLevel(v);
        if (dc_heap_live != 0) return 8;
        uint64_t b = viaClosure(v);
        if (dc_heap_live != 0) return 9;
        uint64_t c = viaFuncPtr(v);
        if (dc_heap_live != 0) return 10;
        uint64_t d = viaTopFuncPtr(v);
        if (dc_heap_live != 0) return 11;
        if (a != v || b != v || c != v || d != v) return 12;
    }

    /* Shape 5 -- the BORROWED direction. The retain/release pair spanning
       this call is load-bearing; if elision wrongly dropped it, the object
       would be freed while `b` still points at it and the live count would go
       WRONG (negative-wrapped or double-decremented), not merely non-zero. */
    for (uint64_t v = 0; v < 500; v++) {
        if (borrowViaFuncPtr(v) != v) return 13;
        if (dc_heap_live != 0) return 14;
    }

    /* Shape 6 -- a void callback invoked for effect, in statement position. */
    for (uint64_t v = 0; v < 500; v++) {
        if (voidCallback(v) != v) return 15;
        if (dc_heap_live != 0) return 16;
    }

    return 0;
}
