/* core/bench/benchmarks/json/kernel.c
 *
 * The C baseline for `json`.
 *
 * IT USES A UNION, AND THAT IS DELIBERATE AND COSTS DCDart. DCDart has no sum
 * types, no unions and no variant records, so its JNode carries a kind tag
 * plus every field any kind might need -- 6 words. A C programmer writes a
 * tagged union and gets a smaller node. Giving the baseline a DCDart-shaped
 * node would import DCDart's limitation into the baseline and flatter DCDart,
 * which is the failure ADR-0059 exists to prevent. So C gets the union, C
 * allocates less per node, and that difference is a real cost of the language
 * today, correctly charged to it.
 *
 * STRINGS ARE NOT COPIED on either side -- a string value is an offset and a
 * length into the input buffer, which is how fast parsers actually work and
 * what `Str` (ADR-0053) is shaped for. Copying would measure allocator
 * throughput a second time, which `string-pass` already does deliberately.
 *
 * malloc is not NULL-checked: DCDart traps on OOM, so a baseline branching on
 * every allocation would carry a hot-path check DCDart does not have.
 */

#include <stdint.h>
#include <stdlib.h>

enum { J_NUM = 0, J_STR = 1, J_ARR = 2 };

struct JNode {
    uint64_t kind;
    union {
        uint64_t number;
        struct { uint64_t offset, length; } str;
        struct JNode *first;
    } as;
    struct JNode *next;
};

struct Parser {
    const unsigned char *buf;
    uint64_t pos;
    uint64_t len;
};

static struct JNode *node_new(uint64_t kind) {
    struct JNode *n = malloc(sizeof(struct JNode));
    n->kind = kind;
    n->next = NULL;
    return n;
}

static struct JNode *parse_value(struct Parser *p);

static void skip_ws(struct Parser *p) {
    while (p->pos < p->len) {
        unsigned char c = p->buf[p->pos];
        if (c != 32 && c != 10 && c != 9) return;
        p->pos++;
    }
}

static struct JNode *parse_number(struct Parser *p) {
    uint64_t v = 0;
    while (p->pos < p->len) {
        unsigned char c = p->buf[p->pos];
        if (c < 48 || c > 57) break;
        v = (v * 10 + (c - 48)) % 1000000007;
        p->pos++;
    }
    struct JNode *n = node_new(J_NUM);
    n->as.number = v;
    return n;
}

static struct JNode *parse_string(struct Parser *p) {
    p->pos++; /* opening quote */
    uint64_t start = p->pos;
    while (p->pos < p->len && p->buf[p->pos] != 34) p->pos++;
    struct JNode *n = node_new(J_STR);
    n->as.str.offset = start;
    n->as.str.length = p->pos - start;
    if (p->pos < p->len) p->pos++; /* closing quote */
    return n;
}

static struct JNode *parse_array(struct Parser *p) {
    p->pos++; /* '[' */
    struct JNode *arr = node_new(J_ARR);
    arr->as.first = NULL;
    struct JNode *tail = NULL;
    while (p->pos < p->len) {
        skip_ws(p);
        unsigned char c = p->buf[p->pos];
        if (c == 93) { p->pos++; return arr; }
        if (c == 44) { p->pos++; continue; }
        struct JNode *child = parse_value(p);
        if (!tail) arr->as.first = child; else tail->next = child;
        tail = child;
    }
    return arr;
}

static struct JNode *parse_value(struct Parser *p) {
    skip_ws(p);
    unsigned char c = p->buf[p->pos];
    if (c == 34) return parse_string(p);
    if (c == 91) return parse_array(p);
    return parse_number(p);
}

/* Folds exactly the fields DCDart's walk folds, in the same order, so the two
 * checksums are comparable. A union member that is not live for a kind reads
 * as whatever that kind stored, which is why each branch is explicit. */
static uint64_t walk(const struct JNode *n) {
    uint64_t h = n->kind;
    uint64_t number = (n->kind == J_NUM) ? n->as.number : 0;
    uint64_t strlen_ = (n->kind == J_STR) ? n->as.str.length : 0;
    h = (h * 31 + number) % 1000000007;
    h = (h * 31 + strlen_) % 1000000007;
    if (n->kind == J_ARR && n->as.first) h = (h + walk(n->as.first)) % 1000000007;
    if (n->next) h = (h + walk(n->next)) % 1000000007;
    return h;
}

/* DCDart has no explicit free here at all -- the destructor cascade
 * (ADR-0022) fires when the last reference to the root goes away. This is the
 * C work ARC is replacing. */
static void drop(struct JNode *n) {
    if (n->kind == J_ARR && n->as.first) drop(n->as.first);
    if (n->next) drop(n->next);
    free(n);
}

static uint64_t gen_doc(unsigned char *dst) {
    uint64_t i = 0, x = 7;
    dst[i++] = 91;
    for (uint64_t group = 0; group < 300; group++) {
        if (group != 0) dst[i++] = 44;
        dst[i++] = 91;
        for (uint64_t k = 0; k < 6; k++) {
            if (k != 0) dst[i++] = 44;
            x = (x * 1103515245 + 12345) % 2147483648u;
            if (x % 2 == 0) {
                for (uint64_t d = 0; d < 4; d++) {
                    dst[i++] = (unsigned char)(48 + (x / 10) % 10);
                    x = x / 7 + 3;
                }
            } else {
                dst[i++] = 34;
                for (uint64_t d = 0; d < 5; d++) dst[i++] = (unsigned char)(97 + (x + d) % 26);
                dst[i++] = 34;
            }
        }
        dst[i++] = 93;
    }
    dst[i++] = 93;
    return i;
}

uint64_t benchKernel(uint64_t rounds) {
    const uint64_t cap = 65000;
    unsigned char *doc = malloc(cap);
    uint64_t len = gen_doc(doc);

    uint64_t acc = 0;
    for (uint64_t r = 0; r < rounds; r++) {
        struct Parser p = { doc, 0, len };
        struct JNode *root = parse_value(&p);
        acc = (acc + walk(root)) % 1000000007;
        drop(root);
    }
    free(doc);
    return acc;
}
