# core/bench/benchmarks/hashmap/manifest.sh — sourced by run-bench.sh.

BENCH_ID=hashmap
BENCH_DESC="hash map under CHURN: 1024-entry rolling window, mixed value sizes"
BENCH_SUITE=m3
BENCH_ARG=800

BENCH_NOTE="One of M3's five. Counts toward the gate. PHASE B of a two-phase
pair; phase A is 'hashmap-burst', which is a diagnostic and enters no mean.

THE PAIR IS THE DESIGN. Both phases run the SAME map, the SAME keys, the SAME
number of inserts, lookups and deletes, and produce the SAME checksum -- which
the harness proves rather than assumes, since it refuses a ratio when two
implementations disagree. They differ ONLY in the order the operations occur:

  hashmap-burst  A  insert 1024, look up 1024, delete 1024   (batched)
  hashmap        B  insert / look up / delete, interleaved   (rolling window)

Because they differ only in allocation pattern, any gap between them IS
allocation, by construction, and needs no argument to establish it.

WHY A PAIR AT ALL. tree-traversal landed the day before this one and came out
2.3x FASTER than C (76.9 ms vs 177.5 ms, matching checksums). That is not ARC
being free: uniform object size, allocated in a burst, freed at once is the
best case for a bump-and-free-list allocator and close to the worst for
malloc. ADR-0058 predicted it in advance as 'the single most likely thing to
make an M3 number look better than a real allocator would'. A hashmap written
the obvious way has the same shape, and two of the gate's five inputs would
then be measuring allocator strategy while the gate's wording says ARC. Phase
B holds the live set steady so both allocators run in recycling mode, which
neutralises that advantage. THE GATE TAKES THE HARSHER OF THE TWO NUMBERS AND
THE FLATTERING ONE IS PRINTED NEXT TO IT.

*** THE DESIGNED EFFECT IS REAL AND IT IS WORTH ABOUT 5%. Phase B came out
*** worse than phase A in ALL SIX runs taken, by a median of 5.5% against
*** plain C. It is not the factor-of-2.3 reversal tree-traversal showed -- the
*** allocator caveat is WORKLOAD-SHAPED, not universal.
***
*** AND THE 5% IS NOT WHAT DECIDES THIS BENCHMARK. Both phases are at ~2.3-2.4x
*** against a gate stated at <=1.10x. Trapping arithmetic costs nothing here
*** (0.97-1.03x) and the allocator costs 5%, so the rest is somewhere else, and
*** it is POINTER CHASING. What this workload is made of is
*** POINTER CHASING, and in DCDart every heap-typed field read into a local is
*** an alias retain (ADR-0017) with a matching release, and NONE of them are
*** elided. ADR-0025's pass 3 is intra-block only, and every nullable heap
*** field read is followed by a branch, so the pair never sits in one block.
*** Roughly 30 unelided retain/release pairs are executed per
*** insert+lookup+delete triple, and the DCDart-vs-C gap divided by that count
*** is about 4 ns per pair, which is what the pair's instruction sequence
*** costs. See docs/decisions/0061-hashmap-benchmark-two-phases.md.

THE BUCKET INDEX IS A BINARY TRIE ON BOTH SIDES, NOT AN ARRAY, AND IT INFLATES
THE NUMBER. DCDart cannot express an array of ARC-managed references at all
(GAP-0061): a managed reference lives only in a field of a HeapObject, there
is no array type, and a raw address cannot be turned back into a managed
reference. So the bucket table is a depth-10 binary trie, and kernel.c walks
the SAME trie so that neither side is chasing more pointers than the other.
The cost of that decision is MEASURED, not waved at: index-tax/ runs the
identical workload in C with a real bucket array, and the trie costs the C
baseline 1.34x. On the DCDart side it costs more than that, because each of
the ten levels is an alias retain/release pair a bucket array would not need.

CHECKSUM. Phase A, phase B, kernel.c, kernel_trapck.c and index-tax's array
variant all return the same value at every round count tested.

DEPTH, WINDOW AND MIX WERE FIXED BEFORE THE FIRST TIMED RUN and are argued
from the workload in ADR-0061: 1024 buckets at load factor 1.0, one eviction
per admission, and three size classes (64/128/512 bytes) whose ratio SHIFTS
across the run so that each class's high-water mark is held simultaneously --
the case ADR-0058's non-coalescing heap handles worst. Nothing was retuned
afterwards.

HEAP CEILING. Peak occupancy of the tightest size class (64 bytes: trie nodes,
entries and small values together) is 3,791 blocks against the shipping
default's 32,768. 8.6x headroom, measured from dc_heap_bump, whose final value
IS that class's high-water mark. --heap-region-bytes is NOT used: a gate
number must describe the configuration DCDart ships.

INTEGRATION NOTE (2026-08-27, merged from the wt-hashmap branch). BENCH_ARG
was resized 600 -> 800 on the integration host so the C baseline clears
run-bench.sh's 50 ms sizing guideline (47 ms at 600); rounds are the sizing
knob and the live set does not depend on them, so DEPTH, WINDOW, MIX and the
heap-ceiling numbers above are untouched. Both phases moved together so the
same-checksum pair property keeps holding in one run. Since the numbers above
were recorded, main landed the GAP-0054 elision correctness fix (ADR-0063)
and the cross-block extension of pass 3 -- the latter recovers ZERO pairs on
this workload (GAP-0062 measured it), so 'none of them are elided' above is
still the truth, now measured rather than inferred from intra-block-ness.
First integrated run at 800 (Apple M-series host, ADR-0063 elision fix in):
DCDart/nonatomic 2.377x plain C / 2.385x trap-matched C, traps cost 0.996x,
atomic 3.000x, stock Dart AOT 2.78x, all five checksums equal (632543358).
Same story as the branch's numbers, slightly kinder -- the ~4% the ADR-0063
fix costs elsewhere does not show here because this workload never had an
elidable pair to lose."
