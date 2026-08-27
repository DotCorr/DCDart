/* core/bench/benchmarks/tree-traversal/kernel_trapck.c
 *
 * `tree-traversal` in C with DCDart's TRAPPING arithmetic semantics. This is
 * the GATE baseline (ADR-0059): the <= 10% bar is measured against this, so
 * that it isolates ARC rather than also charging DCDart for arithmetic
 * semantics C does not have.
 *
 * Identical to kernel.c in every other respect -- same arena pool, same
 * recursive build, same walk, same O(1) drop, same checksum. The only
 * difference is the arithmetic. Read kernel.c's header for why the baseline
 * is an arena and not malloc-per-node (rewritten 2026-08-27; the malloc
 * baseline was 5x slower than natural C and made DCDart look 2.2x faster
 * than C on a tree walk, which was the allocator, not ARC).
 *
 * The pool bump in node_alloc is NOT routed through trapping.h: allocation
 * is runtime work, not user arithmetic. On the DCDart side the equivalent
 * bump lives inside the ADR-0058 allocator the compiler emits, not in
 * bench.dart's source, and trapck matches the semantics of the SOURCE
 * program's arithmetic only.
 */

#include <stdint.h>
#include <stddef.h>
#include "trapping.h"

struct Node {
    uint64_t value;
    struct Node *left;
    struct Node *right;
};

/* A complete binary tree of depth 13: 2^14 - 1 nodes. benchKernel below
 * builds exactly this depth every round; the pool is sized to it exactly. */
#define TREE_DEPTH 13
#define NODE_COUNT ((size_t)((1u << (TREE_DEPTH + 1)) - 1))

static struct Node pool[NODE_COUNT];
static size_t pool_next;

static struct Node *node_alloc(void) {
    return &pool[pool_next++];
}

static struct Node *build(uint64_t depth, uint64_t label) {
    struct Node *n = node_alloc();
    n->value = label;
    if (depth == 0) {
        n->left = NULL;
        n->right = NULL;
    } else {
        n->left = build(sub_ck(depth, 1), mul_ck(label, 2));
        n->right = build(sub_ck(depth, 1), add_ck(mul_ck(label, 2), 1));
    }
    return n;
}

static uint64_t walk(const struct Node *n) {
    uint64_t total = mod_ck(n->value, 1000003);
    if (n->left) total = add_ck(total, walk(n->left));
    if (n->right) total = add_ck(total, walk(n->right));
    return mod_ck(total, 1000000007);
}

/* Arena drop: reset the cursor. DCDart's equivalent is the destructor cascade
 * (ADR-0022) releasing every node when the last reference to the root goes
 * away -- the per-node work C's idiom does not have is the quantity the
 * benchmark measures. */
static void drop(struct Node *n) {
    (void)n;
    pool_next = 0;
}

uint64_t benchKernel(uint64_t rounds) {
    uint64_t acc = 0;
    for (uint64_t i = 0; i < rounds; i++) {
        struct Node *t = build(TREE_DEPTH, 1);
        acc = mod_ck(add_ck(acc, walk(t)), 1000000007);
        drop(t);
    }
    return acc;
}
