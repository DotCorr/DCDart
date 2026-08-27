/* core/bench/benchmarks/hashmap/kernel.c
 *
 * The C baseline for phase B (churn) of the `hashmap` pair.
 *
 * Everything above the kernel is byte-identical to `hashmap-burst/kernel.c`
 * and is checked by `verify-parity.sh`. The two kernels differ only in the
 * ORDER they issue the same operations.
 *
 * THE BUCKET INDEX IS A TRIE HERE TOO, AND THAT IS DELIBERATE. A C programmer
 * writing this would use `struct Entry **buckets` and one indexed load.
 * DCDart cannot: a managed reference lives only in a field of a HeapObject,
 * there is no array type, and a raw address cannot be turned back into a
 * managed reference, so an array of ARC references is inexpressible
 * (GAP-0061). Giving C the array and DCDart the trie would measure that gap
 * instead of ARC, so both sides walk the same trie, and the cost of the trie
 * is measured on its own by `index-tax/` and published in ADR-0061 rather
 * than being folded silently into the gate number.
 *
 * `malloc` is NOT checked for NULL, deliberately and for the same reason
 * `tree-traversal` does not check it: DCDart traps on OOM, so a baseline that
 * branched on every allocation would carry a check DCDart's side does not
 * have, in the hot path, and flatter DCDart.
 */

#include <stdint.h>
#include <stdlib.h>

/* BEGIN-SHARED-MAP */

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

struct Trie {
    struct Trie *c0;
    struct Trie *c1;
    struct Entry *head;
};

static uint64_t hashOf(uint64_t k) {
    uint64_t m = (k % 1000003);
    uint64_t x = (m * 2654435761);
    uint64_t h = (x >> 13) ^ (x >> 31);
    return h & 1023;
}

static uint64_t kindOf(uint64_t s, uint64_t total) {
    uint64_t era = ((s * 3) / total);
    uint64_t q = (s % 10);
    if (era == 0) {
        if (q < 7) return 0;
        if (q < 9) return 1;
        return 2;
    }
    if (era == 1) {
        if (q < 4) return 0;
        if (q < 8) return 1;
        return 2;
    }
    if (q < 2) return 0;
    if (q < 6) return 1;
    return 2;
}

static struct Trie *buildTrie(uint64_t depth) {
    struct Trie *n = malloc(sizeof *n);
    n->head = NULL;
    if (depth == 0) {
        n->c0 = NULL;
        n->c1 = NULL;
    } else {
        n->c0 = buildTrie((depth - 1));
        n->c1 = buildTrie((depth - 1));
    }
    return n;
}

static void dropTrie(struct Trie *n) {
    if (n->c0) dropTrie(n->c0);
    if (n->c1) dropTrie(n->c1);
    free(n);
}

static uint64_t tinsert(struct Trie *n, uint64_t level, uint64_t h, struct Entry *e) {
    if (level == 0) {
        e->next = n->head;
        n->head = e;
        return 1;
    }
    uint64_t bit = (h >> (level - 1)) & 1;
    struct Trie *c = bit == 0 ? n->c0 : n->c1;
    if (c) return tinsert(c, (level - 1), h, e);
    return 0;
}

static uint64_t valueSum(const struct Entry *e) {
    if (e->kind == 0) {
        const struct VS *v = e->vs;
        if (v) return (v->a[0] + v->a[2]);
        return 0;
    }
    if (e->kind == 1) {
        const struct VM *v = e->vm;
        if (v) return (v->a[0] + v->a[11]);
        return 0;
    }
    const struct VB *v = e->vb;
    if (v) return (v->a[0] + v->a[30]);
    return 0;
}

static uint64_t chainSum(const struct Entry *e, uint64_t key) {
    if (e->key == key) return valueSum(e);
    if (e->next) return chainSum(e->next, key);
    return 0;
}

static uint64_t tlookup(const struct Trie *n, uint64_t level, uint64_t h, uint64_t key) {
    if (level == 0) {
        if (n->head) return chainSum(n->head, key);
        return 0;
    }
    uint64_t bit = (h >> (level - 1)) & 1;
    const struct Trie *c = bit == 0 ? n->c0 : n->c1;
    if (c) return tlookup(c, (level - 1), h, key);
    return 0;
}

/* The C side of what ARC does for DCDart: the entry and its value are freed
 * here, by name, at the point the last reference to them goes away. There is
 * no `free` anywhere in bench.dart. */
static void dropEntry(struct Entry *c) {
    if (c->vs) free(c->vs);
    if (c->vm) free(c->vm);
    if (c->vb) free(c->vb);
    free(c);
}

static uint64_t unlinkFrom(struct Entry *p, uint64_t key) {
    struct Entry *c = p->next;
    if (!c) return 0;
    if (c->key == key) {
        p->next = c->next;
        uint64_t k = c->key;
        dropEntry(c);
        return k;
    }
    return unlinkFrom(c, key);
}

static uint64_t unlinkHead(struct Trie *n, uint64_t key) {
    struct Entry *h0 = n->head;
    if (!h0) return 0;
    if (h0->key == key) {
        n->head = h0->next;
        uint64_t k = h0->key;
        dropEntry(h0);
        return k;
    }
    return unlinkFrom(h0, key);
}

static uint64_t tremove(struct Trie *n, uint64_t level, uint64_t h, uint64_t key) {
    if (level == 0) return unlinkHead(n, key);
    uint64_t bit = (h >> (level - 1)) & 1;
    struct Trie *c = bit == 0 ? n->c0 : n->c1;
    if (c) return tremove(c, (level - 1), h, key);
    return 0;
}

static uint64_t mapInsert(struct Trie *root, uint64_t key, uint64_t kind) {
    uint64_t v = (key % 1000003);
    struct Entry *e = malloc(sizeof *e);
    e->key = key;
    e->kind = kind;
    e->next = NULL;
    e->vs = NULL;
    e->vm = NULL;
    e->vb = NULL;
    if (kind == 0) {
        struct VS *val = malloc(sizeof *val);
    val->a[0] = v;
    val->a[1] = v;
    val->a[2] = v;
        e->vs = val;
    } else if (kind == 1) {
        struct VM *val = malloc(sizeof *val);
    val->a[0] = v;
    val->a[1] = v;
    val->a[2] = v;
    val->a[3] = v;
    val->a[4] = v;
    val->a[5] = v;
    val->a[6] = v;
    val->a[7] = v;
    val->a[8] = v;
    val->a[9] = v;
    val->a[10] = v;
    val->a[11] = v;
        e->vm = val;
    } else {
        struct VB *val = malloc(sizeof *val);
    val->a[0] = v;
    val->a[1] = v;
    val->a[2] = v;
    val->a[3] = v;
    val->a[4] = v;
    val->a[5] = v;
    val->a[6] = v;
    val->a[7] = v;
    val->a[8] = v;
    val->a[9] = v;
    val->a[10] = v;
    val->a[11] = v;
    val->a[12] = v;
    val->a[13] = v;
    val->a[14] = v;
    val->a[15] = v;
    val->a[16] = v;
    val->a[17] = v;
    val->a[18] = v;
    val->a[19] = v;
    val->a[20] = v;
    val->a[21] = v;
    val->a[22] = v;
    val->a[23] = v;
    val->a[24] = v;
    val->a[25] = v;
    val->a[26] = v;
    val->a[27] = v;
    val->a[28] = v;
    val->a[29] = v;
    val->a[30] = v;
        e->vb = val;
    }
    return tinsert(root, 10, hashOf(key), e);
}

static uint64_t mapLookup(const struct Trie *root, uint64_t key) {
    return tlookup(root, 10, hashOf(key), key);
}

static uint64_t mapRemove(struct Trie *root, uint64_t key) {
    return tremove(root, 10, hashOf(key), key);
}

/* END-SHARED-MAP */

uint64_t benchKernel(uint64_t rounds) {
    struct Trie *root = buildTrie(10);
    uint64_t total = (rounds * 1024);
    uint64_t acc = 0;
    for (uint64_t s = 0; s < total; s = (s + 1)) {
        acc = ((acc + mapInsert(root, s, kindOf(s, total))) % 1000000007);
        acc = ((acc + mapLookup(root, s)) % 1000000007);
        if (1024 <= s) {
            acc = ((acc + mapRemove(root, (s - 1024))) % 1000000007);
        }
    }
    for (uint64_t d = (total - 1024); d < total; d = (d + 1)) {
        acc = ((acc + mapRemove(root, d)) % 1000000007);
    }
    dropTrie(root);
    return acc;
}
