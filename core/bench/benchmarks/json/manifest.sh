# core/bench/benchmarks/json/manifest.sh — sourced by run-bench.sh.

BENCH_ID=json
BENCH_DESC="parse a 60 KB nested JSON document into a heap tree, walk it, drop it"
BENCH_SUITE=m3
BENCH_ARG=1500

# ROUNDS RAISED 600 -> 1500 on 2026-08-27, and the reason is worth keeping.
#
# At 600 the DCDart kernel measured 24.257 ms against a 25 ms floor and was
# REFUSED -- not for noise, but for being too FAST to measure. C ran 41.3 ms,
# comfortably over. So the one benchmark in the suite where DCDart beats C was
# also the one the harness could not time, which meant NO GATE NUMBER COULD BE
# PRODUCED AT ALL: a geometric mean over the survivors is a different quantity
# from the one M3 asks for, and run-bench.sh correctly refuses to print it.
#
# The failure mode is worth naming because it is counter-intuitive: a timing
# floor rejects the FASTEST configuration first, so the better an
# implementation gets on a benchmark, the more likely that benchmark drops out
# of the mean -- silently improving the reported number of whatever survives.

BENCH_NOTE="One of M3's five. Counts toward the gate.

EXERCISES THE MOST OF DCDart AT ONCE: heap objects with nullable heap fields,
recursion, sibling chains, Str-style borrowed slices into the input, and a
destructor cascade over a tree of mixed shapes.

STRINGS ARE NOT COPIED, on either side. A string value is an offset and a
length into the input buffer, which is how fast parsers actually work and what
Str (ADR-0053) is shaped for. Copying would measure Heap.allocate throughput a
second time, which string-pass already measures deliberately and better.

C GETS A UNION AND DCDart DOES NOT, and that costs DCDart on purpose. DCDart
has no sum types, no unions and no variant records, so its JNode carries a
kind tag plus every field any kind might need -- 6 words against C's 3. Giving
the baseline a DCDart-shaped node would import DCDart's limitation into the
baseline and flatter DCDart, which is the failure ADR-0059 exists to prevent.
DCDart therefore allocates a larger node, and that is a real cost of the
language today, charged to it.

GAP-0054 WATCH. parseValue returns a node it also holds in a local -- the
get-then-mutate shape where ADR-0025's pass 3 can elide a pair across a
Release of an aliasing value, safe today only because _releaseHeapLocals runs
after the return expression, which is a property of the LOWERING rather than
of the pass. If this benchmark returns a wrong checksum or double-frees, that
is the first place to look, and it is a real find rather than an obstacle.

THREE LANGUAGE GAPS WERE HIT WRITING IT, all worked around in the DCDart
source and used freely on the C side: ConditionalExpression (? :),
LogicalExpression (&& and ||), and u64 has no / (only ~/). Worth counting --
the gate is partly a claim about writing real programs, and every one of these
shapes the DCDart source away from what the algorithm wants.

CHECKSUM. Both sides fold the same fields of every node in the same order, so
a parse that dropped or misclassified nodes cannot produce a fast, wrong
number."
