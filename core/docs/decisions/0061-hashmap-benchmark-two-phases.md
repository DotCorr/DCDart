# ADR-0061: `hashmap` is two phases, only one of them is a gate input — and the allocator turns out not to be what decides it

**Status:** decided under delegated authority — implemented and measured. The effect it was built to
expose is real and worth ~5%; the benchmark is decided by something else entirely, which is §4b

M3's second benchmark of five. It exists because `tree-traversal` landed the day before it and came
out **2.3× faster than C**, and because ADR-0058 had already named the reason that would happen.

---

## 1. Context — one of the gate's five inputs was already measuring the wrong thing

`ROADMAP.md` M3's exit criterion is a geometric mean over five named benchmarks, and the milestone is
titled **ARC**. `tree-traversal`'s first result:

```
DCDart   76.9 ms
C       177.5 ms        same tree, matching checksums
```

That is not ARC being free. Every node the same size, allocated in a burst, freed at once is the best
possible case for a bump-and-free-list allocator and close to the worst for `malloc`. ADR-0058 said so
in advance, in its own "What this does NOT do" section: no coalescing, no cross-class reuse, and
**"this is the single most likely thing to make an M3 number look better than a real allocator
would."** It was right, and the effect was larger than everything else that benchmark measured put
together.

A hash map written the obvious way — uniform buckets, bulk allocation, bulk teardown — has the same
shape, only more so. Written that way, **two of the gate's five inputs would be measuring allocator
strategy while the gate's own wording says ARC**, and the geometric mean would stop meaning what the
gate says it means.

---

## 2. Decision — a pair, and the gate takes the harsher half

Two benchmark directories, one map implementation, **identical logical work**:

| id | suite | phase | shape |
|---|---|---|---|
| `hashmap-burst` | `diagnostic` | **A** | insert 1024, look up 1024, delete 1024 — batched |
| `hashmap` | **`m3`** | **B** | insert / look up / delete, interleaved over a rolling 1024 window |

Same map, same keys, same insert/lookup/delete counts, same checksum. **They differ only in the order
the operations occur in.** That is the whole design: if the two sides differ only in allocation
pattern, then any gap between them *is* allocation, by construction, and needs no argument.

**Phase B is the gate input. Phase A is published beside it and excluded from every geometric mean** —
the same treatment `arc-churn` already gets (`BENCH_SUITE=diagnostic`, and `report.awk` skips that
suite when it computes a mean). Phase A is *by construction* the allocator's best case, so putting it
in a mean that claims to be about ARC imports an allocator advantage into the number.

**This is also what disposes of the rigging worry.** Phase B is the half most open to the accusation
that it was tuned until it produced a worse number. Both halves are published, and **the gate takes
the harsher one.** Nobody rigs a benchmark against themselves and then prints the flattering variant
next to it.

### Rejected, so the choice is legible later

| option | why not |
|---|---|
| one benchmark, the obvious burst shape | Two of five gate inputs then measure the allocator. This is the thing being fixed |
| two numbers, neither in the mean | The gate IS a geometric mean over five ids. `hashmap` would contribute nothing and the gate would stay unevaluable |
| both phases in the mean | `hashmap` counted twice, one of the two counts allocator-dominated |
| average A and B into one number | Meaningless *precisely because* the two effects were designed to point in opposite directions |

---

## 3. Phase B's parameters, fixed before the first timed run

Written down first and argued from the workload, not from the ratio. Nothing below was retuned after
seeing a number; `BENCH_ARG` (rounds) was chosen afterwards and is a *duration* control only — it
scales total work and is identical in both phases, which the harness requires anyway to keep each
iteration in the 50–200 ms band.

| parameter | value | why, on workload grounds |
|---|---|---|
| buckets | 1024 (trie depth 10) | load factor 1.0 against the window below, which is the textbook default for a chained map |
| live window | 1024 entries | a **bounded cache**: the canonical steady-state hash-map workload, and large enough that phase A's batch is a genuine allocation burst |
| delete ratio | 1 delete per insert | steady state — one eviction per admission. Anything else is a growing map, which is phase A with extra steps |
| value sizes | 3 classes: 64 / 128 / 512 bytes | must **straddle** ADR-0058's size classes. 40, 48 and 56-byte values all land in the 64-byte class and the allocator behaves exactly as in the uniform case |
| size mix | **shifts** across the run, in three eras (70/20/10 → 40/40/20 → 20/40/40) | a stationary mix lets every class reach its high-water mark early and hold it, which the heap handles as well as any other allocator. A shifting mix is the case a no-coalescing, no-cross-class-reuse heap handles *worst* |
| load factor 1.0 | chosen over 4.0 | **the integrity-critical one.** With longer chains, phase A's delete batch walks shrinking chains while phase B's walks steady-state ones — B would do more chain work than A for a reason that is not allocation, and "B is slower" would have a second explanation. At load factor 1 that asymmetry is under one hop |

**Heap ceiling, sized against the shipping default deliberately.** The tightest size class (64 bytes:
trie nodes, entries and small values together) peaks at **3,791 blocks of 32,768** — 11.6%, 8.6×
headroom. `--heap-region-bytes` is **not used**: a gate number must describe the configuration DCDart
ships, not one tuned until the benchmark fits. The measurement is not an estimate — `dc_heap_bump` is
a per-class cursor that never retreats, so its final value *is* that class's high-water mark.

---

## 4. What actually happened — the designed effect is real and small, and it is not what decides the number

### 4a. The designed effect is real, and it is worth about 5% of a 2.3×

Six independent runs. The harness's noise gates accepted different subsets of configurations on
different runs (§6), so the table below is the median across all six, with the full range beside it.

| quantity | phase A (burst) | phase B (churn) | B vs A |
|---|---|---|---|
| **DCDart / trap-matched C** — *the gate quantity* (ADR-0059) | **≈ 2.32×** (2.28–2.34) | **≈ 2.39×** (2.33–2.49) | **+2.5%**, worse in 4 of 6 runs |
| DCDart / plain C | ≈ 2.28× (2.22–2.36) | ≈ 2.37× (2.35–2.53) | **+5.5%**, worse in **6 of 6 runs** |
| DCDart *atomic* / plain C | ≈ 2.79× (2.73–3.30) | ≈ 3.05× (2.97–3.10) | +9% |
| trapping-arithmetic cost (Ctrap / C) | 0.99× (0.97–1.03) | 1.00× (0.97–1.02) | — |

**The pair's designed effect is present and it is small.** Against plain C — the pair of
configurations the harness measured most reliably — phase B is worse than phase A **in every one of
six runs**, by a median of 5.5%. Six of six in one direction is not a coincidence at any reasonable
significance, and in the run the harness fully accepted (§6) the gap was 6.4% against a combined
uncertainty of ±1.6%.

Against the *gate* baseline the same direction shows in four runs of six, weaker — because
trap-matched C was the single noisiest configuration measured and the harness refused it more often
than anything else. That is a limitation of the measurement, not a second result.

**So: the allocator advantage phase A was built to expose is real, and on this workload it is worth
about 5% of a 2.3× total.** It is not the factor-of-2.3 reversal `tree-traversal` showed. That is the
finding, and it is more useful than a loud confirmation would have been: **the allocator caveat is
workload-shaped, not universal.** `tree-traversal` is allocation-dominated because allocation is most
of what it does; a hash map is not, because allocation is a minority of what a map operation costs.
A caveat generalised from one benchmark now has a second data point telling it where it applies and
how much it is worth there.

**And the number underneath the 5% is the one that matters.** Both phases are at ~2.3–2.4× against a
gate stated at ≤ 1.10×. Whatever the allocator is doing, it is not what decides this benchmark.

### 4b. Where the 2.3× actually is: unelided alias retains on pointer chasing

The trapping-arithmetic column rules out arithmetic (0.97–1.03×; DCDart's trap checks cost nothing
measurable on this workload). §4a accounts for the allocator and prices it at ~5%. So ~2.3× of the
~2.4× is neither, and what is left is **retain/release traffic — far more of it than the source
suggests.**

In DCDart, reading a heap-typed field into a local is an **alias retain** (ADR-0017) with a matching
release at scope exit. Every level of a structure traversal therefore costs a pair:

```dart
final c = n.c0;                    // retain
if (c != null) {
  return tinsert(c, level - u64(1), h, e);
}                                  // release, after the call returns
```

The descent is **recursive rather than a loop for exactly this reason** — a `HeapObject` parameter is
borrowed by default (ADR-0019) so the call itself costs nothing, whereas a loop reassigning a
heap-typed local (`var n = root; … n = c;`) is a heap reference assignment (ADR-0048) and costs a pair
per level as well. Recursion was chosen and it did not help: the *field read* is the retain, and it
happens either way.

**None of these pairs are elided.** ADR-0025's pass 3 is intra-block, and the null test that every
nullable heap field read requires ends the block before the release can be matched. At least **30
unelided retain/release pairs execute per insert+lookup+delete triple**, ~10 per operation from the
descent alone. Dividing the DCDart-minus-trap-matched-C gap by the executed pair count gives **~3.5 ns
per pair**, about 11 cycles at this machine's clock — which is what that pair's instruction sequence
costs (null test, header load, add/sub, store; and on the release side a zero test, a destructor-pointer
load, a weak-count load and a free-list push).

So the arithmetic closes: **essentially the entire 2.3× is unelided ARC on pointer chasing.** Spec
§3.2 calls elision "the whole ballgame"; this is the first benchmark in the tree with enough ARC in it
for that claim to be tested, and the answer is that on the dominant shape in a container, elision does
not fire at all.

---

## 5. The number is inflated by a language gap, and the inflation is measured

**DCDart cannot express an array of ARC-managed references.** A managed reference lives only in a
field of a `HeapObject`; there is no array type; and there is no way to turn a raw address back into
a managed reference, so `Heap.allocate` cannot back one either. **O(1) indexed access to managed
objects is inexpressible.** GAP-0061, and escalation 0010, because the honest fix is a language
change rather than a lowering.

So `hashmap`'s bucket table is a **complete binary trie of depth 10** and `kernel.c` walks the *same
trie*, because a baseline chasing fewer pointers would measure the data structure rather than the
language. That choice is defensible only with a number attached, so `index-tax/` runs the identical
workload in C with a real bucket array — same keys, same values, same order, same checksum:

```
phase       trie (ms)   array (ms)        tax
A              53.106       39.637     1.340x
B              52.215       39.080     1.336x
```

**The trie costs the C baseline 1.34×.** It costs the DCDart side considerably more, because each of
the ten levels is one of the unelided alias-retain pairs from §4b that a bucket array would not need
at all: an array-indexed map would execute roughly 1–2 such pairs per operation instead of ~10.

**Consequence, stated plainly rather than buried:** `hashmap`'s contribution to the gate is dominated
by a workaround for a missing language feature, not by ARC as a real program would meet it. The
benchmark is honest — both sides do identical work and the checksums prove it — but the *quantity* it
measures is "ARC over a structure DCDart was forced to build" rather than "ARC over the structure a
programmer would write". Whoever reads the M3 gate number needs this paragraph next to it, and
`manifest.sh` prints it.

---

## 6. Measurement conditions — read §4a as directional, and know which parts are not

The machine was loaded throughout (load average 4.7–14 on 8 cores; another agent session and a
browser). `run-bench.sh` gates on interquartile noise ≤ 2.5%, half-split drift ≤ 2.5% and ratio
uncertainty ≤ 2.0%, and it **refused most of the ratios in §4a**, on most runs, almost always because
of a C-side configuration. There is deliberately no automatic retry in the harness and none was added;
six runs were taken by hand and all six are reported, not the best of them.

**What the harness did accept**, at its own thresholds:

| run | between-batch drift | accepted |
|---|---|---|
| 4 | 0.950% | **A: DCDart/C = 2.291× ±1.1%** and **B: DCDart/C = 2.439× ±1.2%** — the cleanest direct A-vs-B comparison here, +6.4% against ±1.6% combined |
| 6 | 0.397% | B's DCDart (noise 1.05%) and B's trap-matched C (noise 0.91%) both accepted → **B's gate quantity = 2.436×**; A's atomic ratio 2.792× ±0.6% |
| 5 | 1.822% | B's atomic ratio **3.011× ±1.9%**; A's C and trap-matched C both accepted |

**Treat every ratio in §4a as directional to about ±5%.** The conclusions it supports — ~2.3–2.4×,
an order of magnitude outside a 10% gate, with the cause identified in §4b and its arithmetic closing
— are far larger than that band. The conclusion that sits closest to the band is the 5% A-vs-B gap,
and the reason it survives is not any single run's precision but the **sign being the same in all
six**.

Everything in §5, §7 and §8 is a *count*, not a timing. Those are exact.

## 7. What is checked rather than asserted

- **One map implementation.** The two phases cannot import a common library (`dcc` compiles one
  library per object file; `@bare` functions in imported libraries are dropped, GAP-0028), so the map
  is one text emitted into both directories. `verify-parity.sh` diffs the shared region of all three
  file pairs and fails on drift. The pair's entire finding rests on "same work, different order".
- **Eight implementations agree.** `tests/conformance/hashmap-bench/` checks that phase A, phase B,
  both C baselines, both trap-matched baselines and both array-indexed controls return the same
  checksum at four round counts. `run-bench.sh` checks the implementations of *one* benchmark agree; it
  has no reason to check that phase A agrees with phase B, which is the claim that matters here.
- **No leak.** `dc_heap_live` back at 0 after both phases.
- **Inside the shipping heap.** Per-class high-water printed against the 32,768-block ceiling.
- **Freestanding.** Both `@bare` objects pass `verify-freestanding.sh` (CLAUDE.md rule 1).

---

## 8. The measured answer to ADR-0058's open caveat

ADR-0058 stated its worst case without a number: *"a program whose size mix shifts over its lifetime
will hold peak-usage memory for every class simultaneously."* This benchmark is that program by
design, so it can price it.

| | phase A | phase B |
|---|---|---|
| sum of per-class high-water marks (bytes held) | 506,176 | 506,304 |
| maximum simultaneously-live bytes (computed from the workload) | 472,768 | 472,768 |
| **held / live** | **1.071×** | **1.071×** |

**+7.1% peak memory, and the two phases are within 128 bytes of each other.** The stale blocks are
513 class-64 blocks that small values peaked at during era 0 and never gave back once the mix shifted
to larger values — exactly the mechanism ADR-0058 named. It is real, it is measurable, and on this
workload it is small, because the trie and the entries dominate that class and neither ever recedes.

The other half of the question the pair was built to answer: **phase B's peak is not higher than phase
A's.** A rolling window of W and a batch of W reach the same high-water mark in every class, so the
non-coalescing heap holds the same memory either way. That converts "B stresses the allocator
differently" from a claim into a measurement, and the measurement says it does not.

---

## 9. GAP-0054 was met, and the answer is worse than the gap said

GAP-0054 predicted this: *"`map.get(k)` returning a borrowed reference, followed by a mutation of the
map, is the canonical form and it is exactly what M3's hashmap benchmark will write."* It does write
it, in `unlinkFrom`, in its natural form, deliberately not routed around:

```dart
final c = p.next;
if (c == null) { return u64(0); }
if (c.key == key) {
  p.next = c.next;     // ADR-0048 field store: Release of the old value, which IS c
  return c.key;        // a USE, after that release
}
```

**The benchmark is not miscompiled** — verified in the emitted IR (the alias retain on `c` survives)
and by eight agreeing checksums. **And the reason it is not is an accident, not a safety property.**
Pass 3 is single-basic-block, and the null test that a nullable heap field read requires ends the
block before the store. GAP-0054's own reachability argument rested on `_releaseHeapLocals` running
after the return expression; that is a *second*, unrelated accident in a *different* file. Two
independent coincidences are currently holding this up.

**Remove one of them and the bug is immediate.** `examples/m3-elide-alias/` does exactly that, by
making the field **non-nullable** so the sequence lowers into one basic block:

```dart
final borrowed = h.slot;        // alias retain — DELETED by pass 3
h.slot = replacement;           // frees the old slot: it was the last reference
final fresh = Cell(u64(99));    // pops the block just freed
return borrowed.v + fresh.v;    // reads 99 through a dangling reference
```

Correct answer 110. **DCDart returns 198**, through the shipping `dcc build`, at `-O2`, with
`dc_heap_live` back at 0 and every refcount balancing. No leak test and no exhaustion trap can see
this: the counts are right and the identity is wrong.

`tests/conformance/elide-alias/` pins it, with the nullable spelling alongside as a control (110,
correct) so the trigger is attributed to the block boundary rather than to aliasing in general. It is
written as an **expected-failure** target: it passes today, loudly, and **fails the day pass 3 is
fixed**, telling whoever fixed it to invert the assertion and close the gap. CLAUDE.md requires the
conformance case before the fix; the fix is dc-elide's work and not this unit's, and the honest fix
GAP-0054 already named — invalidate pending retains on **any** `Release` — costs elision that has to
be priced. §4b says this benchmark executes ~30 unelided pairs per triple and elides none of them, so
the price of that fix on `hashmap` is, as far as this benchmark can see, **zero**.

---

## 10. Consequences

- **M3 is at 4 of 5.** `hashmap` joins `tree-traversal`, `json` and `string-pass`, which landed in
  parallel with it. Only `closure-heavy` is missing. No gate number is produced and `run-bench.sh`
  still exits 3 until it is.
- **The gate inputs disagree about the allocator, and that is information rather than a
  contradiction.** `tree-traversal` at 0.43× and `hashmap` at 2.33× are not in tension: one is
  allocation-dominated and the other is traversal-dominated, and the geometric mean over five will
  contain both kinds. Nobody should now generalise *either* number into a claim about ARC.
- **The gate is not close.** A single benchmark at 2.33× cannot be brought under 1.10× by the other
  four. If elision on the container shape is not fixed, the gate as stated is unreachable, and that is
  now a measured statement rather than a worry.
- **A requirement on whoever fixes pass 3:** re-run `hashmap` before and after. It is the benchmark
  with enough ARC in it to price both the fix and the elision the fix gives up, and it is the reason
  the expected-failure target above points at this ADR.
- **`div_ck` was added to `bench/harness/trapping.h`** for the era selector. Additive; no existing
  baseline changes.
- **Reversal path.** Everything here is under `bench/` plus two docs entries and two conformance
  targets. Deleting `hashmap-burst` and re-pointing `BENCH_ID=hashmap` at the burst kernel restores
  the single-benchmark shape; nothing outside `bench/` depends on either.

---

## 11. Integration onto `main` (2026-08-27, addendum)

Written on the `wt-hashmap` branch against a pre-ADR-0063 `main`; integrated after the GAP-0054
elision-correctness fix (ADR-0063) and the cross-block extension of pass 3 landed. Both were
predicted by this ADR to cost/recover nothing on this workload, and both did: the workload never had
an elidable pair to lose (§4b), and the cross-block pass recovers zero here (GAP-0062).

Integration-host run (Apple M-series, `run-bench.sh hashmap`, BENCH_ARG resized 600 → 800 so the C
baseline clears the 50 ms sizing guideline — rounds are the sizing knob, §3's fixed parameters are
untouched): identity check PASS, 79 ARC update sites, all five implementations at checksum
632543358, DCDart/nonatomic **2.377x plain C / 2.385x trap-matched C**, traps cost 0.996x, atomic
3.000x, stock Dart AOT 2.78x. `index-tax` reproduces at 1.38x on this host (1.34x in §5).
`tests/conformance/hashmap-bench/` passes: 8 implementations agree at 4 round counts, no leak,
peak 64-byte-class occupancy 3,791 of 32,768 blocks, both `@bare` objects freestanding.

One addition beyond the branch: `bench_aot.dart`, the stock-Dart-AOT informational column (same
trie algorithm, GC instead of ARC), which the other four benchmarks' pattern calls for.
