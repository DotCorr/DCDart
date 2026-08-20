/* main.c -- harness for the DCDart-calls-C direction
 * (docs/decisions/0038-extern-symbols-and-linking.md).
 *
 * Links THREE objects: this one, c_side.o, and the object dcc emitted from
 * extern_calls.dart. The DCDart object references c_side.o's symbols and
 * this file references the DCDart object's symbols, so the link only
 * succeeds if relocations resolve in both directions.
 *
 * Freestanding-safe: <stdint.h> is types only, no libc symbol is referenced,
 * so this same file works under `-nostdlib` (with the harness's _start stub)
 * and under an ordinary native link.
 *
 * Every expected value is derived here independently of the DCDart source.
 * Exit code 0 = all correct; any other code identifies the first check that
 * failed (see the numbering below).
 */
#include <stdint.h>

/* Defined in extern_calls.dart, compiled by dcc. */
extern uint64_t addThroughC(uint64_t a, uint64_t b);
extern uint64_t answerThroughC(void);
extern uint32_t mixThroughC(uint32_t a, uint32_t b);
extern uint8_t  clampThroughC(uint8_t value);
extern uint64_t widenThroughC(uint8_t low, uint32_t mid, uint64_t high);
extern uint64_t recordAndDouble(uint64_t value);
extern uint64_t sumThroughC(uint64_t upTo);
extern uint64_t addThroughCTwice(uint64_t a, uint64_t b);

typedef struct {
    uint64_t tag;
    uint64_t payload;
} dcx_result;

extern dcx_result checkedThroughC(uint64_t value);

/* Defined in c_side.c -- read directly here to prove the void extern call
 * really executed rather than being elided. */
extern uint64_t dcx_last_recorded;
extern uint64_t dcx_record_count;

int main(void) {
    /* 1 -- u64 in / u64 out through a C function. */
    if (addThroughC(2, 3) != 5) return 1;
    if (addThroughC(0, 0) != 0) return 1;
    if (addThroughC(1000000, 2000000) != 3000000) return 1;

    /* 2 -- zero-argument extern. 42 is c_side.c's own constant. */
    if (answerThroughC() != 42) return 2;

    /* 3 -- u32 in / u32 out. The expected value is recomputed here from the
     * formula, not by calling dcx_mix32, so a width bug in the DCDart-side
     * declaration cannot cancel out. */
    for (uint32_t a = 0; a < 40; a++) {
        for (uint32_t b = 0; b < 40; b++) {
            uint32_t expected = (uint32_t)((a * 2654435761u) ^ (b + 0x9E3779B9u));
            if (mixThroughC(a, b) != expected) return 3;
        }
    }
    /* One hand-checked constant, so the loop above is not the only witness:
     * a=1 -> 2654435761 (0x9E3779B1); b=1 -> 0x9E3779BA;
     * 0x9E3779B1 ^ 0x9E3779BA = 0x0000000B = 11. */
    if (mixThroughC(1, 1) != 11u) return 3;

    /* 4 -- u8 in / u8 out, including the clamp boundary. */
    for (unsigned v = 0; v < 256; v++) {
        uint8_t expected = (uint8_t)(v > 200 ? 200 : v);
        if (clampThroughC((uint8_t)v) != expected) return 4;
    }

    /* 5 -- mixed-width parameters in one signature. */
    if (widenThroughC(0, 0, 0) != 0) return 5;
    if (widenThroughC(7, 0, 0) != 7) return 5;
    if (widenThroughC(0, 1, 0) != 256) return 5;
    if (widenThroughC(0, 0, 1) != (1ULL << 40)) return 5;
    if (widenThroughC(255, 65535, 3) !=
        255ULL + (65535ULL << 8) + (3ULL << 40)) return 5;

    /* 6 -- the void extern call, as a statement, with a real side effect. */
    uint64_t before = dcx_record_count;
    if (recordAndDouble(21) != 42) return 6;
    if (dcx_last_recorded != 21) return 6;
    if (dcx_record_count != before + 1) return 6;
    if (recordAndDouble(1000) != 2000) return 6;
    if (dcx_last_recorded != 1000) return 6;
    if (dcx_record_count != before + 2) return 6;

    /* 7 -- an extern call inside a while loop. sum(1..n) = n(n+1)/2. */
    for (uint64_t n = 0; n <= 200; n++) {
        if (sumThroughC(n) != n * (n + 1) / 2) return 7;
    }

    /* 8 -- a struct returned by value FROM C, propagated through DCDart.
     * c_side.c returns Err(999) for 0 and Ok(v+1) otherwise; DCDart's
     * checkedThroughC doubles the Ok payload and passes Err straight out. */
    dcx_result err = checkedThroughC(0);
    if (err.tag != 1) return 8;
    if (err.payload != 999) return 8;
    for (uint64_t v = 1; v < 200; v++) {
        dcx_result ok = checkedThroughC(v);
        if (ok.tag != 0) return 8;
        if (ok.payload != (v + 1) * 2) return 8;
    }

    /* 9 -- DCDart calling DCDart calling C: (a+b)+b. */
    if (addThroughCTwice(2, 3) != 8) return 9;
    for (uint64_t a = 0; a < 30; a++) {
        for (uint64_t b = 0; b < 30; b++) {
            if (addThroughCTwice(a, b) != a + 2 * b) return 9;
        }
    }

    return 0;
}
