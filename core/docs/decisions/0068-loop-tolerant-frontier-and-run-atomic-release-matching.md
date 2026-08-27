# ADR-0068: loop-tolerant rule F, and run-atomic release matching (the emission-order study's answer)

**Status:** decided, implemented, verified. Same categorical position as ADR-0063/0066: `dcc-lower`
emits byte-identical DC-IR (a lowering change was tried, measured, and REVERTED — §2); only which
provably-redundant operations `dc-elide` deletes changes. NOT a rule-4 memory-model change; the one
observability question it raises (destructor-cascade order inside a release run) is answered in §2's
safety argument. Addresses GAP-0067 item 2 (loops) and part of GAP-0066's releaseLimited population;
GAP-0067 item 1 (mutating callees) untouched — it waits on escalation 0011, per the assignment.

Numbered 0068 because 0067 was claimed by a concurrent unit
(`0067-closure-heavy-benchmark-explicit-environments.md`) while this one was in flight.

## Context

ADR-0066 left two ranked limiters (GAP-0067) plus GAP-0066's releaseLimited pairs. This unit took
the two that need no spec decision:

- **Rule F refused any function containing a back edge.** The live cost was NEON `tensor.dart`'s
  `loaderNextBatch`: `Retain loader.data` in the entry block, `Release` in the single exit, two
  ARC-free copy loops between — refusal purely structural (`blockLimited=1` under `--why`).
- **GAP-0066 named a `_releaseHeapLocals` emission-order study** as the analysis-free route to
  `epochReduce`'s releaseLimited pair: `Retain t; tensorDestroy(t)@owned; Release s2; Release s1;
  Release t` — releasing `t` FIRST would let ADR-0031's consumed-argument rule cancel the pair.

## 1. Rule F, loop-tolerant (supersedes ADR-0066's whole-function back-edge refusal)

Condition 1 ("no back edges anywhere") is replaced by: **the retain's block and every frontier
block must lie on no CFG cycle** (a block can execute twice per call iff it is reachable from
itself). Blocks BETWEEN the pair may lie on cycles. Machinery updated to match: dominators by the
standard iterative fixpoint (valid on cyclic CFGs; the old single forward sweep relied on the DAG's
topological order), and condition 4's frontier-disjointness reachability was already cycle-safe.

**Safety argument, delta only.** The retain executes ≤1× per call (its block is on no cycle);
likewise each frontier release. Condition 3 (dominance) still makes every frontier execution follow
the retain; condition 2's walk still stops each path at its first unclaimed `Release v` and — the
load-bearing point — **fully scans every block it can reach, interior loop bodies included**, so a
loop body containing any release, any opaque op, or a `Retain v` fails the candidate. What executes
N times inside the interval is therefore provably refcount-irrelevant. A path that enters an
interior loop and never leaves performs no decrement and never reaches a `Return`. ADR-0063's gap
invariant holds per completing path, unchanged.

**Deliberately still refused:** retain and release both inside one iteration body (the pair
completing before the back edge). That needs an alternation argument this pass does not make, and
the one live instance (`parseArray`'s `Retain tail`) is independently blocked by an aliasing
field-store release inside its interval — nothing measured would be recovered.

**Tests:** the ADR-0066 negative test for this exact shape is INVERTED with an in-place
justification (it is now the acceptance test, `crossBlockElided=1`); new negatives pin the retain-
in-loop (cross-iteration escape), release-in-loop, and loop-carried-alias (surviving foreign
release inside the interior loop) refusals.

## 2. The emission-order study, and where it actually landed

**Hypothesis confirmed, mechanism-wise:** with one-at-a-time processing, emission order among an
exit's releases decides elision — a surviving `Release a` one slot before a pending pair's
`Release b` kills the pair; the opposite order cancels it. Same multiset, one executed pair of
difference.

**The dcc-lower fix was tried and rejected on its numbers.** `_releaseHeapLocals` /
`_releaseScopeFrom` were changed to emit most-recently-used-first (the local most likely to carry
the pending retain). Measured: `epochReduce`'s pair cancelled (hypothesis's acceptance case) — and
`m2-heap-field`'s previously-elided pair UN-cancelled, because there the pending retain (a
field-store retain on `b`) is on the *less* recently used local (`holder` is read after the store).
Declaration order fixes one case, last-use order the other; **no static order dominates.** Reverted
to byte-identical lowering.

**Adopted instead: run-atomic matching in `_elideBlock`.** A maximal run of CONSECUTIVE `Release`
instructions is processed as one unit: first every pending retain whose matching release sits
anywhere in the run cancels; then the survivors (original order — the emitted sequence never
changes) invalidate whatever is still pending. This makes the per-block pass order-independent
across a run, which strictly dominates every emission-order choice dcc-lower could make — and it
lives in the pass, so it is checked against literal adjacency in the block body rather than against
a lowering convention asserted in another file (exactly the dependence ADR-0063 complained about
when GAP-0054's safety hung on `_releaseHeapLocals` placement).

**Safety argument.** Equivalent to commuting adjacent releases until the matched one is first, then
applying the unchanged one-at-a-time rule. Commuting adjacent releases is sound because nothing
executes between them: releases are pure decrements, decrements commute, and every object's count
at the END of the run is order-independent — destructor cascades included (induction over the
acyclic ownership graph: an object's total decrement is its explicit releases plus one per dying
holder, and dying is determined by order-independent totals; a strong cycle reaches zero under
neither order). So an object is freed by the run iff the original order freed it, and between the
two candidate free sites only releases execute — no use, no weak load, nothing that can touch a
freed object. For the cancelled pair, the interval up to the run is decrement-free exactly as
before (anything surviving there would have cleared the pending), and inside the run the
transformed count sits exactly one below the original's, both ending equal.

**What order CAN move — and why it is not observable.** Which release site zeroes a shared count,
hence destructor-cascade order within the run, hence heap-slot reuse order. Every DCDart destructor
is compiler-synthesized (`_buildDestructor`, ADR-0022 — field releases only, never user code), and
a managed object's address is not exposed to programs in either direction (GAP-0061; `PtrToInt` is
emitted only for raw `Pointer`/`Str` values). No conforming program can read the difference. Had
user-defined destructors existed, this half of the unit would have stopped at an escalation instead
— that check was made first, not after.

## What it does — measured

`bench/elision-delta.sh` (retains lowered → surviving), before → after, same tree (baseline is
ADR-0066's state plus concurrent unrelated work; tree total reads 146 pre, not 133, for that
reason):

| target | before | after | what moved |
|---|---|---|---|
| `json` | 19 → 4 | 19 → **3** | `parseArray`'s tail-append pair (GAP-0066's headline case) — run-atomic |
| `m3-generic-class` | 2 → 1 | 2 → **0** | `boxNode`'s `got` pair — run-atomic; justification re-pinned in its conformance harness |
| `m3-elide-alias` | 7 → 3 | 7 → **2** | `releaseThroughDestructor` — run-atomic; **`aliasBug`/`aliasBugNullable` byte-for-byte unchanged, still refused** |
| `hashmap` / `hashmap-burst` | 35 → 13 | unchanged | every survivor is GAP-0067 item 1 (mutating callees) — out of scope by assignment |
| `m2-loopheap` | 2 → 1 | unchanged | `lastKept`'s releases are separated by the loop counter's `IAdd`: no run, still GAP-0066 |
| everything else | — | unchanged | tree-wide diff is exactly these rows |
| **total across tree** | 146 → 46 | 146 → **43** | |

NEON `tensor.dart` (the assignment's two acceptance cases, `dc-objdump --arc --why`):

| function | before | after | rule |
|---|---|---|---|
| `loaderNextBatch` | retain 1 (blockLimited) | **0** (`crossBlock=1`) | §1 loop-tolerant rule F |
| `epochReduce` | retain 1 (releaseLimited) | **0** (`elided=1`) | §2 run-atomic (consumed-argument pair) |
| `tensorSlice0` / `loaderNew` / `tensorDestroyViaBase` | 2 / 1 / 1 | unchanged | blockLimited/releaseLimited across real branches and field stores — GAP-0066 family |

Dynamic effect on NEON's epoch: both cancelled pairs execute once per batch — 469 retain/release
pairs per epoch each, now gone. `neon/native/build.sh` fully green after: N0 + tensor-path oracles
300/300 + 300/300, view semantics, epoch over MNIST-60k with `dc_heap_live == 0` at exit, matmul
freestanding-green.

## Verification

- `dc-elide` unit tests: 32 (28 before): the inverted loop test + three loop negatives (§1), the
  inverted adjacency test + the use-between-the-releases negative (§2); all passing.
- Conformance: 46/46. Exactly three count assertions re-pinned, each with an in-place justification
  that answers the stop-the-line warning the old pin carried (`generic-class` `boxNode`,
  `elide-alias` `releaseThroughDestructor` + its TOTAL). The behavior (VALUE) assertions those
  harnesses exist for — 110-not-198 — pass unchanged, and the two genuine miscompilation shapes
  still pin retain=1.
- Leak discipline: every conformance target and NEON's per-case + epoch checks end
  `dc_heap_live == 0`.
- Benchmarks: hashmap/json/tree-traversal medians in the unit report; hashmap and tree-traversal
  object files are expected-identical (their counts did not move), json is the only one whose code
  changed.
