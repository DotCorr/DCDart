# ADR-0066: three new elision rules — refcount-transparent callees, multi-exit frontier pairs, null ARC ops

**Status:** decided, implemented, verified. Extends ADR-0025's pass 3 within the existing
memory-model semantics (NOT a rule-4 change: `dcc-lower` emits exactly the same DC-IR as before;
only which provably-redundant operations `dc-elide` deletes changes — the same categorical position
ADR-0063 established). Addresses GAP-0062's measured wall; narrows, does not touch, GAP-0066's.

## Context

GAP-0062 measured the M3 gate's dominant term: elision removed 1 of 19 retains on `json`, ~0 of
`hashmap`'s ~30 executed pairs per round, and the hashmap benchmark's residual vs trap-matched C
stood at ~2.38× with attribution isolating the gap to unelided retain/release pairs (traps 0.996×,
allocator ~5%). Measured with `--why` on the actual benchmarks, the surviving pairs fell to three
limiters:

- **blockLimited** — the retain dies at a block boundary, and the shapes that matter (`tlookup`'s
  descent, `valueSum`'s branches) have **multiple return blocks**, which the ADR-0025 cross-block
  extension (single-exit only) could not touch.
- **opaqueLimited** — a `Call` between the retain and its release. GAP-0062's own postscript
  recorded this as "now the load-bearing constraint": `walk` in both `json` and `tree-traversal`
  passes the structural conditions and then dies on its own recursive call.
- **releaseLimited** — ADR-0063's surviving-release rule (GAP-0066). Untouched here, on purpose.

One further population was hiding in plain sight: `Retain <NullRef>`. dcc-lower emits a retain for
every reference field a constructor initializes to null; on `parseNumber` that is **6 of its 6
retains**, and each survives as blockLimited noise while costing a real null-check-and-branch at
runtime.

## Decision: three rules, each with its own safety argument and its own negative test

### Rule N — ARC ops on a statically-null value are deleted

A `Retain` or `Release` whose object is defined by a `NullRef` **in the same function** is removed
outright (not as a pair — individually).

**Safety argument.** SSA: a `NullRef`-defined value is null on every execution. ADR-0049 made
`dc_retain(null)` / `dc_release(null)` DEFINED no-ops (the backend emits an explicit null test
before touching any header). Removing an instruction that provably does nothing changes no refcount,
ever. The rule matches the *definition*, never the type or a dataflow guess.

**Negative test** (`rule N: does NOT remove a Retain of a block parameter one predecessor binds to
null`): a block param bound to null by only one predecessor is dynamic and its retain survives.

### Rule T — refcount-transparent callees ("borrows-only" interprocedural summary)

`computeRefcountTransparentCallees(functions)` computes, per module, the set of functions whose
execution **can never decrement any object's strong count below its value at call entry**. A direct
`Call` to a member of this set no longer invalidates ordinary pending retains — in the per-block
pass and in rule F's walk. (`IndirectCall` is never transparent: no name, no summary. An argument
passed `@owned` still gets ADR-0031's strict `callConsumed` treatment, which is orthogonal.)

A function qualifies iff all of:

1. **No weak ops, no `IndirectCall`** anywhere in its body.
2. **Every `Release` is covered per-ValueId**: along every path, the running
   (#`Retain` − #`Release`) balance for that exact vid never goes negative. Checked by a forward
   min-dataflow over blocks (meet = min, entry = 0; a net-negative cycle blows the iteration cap and
   refuses). Per-vid is strictly conservative w.r.t. aliasing: a cover on the same SSA value is a
   fortiori the same object; a release of any *other* vid (the field-overwrite shape
   `Store p <- new; Release old`) is uncovered and disqualifies.
3. **Every direct callee is itself transparent**, transitively; a callee with no body in the module
   (extern) disqualifies. Recursion is handled as bad-*reachability* (a function is bad iff a
   disqualifying instruction is reachable from it in the call graph), so a self-recursive function
   with only covered releases — `walk`, `tlookup`, `chainSum` — qualifies. That is exactly the case
   the gate needed.

**Safety argument.** Every decrement executed in a qualifying function's dynamic extent is a covered
release: injectively matched (prefix balance ≥ 0) to an earlier retain *of the same SSA value, hence
the same object, in the same frame*. So for any object, at any time inside the extent, the partial
sum of (increments − decrements) since entry is ≥ 0: no count ever dips below its entry value.
Corollary: no count reaches zero (a live object enters at ≥ 1; an object allocated inside enters at
1 and an uncovered release of it would disqualify) — so **no destructor can fire inside a
transparent callee**, closing the "release cascades through a dtor with no call edge in the IR"
hole. Carrying a pending retain across such a call therefore preserves ADR-0063's gap invariant
verbatim: inside the elided pair's interval the transformed program still performs no decrement.

**Pre-/post-elision coherence.** The summary is computed once, on the pre-elision module, and used
to elide; the emitted code is post-elision. Valid because elision preserves the non-decrement
property: a deleted pair's interval has, in the transformed callee, a count exactly one below the
original's — and the original was ≥ entry+1 there (its own retain had executed, nothing in the
interval decrements) — so the transformed count stays ≥ entry; null-op deletions change nothing.

**Negative tests**: the field-overwrite shape disqualifies (`tinsert`/`unlinkFrom`'s genuine
decrements — the GAP-0054 family — keep those callees opaque); a release covered on only one path
disqualifies; weak ops / indirect calls / extern callees disqualify and badness propagates to
callers; and the identical call-spanning pair with the callee NOT in the set is not elided.

### Rule F — multi-exit frontier pairs (supersedes ADR-0025's single-exit cross-block form)

A `Retain v` in block A cancels against a **frontier** of `Release v` instructions — one on every
path leaving the retain — under four conditions, each refusing rather than approximating:

1. **No back edges** anywhere in the function (indices strictly increase), so every block executes
   at most once per call.
2. **A forward walk** from the instruction after the retain stops each path at the first unclaimed
   `Release v` (that release joins the frontier) and fails the whole candidate on: `Retain v`
   (ambiguous), anything opaque (surviving `Release` of any other value per ADR-0063, a
   non-transparent or owned-consuming call, `IndirectCall`, weak ops), or a `Return` reached with no
   release (the deletion would leak on that path). Instructions already claimed by an accepted pair
   are skipped — they are deleted and never execute (the same reasoning as the per-block pass's
   deleted-release rule; it is what lets `walk`'s two pairs share an exit block).
3. **A dominates every frontier block** — no path reaches a frontier release without having passed
   the retain.
4. **No frontier member reaches another** — otherwise one execution would shed one retain and two
   releases.

**Safety argument.** With 1–4, each execution through the retain deletes exactly one retain and
exactly one release, and inside the deleted interval the transformed program performs no decrement —
so ADR-0063's invariant (counts agree at the interval boundaries, only rise inside, boundary ≥ 1)
holds per path, unchanged. Everything the old single-exit form accepted, this form accepts;
additionally it checks opacity over exactly the blocks *reachable* from the retain instead of an
index-range superset.

**Negative tests**: a path reaching `Return` with no release refuses; a retain that does not
dominate the frontier refuses; a back edge refuses the whole function.

## What it does — measured

`bench/elision-delta.sh` (retains lowered → surviving), before → after this ADR, same tree
(including the concurrent float/void-release lowering changes, which is why `hashmap` reads 35
pre rather than ADR-0061's 33):

| target | before | after |
|---|---|---|
| `hashmap` / `hashmap-burst` | 35 → 33 | 35 → **13** |
| `json` | 19 → 19 | 19 → **4** |
| `tree-traversal` | 6 → 4 | 6 → **0** |
| `m2-list` | 12 → 9 | 12 → **6** |
| `m2-loopheap` | 2 → 2 | 2 → 1 *(rule N: the null initializer; the ADR-0063 pair still refused)* |
| `m3-generic-class` | 2 → 2 | 2 → 1 *(rule T across `unwrap`; the GAP-0054 pair still refused — see below)* |
| `m3-elide-alias` | 7 → 3 | 7 → 3 *(unchanged: every ADR-0063 refusal holds)* |
| `m3-funcptr` | 6 → 1 | 6 → 1 |
| `m2-alias`, `m2-closure`, `m2-heap-field`, `m2-owned`, `m2-void-release` | 100% | 100% |
| **total across tree** | 133 → 106 | 133 → **42** |

The one recovered `boxNode` pair deserves its sentence, because `boxNode` is GAP-0054's crime
scene: the pair rule T recovers is the *store*-retain whose interval spans only the
release-free `Box$Node_unwrap` call; the pair ADR-0063 refused — `Retain got` straddling the
surviving `Release b` whose destructor frees the very object — **is still refused**
(`releaseLimited=1`), and `m3-elide-alias`'s three refusals are byte-for-byte unchanged.

On the gate benchmarks the dynamic effect is the point: `hashmap`'s entire lookup path
(`tlookup` → `chainSum` → `valueSum`, ~12 executed pairs per operation) and `tree-traversal`'s
entire traversal are now retain-free; `json` keeps ARC ops only in `parseArray`'s
tail-append (releaseLimited, GAP-0066) — see the unit report for timings.

## What it deliberately does not do

- **`tinsert` / `tremove` / `unlinkFrom` descent pairs survive** (hashmap: 13 surviving retains).
  Their callees genuinely decrement old field values — rule T's condition 2 refusal is the
  correctness line, not a limitation to engineer around. Recovering these needs return-value
  uniqueness (escalation 0011) or field-store ownership reasoning, both spec §3 questions.
- **Loops**: rule F refuses any function with a back edge (NEON's `loaderNextBatch` stays
  blockLimited for exactly this reason). A region-based extension that skips ARC-free loop bodies
  is future work, recorded in GAP-0062's update.
- **ADR-0063's surviving-release rule is untouched.** releaseLimited pairs (`parseArray`'s
  `tail = child`, NEON's `epochReduce` batch drop) still need escalation 0011, or a
  `_releaseHeapLocals` emission-order change in dcc-lower — a separate unit either way.

## Verification

- `dc-elide` unit tests: 28 (15 before), positive + negative per rule, all passing.
- Conformance suite: green, with exact-count assertions updated where a count legitimately changed,
  each with an in-place justification (see the unit's diff).
- Leak discipline: every conformance target and benchmark still ends `dc_heap_live == 0`.
- `--why` totals now include `crossBlock` and `nullOps`, so the pair accounting stays auditable;
  `opaqueLimited` now counts only retains actually invalidated by a call (an owned-argument
  promotion is not an invalidation).
