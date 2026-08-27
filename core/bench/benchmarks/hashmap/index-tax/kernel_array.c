/* core/bench/benchmarks/hashmap/index-tax/kernel_array.c
 *
 * THE SAME WORKLOAD, IN C, WITH THE BUCKET TABLE A C PROGRAMMER WOULD WRITE.
 *
 * `hashmap`'s bucket index is a depth-10 binary trie on BOTH sides, because
 * DCDart cannot express an array of ARC-managed references at all (GAP-0061):
 * a managed reference lives only in a field of a `HeapObject`, there is no
 * array type, and there is no way to turn a raw address back into a managed
 * reference. Giving C the array and DCDart the trie would have measured that
 * gap rather than ARC, so both sides walk the trie.
 *
 * That decision has a cost, and a caveat with no number attached is an
 * excuse. This file IS the number: identical keys, identical values,
 * identical operation order, identical checksum -- one indexed load where the
 * benchmark walks ten pointers. `run.sh` times it against `../kernel.c` and
 * the ratio is the INDEX TAX: how much of the benchmark's C baseline is the
 * workaround rather than the hash map.
 *
 * It is NOT a benchmark and it has no manifest.sh, so run-bench.sh does not
 * discover it and it can never contribute to a gate number.
 *
 * Build with -DPHASE_A for the burst kernel, -DPHASE_B for churn.
 */

#include <stdint.h>
#include <stdlib.h>

#define DEPTH   10
#define NBUCKET (1u << DEPTH)
#define WIN     1024

struct VS { uint64_t a[3]; };
struct VM { uint64_t a[12]; };
struct VB { uint64_t a[31]; };

struct Entry {
    uint64_t key;
    uint64_t kind;
    struct Entry *next;
    struct VS *vs;
    struct VM *vm;
    struct VB *vb;
};

static uint64_t hashOf(uint64_t k) {
    uint64_t m = k % 1000003;
    uint64_t x = m * 2654435761;
    uint64_t h = (x >> 13) ^ (x >> 31);
    return h & (NBUCKET - 1);
}

static uint64_t kindOf(uint64_t s, uint64_t total) {
    uint64_t era = (s * 3) / total;
    uint64_t q = s % 10;
    if (era == 0) { if (q < 7) return 0; if (q < 9) return 1; return 2; }
    if (era == 1) { if (q < 4) return 0; if (q < 8) return 1; return 2; }
    if (q < 2) return 0;
    if (q < 6) return 1;
    return 2;
}

static uint64_t valueSum(const struct Entry *e) {
    if (e->kind == 0) { const struct VS *v = e->vs; if (v) return v->a[0] + v->a[2];  return 0; }
    if (e->kind == 1) { const struct VM *v = e->vm; if (v) return v->a[0] + v->a[11]; return 0; }
    const struct VB *v = e->vb; if (v) return v->a[0] + v->a[30]; return 0;
}

static uint64_t chainSum(const struct Entry *e, uint64_t key) {
    if (e->key == key) return valueSum(e);
    if (e->next) return chainSum(e->next, key);
    return 0;
}

static void dropEntry(struct Entry *c) {
    if (c->vs) free(c->vs);
    if (c->vm) free(c->vm);
    if (c->vb) free(c->vb);
    free(c);
}

static uint64_t mapInsert(struct Entry **buckets, uint64_t key, uint64_t kind) {
    uint64_t v = key % 1000003;
    struct Entry *e = malloc(sizeof *e);
    e->key = key; e->kind = kind; e->next = NULL;
    e->vs = NULL; e->vm = NULL; e->vb = NULL;
    if (kind == 0) {
        struct VS *val = malloc(sizeof *val);
        val->a[0] = v; val->a[1] = v; val->a[2] = v;
        e->vs = val;
    } else if (kind == 1) {
        struct VM *val = malloc(sizeof *val);
        for (int i = 0; i < 12; i++) val->a[i] = v;
        e->vm = val;
    } else {
        struct VB *val = malloc(sizeof *val);
        for (int i = 0; i < 31; i++) val->a[i] = v;
        e->vb = val;
    }
    struct Entry **slot = &buckets[hashOf(key)];   /* ONE indexed load */
    e->next = *slot;
    *slot = e;
    return 1;
}

static uint64_t mapLookup(struct Entry **buckets, uint64_t key) {
    struct Entry *h = buckets[hashOf(key)];
    if (h) return chainSum(h, key);
    return 0;
}

static uint64_t mapRemove(struct Entry **buckets, uint64_t key) {
    struct Entry **link = &buckets[hashOf(key)];
    struct Entry *c = *link;
    while (c) {
        if (c->key == key) {
            *link = c->next;
            uint64_t k = c->key;
            dropEntry(c);
            return k;
        }
        link = &c->next;
        c = c->next;
    }
    return 0;
}

#ifdef PHASE_A
uint64_t benchKernel(uint64_t rounds) {
    struct Entry **buckets = calloc(NBUCKET, sizeof *buckets);
    uint64_t total = rounds * WIN;
    uint64_t acc = 0;
    for (uint64_t base = 0; base < total; base += WIN) {
        for (uint64_t j = 0; j < WIN; j++) { uint64_t s = base + j; acc = (acc + mapInsert(buckets, s, kindOf(s, total))) % 1000000007; }
        for (uint64_t j = 0; j < WIN; j++) { uint64_t s = base + j; acc = (acc + mapLookup(buckets, s)) % 1000000007; }
        for (uint64_t j = 0; j < WIN; j++) { uint64_t s = base + j; acc = (acc + mapRemove(buckets, s)) % 1000000007; }
    }
    free(buckets);
    return acc;
}
#else
uint64_t benchKernel(uint64_t rounds) {
    struct Entry **buckets = calloc(NBUCKET, sizeof *buckets);
    uint64_t total = rounds * WIN;
    uint64_t acc = 0;
    for (uint64_t s = 0; s < total; s++) {
        acc = (acc + mapInsert(buckets, s, kindOf(s, total))) % 1000000007;
        acc = (acc + mapLookup(buckets, s)) % 1000000007;
        if (WIN <= s) acc = (acc + mapRemove(buckets, s - WIN)) % 1000000007;
    }
    for (uint64_t d = total - WIN; d < total; d++) acc = (acc + mapRemove(buckets, d)) % 1000000007;
    free(buckets);
    return acc;
}
#endif
