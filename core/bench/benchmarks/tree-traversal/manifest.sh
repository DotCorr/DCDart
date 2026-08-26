# core/bench/benchmarks/tree-traversal/manifest.sh — sourced by run-bench.sh.

BENCH_ID=tree-traversal
BENCH_DESC="build, walk and drop a 16383-node binary tree (ARC at high-water mark)"
BENCH_SUITE=m3
BENCH_ARG=400

BENCH_NOTE="One of M3's five. Counts toward the gate.

THE BENCHMARK THE ARENA MADE IMPOSSIBLE. A tree needs many objects alive AT
ONCE, which is what separates it from arc-churn, where the heap never holds
more than one object. Under ADR-0015's 64-slot arena the deepest tree
expressible had 63 nodes (GAP-0050). This builds 2^18-1 = 262,143.

WHAT IT MEASURES. Both sides do the same job: allocate a node per tree node,
walk the whole tree, release it. C does malloc-per-node and one recursive
free; DCDart has no free in its source at all -- the destructor cascade
(ADR-0022) fires when the last reference to the root goes away. The gap is
retain/release traffic plus the allocator difference.

*** FIRST RESULT: DCDart IS 2.3x FASTER THAN C ON THIS BENCHMARK. ***
*** DO NOT READ THAT AS A GATE RESULT. IT IS THE ALLOCATOR CAVEAT     ***
*** DOMINATING THE MEASUREMENT, NOT ARC BEING FREE.                   ***

Measured on first run: DCDart 76.9 ms, C 177.5 ms, same tree, matching
checksums. ADR-0058 predicted exactly this and named it the single most likely
thing to make an M3 number look better than a real allocator would. It was
right, and the effect is not small -- it is larger than everything else this
benchmark measures put together.

WHY. This workload is the best possible case for a bump-and-free-list
allocator and close to the worst for malloc: every node is the same size, they
are allocated in a burst, and the whole tree is freed at once. DCDart bumps a
cursor through a pre-zeroed .bss region; malloc maintains size bins,
coalesces neighbours on free, and can return pages to the OS. DCDart is not
faster because ARC is cheap -- it is faster because it is doing LESS WORK, and
the work it skips is work malloc does so that a long-running program with a
shifting size mix does not fragment.

CONSEQUENCE FOR THE GATE. As written, this benchmark is ALLOCATOR-DOMINATED
rather than ARC-dominated, so its ratio is weak evidence about the quantity M3
is asking for. It stays in the suite -- a tree traversal is one of the five
M3 names, and removing a benchmark because its number is inconvenient is worse
than reporting it with this paragraph attached. But whoever reads the gate
number must know that one of its five inputs is measuring an allocator
difference, in DCDart's favour, by a factor larger than the 10% bar itself.

THE ALLOCATOR HALF IS NOT NEUTRAL, in DCDart's favour. Every node here is the
same size and every tree is freed completely -- the case ADR-0058's segregated
size-class heap handles best and the case malloc's coalescing and cross-class
reuse gain least from. A workload with mixed sizes and partial frees would
narrow or reverse that. run-bench.sh prints this caveat next to the number and
it must stay attached to it.

CHECKSUM. Both sides return the same modular sum over every node, and the
harness refuses to report a ratio if they disagree -- so a tree that silently
lost a subtree cannot produce a fast, wrong number.

DEPTH IS FIXED AND ROUNDS ARE THE PARAMETER, so both sides allocate exactly
2^18-1 nodes per round and neither can win by allocating fewer."
