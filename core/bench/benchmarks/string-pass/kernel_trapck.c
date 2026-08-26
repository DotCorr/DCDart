/* core/bench/benchmarks/string-pass/kernel.c
 *
 * `string-pass` in C with DCDart's TRAPPING arithmetic semantics. THIS IS THE
 * GATE BASELINE (ADR-0059) -- the <= 10% bar is measured against this file so
 * that it isolates ARC and the allocator rather than also charging DCDart for
 * arithmetic semantics C does not have. `kernel.c` is identical except for
 * the arithmetic, and its number is published separately as the trapping cost.
 *
 * (Original note, true of both files: a realloc-backed growable buffer, which
 * is what a C programmer writes for this, and the reason this benchmark is a
 * useful counterweight to `tree-traversal`.
 *
 * THE ALLOCATOR COMPARISON HERE RUNS THE OTHER WAY. `tree-traversal` is
 * uniform-size, burst-allocate, bulk-free -- the best case for DCDart's
 * segregated size classes and close to the worst for malloc, and DCDart came
 * out 2.3x FASTER, which measured the allocator rather than ARC.
 *
 * Growth reallocation inverts it. `realloc` can frequently EXTEND A BLOCK IN
 * PLACE when the following space is free -- no copy at all. DCDart's classes
 * are fixed powers of two and a block never grows, so every doubling is
 * allocate-new-class + copy-everything + free-old, unconditionally
 * (ADR-0058). This is the case DCDart's allocator handles WORST.
 *
 * Neither benchmark is neutral; that is the point of having both. Reporting
 * only the flattering one would be the failure ADR-0059 exists to prevent.
 *
 * malloc/realloc are not NULL-checked, deliberately: DCDart traps on OOM, so
 * a baseline branching on every allocation would carry a hot-path check the
 * DCDart side does not have.
 */

#include <stdint.h>
#include <stdlib.h>
#include "trapping.h"

struct Buf {
    unsigned char *data;
    uint64_t length;
    uint64_t capacity;
};

static void buf_push(struct Buf *b, unsigned char byte) {
    if (b->length == b->capacity) {
        b->capacity = mul_ck(b->capacity, 2);
        b->data = realloc(b->data, b->capacity);
    }
    b->data[b->length] = byte;
    b->length = b->length + 1;
}

/* Identical recurrence to bench.dart's, so both sides start from the same
 * bytes and pay the same generation cost. */
static void gen_input(unsigned char *dst, uint64_t n) {
    uint64_t x = 12345;
    for (uint64_t i = 0; i < n; i++) {
        x = mod_ck(add_ck(mul_ck(x, 1103515245), 12345), 2147483648u);
        uint64_t b = mod_ck(x, 64);
        uint64_t ch = 44;
        if (b != 0) ch = add_ck(97, mod_ck(b, 26));
        dst[i] = (unsigned char)ch;
    }
}

static uint64_t transform(const unsigned char *in, uint64_t n, struct Buf *out) {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < n; i++) {
        uint64_t c = in[i];
        if (c != 44) {
            uint64_t up = sub_ck(c, 32);
            buf_push(out, (unsigned char)up);
            sum = mod_ck(add_ck(mul_ck(sum, 31), up), 1000000007);
        }
    }
    return sum;
}

uint64_t benchKernel(uint64_t rounds) {
    const uint64_t input_len = 60000;
    unsigned char *input = malloc(input_len);
    gen_input(input, input_len);

    uint64_t acc = 0;
    for (uint64_t r = 0; r < rounds; r++) {
        struct Buf out;
        out.capacity = 64;
        out.length = 0;
        out.data = malloc(out.capacity);
        acc = mod_ck(add_ck(acc, transform(input, input_len, &out)), 1000000007);
        free(out.data);
    }
    free(input);
    return acc;
}
