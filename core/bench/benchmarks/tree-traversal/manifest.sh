# core/bench/benchmarks/tree-traversal/manifest.sh — sourced by run-bench.sh.

BENCH_ID=tree-traversal
BENCH_DESC="build, walk and drop a 16383-node binary tree (ARC at high-water mark)"
BENCH_SUITE=m3
# 400 rounds was sized against the malloc-per-node C baseline (~155 ms). The
# 2026-08-27 arena baseline is ~5x faster (~33 ms), too close to the harness's
# 25 ms floor to hold noise under 2.5% on a shared machine. 1200 rounds puts
# the shortest side near 100 ms. Checksum depends on the arg, so all sides
# still compute the same value.
BENCH_ARG=1200

BENCH_NOTE="One of M3's five. Counts toward the gate.

THE BENCHMARK THE ARENA MADE IMPOSSIBLE. A tree needs many objects alive AT
ONCE, which is what separates it from arc-churn, where the heap never holds
more than one object. Under ADR-0015's 64-slot arena the deepest tree
expressible had 63 nodes (GAP-0050). This builds 2^14-1 = 16,383 per round
(depth 13; see bench.dart for why not deeper).

WHAT IT MEASURES. Both sides do the same job: allocate a node per tree node,
walk the whole tree, release it. C pools its nodes in a static arena and
drops the tree by resetting the cursor; DCDart has no free in its source at
all -- the destructor cascade (ADR-0022) fires when the last reference to the
root goes away. The gap is retain/release traffic plus the per-node release
work the cascade does that an arena does not.

BASELINE REWRITTEN 2026-08-27. The first C baseline was malloc-per-node with
one recursive free, and DCDart measured 0.45x of it -- 2.2x FASTER than C.
That number was the baseline's weakness, not DCDart's strength: this workload
(fixed-size nodes, burst allocation, wholesale drop) is the textbook arena
case, and idiomatic C tree code pools its nodes (obstacks, slab caches,
LLVM's BumpPtrAllocator). Rewriting the baseline as a static pool with a
bump cursor -- same node count, same build recurrence, same walk order, same
checksum, enforced by the harness -- made the C side 5x faster on the same
machine (~155 ms -> ~33 ms at 400 rounds) and flipped the ratio:

  before (malloc baseline):  DCDart/C 0.45x   DCDart/Ctrap 0.46x
  after  (arena baseline):   DCDart/C 2.37x   DCDart/Ctrap 2.34x   traps 1.01x
  (clean run 2026-08-27, all four configs under the noise gate: C 98.2 ms,
   Ctrap 99.6 ms, DCDart/nonatomic 232.9 ms, DCDart/atomic 300.2 ms at 1200
   rounds; atomic is 3.06x vs C, 3.01x vs Ctrap)

The 5x delta was all malloc bookkeeping being charged to the baseline. The
old number's caveat ('allocator-dominated, weak evidence for the gate') was
correct and is now resolved by construction rather than by warning label.

WHAT THE NEW RATIO MEANS. Trap cost is ~1.01x here (pointer-chasing hides
the checks), so the ~2.34x residual is the real ARC + heap price: a retain/release
pair per edge on build, refcount traffic on the walk, a per-node destructor
cascade on drop, plus ADR-0058's 64-byte size class (24 bytes of fields +
16-byte header, rounded up) against C's 24-byte packed pool nodes. C's O(1)
arena reset vs DCDart's O(n) cascade is not an unfairness -- per-node release
work C does not need is precisely the quantity this benchmark prices.

THE ARENA IS STILL NOT A NEUTRAL ALLOCATOR COMPARISON, now in C's favour
rather than DCDart's: a static pool sized to the tree cannot serve mixed
sizes or partial frees, which DCDart's general heap can. That is the natural
asymmetry of comparing a language's general allocator to what a C programmer
writes for the specific workload, and it is the honest direction for a
baseline to be strong in.

CHECKSUM. Both sides return the same modular sum over every node, and the
harness refuses to report a ratio if they disagree -- so a tree that silently
lost a subtree cannot produce a fast, wrong number.

DEPTH IS FIXED AND ROUNDS ARE THE PARAMETER, so both sides allocate exactly
2^14-1 nodes per round and neither can win by allocating fewer."
