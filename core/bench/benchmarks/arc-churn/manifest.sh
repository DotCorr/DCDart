# core/bench/benchmarks/arc-churn/manifest.sh — sourced by run-bench.sh.

BENCH_ID=arc-churn
BENCH_DESC="allocate + release one short-lived heap object per iteration"
BENCH_SUITE=diagnostic
BENCH_ARG=12000000

BENCH_NOTE="NOT one of M3's five. Its ratio is NOT evidence about the gate and
run-bench.sh keeps it out of every geometric mean.

What it IS for: it is the only benchmark in this tree today that executes ARC at
all, so it is the only one where the atomic/non-atomic question has a number
attached. Escalation 0007 §5 condition 2 asks for exactly one thing -- the price
of making retain/release atomic -- and this is the smallest program that produces
it.

Read its DCDart:C ratio as an UPPER BOUND on nothing and a LOWER BOUND on nothing.
It is an unrepresentative microbenchmark by construction: the C side does the
natural C thing (a value on the stack, no allocator, no refcount), because that is
what 'overhead vs C' means -- a C programmer solving this does not refcount. The
gap is therefore alloc + release + trapping arithmetic + the compiler's failure to
elide, all at once, on a loop that does almost nothing else. Real code amortises
all of it. A hashmap benchmark would not look like this, which is precisely why
M3 asks for a hashmap benchmark and not for this."
