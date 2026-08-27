/* core/bench/benchmarks/tree-traversal-malloc/kernel.c
 *
 * THE OTHER HALF OF THE TREE-TRAVERSAL MEASUREMENT. Identical DCDart source
 * to `tree-traversal`; the only difference is this C baseline, which does
 * malloc-per-node with one recursive free instead of bump-allocating from an
 * arena.
 *
 * WHY BOTH EXIST, and why neither is "the" baseline:
 *
 * ADR-0059's ruling was not "isolate ARC" in the abstract. Over three
 * alternatives the owner chose: NAME EACH COST AS WHAT IT IS, rather than
 * letting one number quietly contain two unrelated things. The trapping-
 * arithmetic column exists for that reason -- neither folded into the ARC
 * ratio nor discarded. Allocator strategy is the same case one axis over.
 *
 *   tree-traversal          arena C. THE GATE INPUT. Both sides bump-
 *                           allocate, so the ratio isolates ARC, which is
 *                           the quantity the gate names.
 *   tree-traversal-malloc   malloc-per-node C. DIAGNOSTIC. What a C
 *                           programmer would actually write for this
 *                           problem, and the first question an outside
 *                           reader asks.
 *
 * THE DIFFERENCE BETWEEN THE TWO ROWS IS THE ALLOCATOR-STRATEGY COST,
 * isolated -- which is a real and interesting number that neither row can
 * report alone.
 *
 * This baseline was the original one, and against it DCDart came out ~2.3x
 * FASTER. That was not a win: it measured ADR-0058's segregated size classes
 * against malloc's coalescing on the workload most flattering to the first
 * and least to the second, and it dominated everything else in the benchmark
 * combined. Replacing it with an arena was correct FOR THE GATE. Deleting it
 * would have been wrong, because "we changed the baseline and the number
 * improved" is indistinguishable from moving the goalposts once it is read
 * without its reasoning -- and it will be read without its reasoning.
 * Nobody who changed a baseline to flatter themselves also prints the
 * unflattering one next to it.
 *
 * malloc is not NULL-checked, deliberately: DCDart traps on OOM, so a
 * baseline branching on every allocation would carry a hot-path check the
 * DCDart side does not have.
 */

#include <stdint.h>
#include <stdlib.h>

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
        n->left = build(depth - 1, label * 2);
        n->right = build(depth - 1, label * 2 + 1);
    }
    return n;
}

static uint64_t walk(const struct Node *n) {
    uint64_t total = n->value % 1000003;
    if (n->left) total = total + walk(n->left);
    if (n->right) total = total + walk(n->right);
    return total % 1000000007;
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
        acc = (acc + walk(t)) % 1000000007;
        drop(t);
    }
    return acc;
}
