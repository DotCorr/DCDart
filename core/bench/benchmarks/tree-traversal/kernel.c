/* core/bench/benchmarks/tree-traversal/kernel.c
 *
 * The C baseline for `tree-traversal`. REWRITTEN 2026-08-27: the first
 * version did malloc-per-node with one recursive free, and that baseline was
 * WEAK -- DCDart measured 0.446x of it, i.e. 2.2x FASTER than C, which for a
 * managed-ARC language on a tree walk is not a result, it is a symptom. The
 * BENCH_NOTE said so from the first run ("allocator-dominated"); this fixes
 * the baseline instead of leaving the caveat to do the work.
 *
 * THE NATURAL C IDIOM FOR THIS WORKLOAD IS AN ARENA (POOL), NOT MALLOC.
 * Every node is the same size, the whole tree is built in one burst, and the
 * whole tree is dropped at once. That is the textbook arena case, and it is
 * what real C tree code does -- compilers (obstacks, LLVM's BumpPtrAllocator),
 * parsers (apr pools), kernels (slab caches) all pool their nodes. A C
 * programmer who calls malloc 16,383 times to build a tree they will free
 * wholesale is writing naive C, not idiomatic C, and a baseline is only a
 * baseline if it is the program a competent C programmer would write.
 * Measured on the first run's machine: malloc-per-node ~168 ms, this arena
 * ~33 ms for the same 400 rounds and the same checksum -- the old baseline
 * was 5x slower than natural C, and ALL of that 5x was being credited to
 * DCDart.
 *
 * WHAT IS UNCHANGED -- the harness enforces the checksum and the shape is by
 * construction: same node count (2^14-1 = 16,383 per round, depth fixed at
 * 13), same recursive build with the same label recurrence, same recursive
 * walk in the same left-then-right order, same modular checksum. Only where
 * the bytes come from changed.
 *
 * DROP IS O(1) AND THAT IS THE POINT, NOT AN OMISSION. An arena frees by
 * resetting the cursor; per-node free is the thing the idiom exists to avoid.
 * DCDart's drop is the destructor cascade (ADR-0022) visiting every node --
 * that per-node release traffic is precisely the ARC cost this benchmark
 * exists to price, and it is now priced against what C actually does instead,
 * rather than hidden under malloc's own per-node bookkeeping.
 *
 * The pool is NOT bounds-checked, same stance as the old baseline's unchecked
 * malloc: the tree size is exact by construction (build(13) allocates exactly
 * NODE_COUNT nodes), and a per-allocation branch C does not need would
 * flatter DCDart, whose allocator does carry a bump bounds check (ADR-0058).
 *
 * The pool is static (.bss), like the DCDart heap's pre-zeroed region. Note
 * what C still gets for free here that DCDart pays for: a Node is 24 bytes
 * with no header, so the pool packs nodes at 24-byte pitch, while DCDart's
 * 16-byte object header pushes its nodes into the 64-byte size class.
 */

#include <stdint.h>
#include <stddef.h>

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
        acc = (acc + walk(t)) % 1000000007;
        drop(t);
    }
    return acc;
}
