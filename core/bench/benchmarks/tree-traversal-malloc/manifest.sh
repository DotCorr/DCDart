# core/bench/benchmarks/tree-traversal-malloc/manifest.sh — sourced by run-bench.sh.

BENCH_ID=tree-traversal-malloc
BENCH_DESC="tree-traversal against malloc-per-node C (allocator-strategy diagnostic)"
BENCH_SUITE=diagnostic
BENCH_ARG=1200

BENCH_NOTE="NOT one of M3's five. Its ratio is NOT a gate number and
run-bench.sh keeps it out of every geometric mean.

IDENTICAL DCDart SOURCE TO tree-traversal. The only difference is the C
baseline: malloc-per-node with one recursive free, instead of bump-allocating
from an arena. So THE DIFFERENCE BETWEEN THE TWO ROWS IS THE
ALLOCATOR-STRATEGY COST, isolated -- a real number neither row can report
alone.

WHY BOTH EXIST. ADR-0059's ruling was not 'isolate ARC' in the abstract; over
three alternatives the owner chose NAME EACH COST AS WHAT IT IS rather than
letting one number quietly contain two unrelated things. The trapping-
arithmetic column exists for that reason -- neither folded in nor discarded.
Allocator strategy is the same case one axis over:

  tree-traversal          arena C.  THE GATE INPUT. Both sides bump-allocate,
                          so the ratio isolates ARC, the quantity the gate
                          names.
  tree-traversal-malloc   malloc C. DIAGNOSTIC. What a C programmer would
                          actually write for this problem, and the first
                          question an outside reader asks.

AGAINST THIS BASELINE DCDart CAME OUT ~2.3x FASTER, and that was not a win.
It measured ADR-0058's segregated size classes against malloc's coalescing on
the workload most flattering to the first and least to the second, and it
dominated everything else in the benchmark combined. Replacing it with an
arena was correct FOR THE GATE. Deleting it would have been wrong: 'we changed
the baseline and the number improved' is indistinguishable from moving the
goalposts once it is read without its reasoning, and it will be read without
its reasoning. Nobody who changed a baseline to flatter themselves also prints
the unflattering one next to it.

CHECKSUM. Same tree, same depth (13), same rounds as tree-traversal, so all
implementations here and there agree -- the harness refuses a ratio otherwise."
