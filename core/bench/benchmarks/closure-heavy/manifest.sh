# core/bench/benchmarks/closure-heavy/manifest.sh — sourced by run-bench.sh.

BENCH_ID=closure-heavy
BENCH_DESC="pipeline of data-selected function-pointer stages with heap environments (closure churn)"
BENCH_SUITE=m3
# 2500 rounds x 1024 items: C ~88 ms, trap-matched C ~88 ms, DCDart
# (nonatomic) ~102 ms on the integration host -- everything inside the
# 50-200 ms band and well above the harness's 25 ms floor.
BENCH_ARG=2500

BENCH_NOTE="One of M3's five. Counts toward the gate. THE LAST OF THE FIVE.

WHAT 'CLOSURE' MEANS HERE, stated up front because it decides what the
number means. A CAPTURING closure is still rejected by dcc (probed
2026-08-27; escalation 0008 §2 open -- the capture convention is a rule-4
memory-model decision nobody has made). What exists is ADR-0060: a function
is a VALUE -- torn off, passed, returned, called indirectly (GAP-0052
closed). So this benchmark is written the way closures COMPILE: a code
pointer plus an explicit environment object. DCDart heap-allocates three
Env objects per item (that is where a capturing closure's environment would
live) and reaches every stage through a function pointer selected from
run-time data bits; a shared per-round Gain object is referenced by two of
the three environments (the captured-heap-object half of the workload), and
the previous item's environment is kept alive one item longer (a one-item
rolling window -- a closure outliving its expression). Serial data
dependency throughout: each item's output is the next item's input.

THE C BASELINE KEEPS ITS ENVIRONMENTS ON THE STACK, because function
pointers + caller-owned context structs IS C's natural closure idiom
(qsort_r, every callback API), and a context that provably does not escape
the iteration goes in a local, not through malloc. ADR-0059: the baseline
is what a competent C programmer writes, not a transliteration of DCDart's
shape. The consequence is the measurement: the gap prices DCDart's
environment ALLOCATION plus the ARC traffic through it -- per item, 3
alloc/release, retains on the shared Gain, one heap-reference reassignment
(prev, ADR-0048), and the borrowed pairs that span each indirect call,
which are load-bearing and survive elision (funcptr conformance shape 5).
That is exactly the quantity M3's closure-heavy row exists to price.

BOTH SIDES' STAGE CALLS ARE GENUINELY INDIRECT: the stage is picked from
bits of the live pipeline value, so neither compiler can devirtualize
(the funcptr target's 'dispatch' guarantee). Same selection bits, same
composition order, same modular checksum on every side; the harness
refuses the benchmark if any checksum disagrees.

ARC SHAPE (dc-objdump --arc): benchKernel alloc=4 retain=4 release=7,
Env_dtor release=1 -- real per-item traffic, not a hoisted constant.
dc_heap_live returns to 0 (driver-enforced). Live set is at most 5 small
objects, far inside the default 2 MiB heap.

WHEN CAPTURE LANDS (escalation 0008 §2), rewrite this file in capture
syntax and re-measure -- the explicit-environment spelling then becomes the
control for what the capture lowering costs over hand-rolled environments.

BENCH_AOT is the one side written with REAL capturing closures, because
stock Dart has them and that is its natural idiom -- its per-item
allocations are closure contexts under a tracing GC, the third point of
the memory-management comparison."
