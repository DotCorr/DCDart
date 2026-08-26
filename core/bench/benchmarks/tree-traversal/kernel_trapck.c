/* core/bench/benchmarks/tree-traversal/kernel_trapck.c
 *
 * `tree-traversal` in C with DCDart's TRAPPING arithmetic semantics. This is
 * the GATE baseline (ADR-0059): the <= 10% bar is measured against this, so
 * that it isolates ARC rather than also charging DCDart for arithmetic
 * semantics C does not have.
 *
 * Identical to kernel.c in every other respect -- same malloc-per-node, same
 * recursive free, same checksum. The only difference is the arithmetic.
 *
 * (Original note, still true of both files: unlike `arc-churn`'s it required
 * no judgement call: a C programmer solving this problem allocates nodes and
 * frees them, so the baseline does exactly that. `malloc` per node, one
 * recursive `free` at the end.
 *
 * That makes this the FIRST benchmark in this tree whose C side and DCDart
 * side are doing the same job, which is why it is one of M3's five and
 * `arc-churn` is not. The gap it measures is DCDart's retain/release traffic
 * plus the difference between ADR-0058's segregated size-class heap and
 * glibc/macOS malloc -- exactly the quantity the gate is about.
 *
 * THE ALLOCATOR HALF OF THAT GAP IS NOT NEUTRAL AND CANNOT BE MADE SO. The
 * DCDart heap has no coalescing and no cross-class reuse; malloc has both and
 * pays for them. Every node here is the same size and every tree is freed
 * completely, which is the case DCDart's allocator handles best and malloc
 * gains least from. run-bench.sh prints this caveat next to the number.
 *
 * malloc is NOT checked for NULL, deliberately: DCDart traps on OOM, so a
 * baseline that branched on every allocation would carry a check DCDart's
 * side does not have, in the hot path, and flatter DCDart.
 */

#include <stdint.h>
#include <stdlib.h>
#include "trapping.h"

struct Node {
    uint64_t value;
    struct Node *left;
    struct Node *right;
};

static struct Node *build(uint64_t depth, uint64_t label) {
    struct Node *n = malloc(sizeof(struct Node));
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

/* DCDart's equivalent is the destructor cascade (ADR-0022) firing when the
 * last reference to the root goes away -- no explicit free exists in the
 * DCDart source at all. This is the C work that ARC is replacing. */
static void drop(struct Node *n) {
    if (n->left) drop(n->left);
    if (n->right) drop(n->right);
    free(n);
}

uint64_t benchKernel(uint64_t rounds) {
    uint64_t acc = 0;
    for (uint64_t i = 0; i < rounds; i++) {
        struct Node *t = build(13, 1);
        acc = mod_ck(add_ck(acc, walk(t)), 1000000007);
        drop(t);
    }
    return acc;
}
