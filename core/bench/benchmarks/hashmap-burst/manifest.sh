# core/bench/benchmarks/hashmap-burst/manifest.sh — sourced by run-bench.sh.

BENCH_ID=hashmap-burst
BENCH_DESC="hash map in BURST: bulk insert, bulk lookup, bulk teardown"
BENCH_SUITE=diagnostic
BENCH_ARG=800

BENCH_NOTE="NOT one of M3's five, and run-bench.sh keeps it out of every
geometric mean. PHASE A of the two-phase 'hashmap' pair; phase B is the gate
input.

It performs EXACTLY the same work as 'hashmap' -- same map, same keys, same
insert/lookup/delete counts, same checksum -- batched instead of interleaved.
The map implementation is byte-identical between the two directories and
verify-parity.sh fails if that ever stops being true.

WHY IT IS A DIAGNOSTIC AND NOT A SECOND GATE INPUT. It is built to be the
allocator's best case and malloc's worst: 1024 entries and 1024 values
allocated back to back with nothing freed in between, then all of them freed
before the next round starts. tree-traversal has that shape and came out 2.3x
faster than C. Putting a benchmark of that shape into a geometric mean that
claims to measure ARC imports an allocator advantage into the number. So it is
published, next to the gate input, and averaged into nothing.

WHAT IT ACTUALLY SHOWED. It DID favour DCDart, and by much less than expected:
phase A beat phase B in all six runs taken, by a median of 5.5% against plain C
(2.28x vs 2.37x). So the effect this pair was built to expose is real -- and it
is worth 5% of a 2.4x, not the factor-of-2.3 reversal tree-traversal showed.
The allocator caveat is WORKLOAD-SHAPED: tree-traversal is allocation-dominated
because allocation is most of what it does; a hash map is not, because
allocation is a minority of what a map operation costs. What a map operation IS
made of is pointer chasing, and in DCDart every heap field read into a local is
a retain/release pair that ADR-0025's intra-block pass 3 does not elide.
That is where the 2.4x is. See docs/decisions/0061-hashmap-benchmark-two-phases.md."
