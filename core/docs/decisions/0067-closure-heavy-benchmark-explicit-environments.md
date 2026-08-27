# ADR-0067: The closure-heavy M3 benchmark is written as explicit environment objects, because capture is (correctly) still rejected

**Date:** 2026-08-27
**Status:** accepted
**Unit:** `bench/benchmarks/closure-heavy/` (the fifth and last of M3's suite, GAP-0051b)

## Context

`ROADMAP.md` M3 names "a closure-heavy functional workload" among the five gate benchmarks. Two
facts about closures held on the day this was written, and they pull in opposite directions:

1. **Functions are values** (ADR-0060, GAP-0052 closed): torn off, passed, returned, called
   indirectly, with the ARC convention carried in the pointer's type — and the indirect call is
   NOT an elision barrier (measured, funcptr conformance).
2. **Capture is rejected** — re-probed against this day's compiler rather than read from the gaps
   file: a captured scalar, a captured heap object, and a capturing function torn off as a value
   all fail with ADR-0057's diagnostic. Escalation 0008 §2 (the capture convention) is a rule-4
   memory-model decision that remains undecided, and it must not be decided by a benchmark's
   schedule pressure — that is exactly option 2 of escalation 0008 §4, the one recommended
   against.

So the benchmark cannot be written in capture syntax, and waiting for capture would leave the M3
gate unevaluable for an unknown time over a language decision the gate itself does not need.

## Decision

**Write the workload the way closures compile: a code pointer paired with an explicit heap
environment object.** Per item, three `Env` heap objects are allocated (two scalars +
an optional reference to a shared per-round `Gain` — capture-by-value and capture-of-heap-object,
spelled as fields); every stage is reached through a function pointer selected from run-time data
bits; the previous item's environment outlives its item by one (a one-item rolling window); the
data dependency is serial. `dc_heap_live` returns to 0 (driver-enforced).

**The C baseline keeps its contexts on the stack** — function pointers + caller-owned context
structs is C's natural closure idiom (`qsort_r`, every callback API), and a context that provably
does not escape the iteration goes in a local. Heap-allocating it would be a transliteration of
DCDart's shape, the failure ADR-0059 names (and the tree-traversal malloc baseline already paid
for once, in the other direction). The measured gap is therefore the price of DCDart
heap-allocating and refcounting closure environments, which is the quantity the gate's wording
asks about.

**The AOT column is written with real capturing closures**, because stock Dart has them; it is the
tracing-GC third point of the memory-management comparison and never enters a gate number.

**Two commitments make this honest rather than convenient:**

- `tests/conformance/closure-capture-reject/` pins the rejection, with a failure message that
  names what must happen when capture lands: decide 0008 §2 on the record, rewrite this benchmark
  in capture syntax, re-measure. The explicit-environment spelling then becomes the CONTROL for
  what the capture lowering costs over hand-rolled environments.
- The benchmark's manifest states in its first paragraph what "closure" means here, so the gate
  number cannot be quoted as pricing a language feature that does not exist yet.

## Consequences

- The M3 gate became evaluable on 2026-08-27 (5 of 5 present) without pre-deciding escalation
  0008 §2 — and produced its first real number the same day: **1.3073x vs trap-matched C
  (nonatomic), OVER the <= 1.10x bar** (atomic 1.6534x). The miss is carried by the two
  linked-structure benchmarks (hashmap 2.21x, tree-traversal 2.15x — GAP-0062), not by this one.
  Full record in GAP-0051b.
- Measured (Apple M1 Pro, `BENCH_ARG=2500`): DCDart/nonatomic **1.154x trap-matched C**
  (1.171x plain C; traps cost 1.015x here), atomic 1.704x, stock Dart AOT 2.70x. The
  environment-churn shape is one of DCDart's better benchmarks — the segregated free-list heap
  recycles the three sizes-alike `Env`s cheaply, and the borrowed pairs that survive across
  indirect calls (correctly — funcptr shape 5) are a small fraction of the arithmetic.
- What the number does NOT contain: the cost of a real capture lowering (environment layout,
  capture-time retains, possible weak/unowned capture checks). If capture lands materially more
  expensive than hand-rolled environments, the gate number moves; the rewrite-and-re-measure
  commitment above is what notices.
