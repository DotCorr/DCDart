# ADR-0032: if/else merge blocks, and heap object field stores

**Status:** VERIFIED — `core/examples/demo-collatz/collatz.dart`, a real hand-written program (not a
narrow single-ADR conformance target), builds via real `dcc build --mode bare`, passes
`verify-freestanding.sh`, links as a completely ordinary hosted C program (no `-ffreestanding`,
no `-nostdlib`, real `printf`), and — critically — **produces the mathematically correct answer**:
`collatzSteps(27) = 111`, the well-known reference value for that famous Collatz starting number,
independently checkable, not just "it ran without crashing." Full 16-target conformance suite plus
`dc-elide`'s unit suite re-verified with zero regressions.

## Context

The user asked to actually build and run a real program in DCDart — not another isolated
conformance-style target proving one feature, but something with the shape of real code. Writing one
(a Collatz step-counter, chosen to exercise several already-verified features together: heap objects
with real ARC, `while` loops, arithmetic, the bitwise operators) immediately hit two real, previously
undiscovered gaps — exactly what "battle testing" is supposed to surface.

## Gap 1: `if`/`else` where both branches fall through

```dart
if ((n & u64(1)) < u64(1)) {
  n = n >> u64(1);       // even
} else {
  n = n + n + n + u64(1); // odd
}
```

`_lowerIf` had only ever supported branches that *terminate* (end in `return`) — the guard-clause
pattern `Result`/`.propagate()` uses. A plain conditional reassignment, where neither branch returns
and both fall through to the code after the `if`, is arguably the single most common shape in
imperative code, and it threw `"then does not end in a return"` (`GAP-0007`'s own documented scope
cut) immediately.

**Fix**: `_lowerIf` now supports a third shape — either branch (or both) falling through instead of
terminating merges back into a real DC-IR merge block, using the **exact same block-parameter
mechanism** `_lowerWhile`'s own header already uses (`ssa.dart`'s design: block parameters ARE how
DC-IR represents merge points, no separate phi instruction). Merge-candidate variables (every scalar
reassigned in either branch) are found via the same `_collectLoopCarriedCandidates` scan
`_lowerWhile` already uses for its own header params — reused, not reimplemented, now serving two call
sites (its doc comment updated to say so). Scalar (`DCInt`) only, same rule as ADR-0027; a heap/weak
local declared inside a branch that falls through is explicitly rejected (nothing would release it —
the naive policy only fires on a real `return`), matching the identical restriction `_lowerWhile`
already has for its own loop body.

The existing two shapes (both terminate; guard-clause with no else) are **unchanged, byte-identical
behavior** — verified by the full conformance suite's zero regressions, not assumed from reading the
diff. The now-dead `_closeBranchIfOpen` helper (its logic inlined and generalized into the new
control flow) was removed rather than left unused.

## Gap 2: writing to a heap object's field

```dart
counter.total = counter.total + collatzSteps(i);
```

`_lowerHeapFieldLoad` (reading a `HeapObject` subclass's field) existed since ADR-0016/0020. Its
Store-direction counterpart never did — nothing had needed to *mutate* a heap object's field after
construction until this program tried to use one as a running accumulator across loop iterations.

**Fix**: `_lowerHeapFieldStore`, mirroring `_lowerHeapFieldLoad`'s addressing exactly (`PtrOffset` off
the `DCHeapPointer` directly, no address-materialization step, unlike `@packed` struct fields which
start from a raw `u64`) — just in the `Store` direction. **Scalar (`DCInt`) fields only**: storing to
a heap- or weak-typed field raises the exact same real ownership question ADR-0027 already flagged for
local reassignment — does overwriting release the old value? retain the new one? — genuinely
undecided, so it throws a clear error rather than guessing at a policy nobody has designed.

## Consequences

- `docs/known-gaps.md` gains an entry for heap/weak-typed field stores (undecided ownership policy,
  same shape as scalar-vs-heap local reassignment) — not a new problem, the same one, now surfaced in
  a second place.
- `core/examples/demo-collatz/` is kept in the repo (not deleted after use) as the first real,
  hand-written (not single-ADR-scoped) DCDart program — a useful reference for what idiomatic `@bare`
  code actually looks like once these two gaps closed.
- Both fixes were found and closed in the same session as the very first attempt to write real code —
  a concrete demonstration that conformance-target-driven development, while rigorous, doesn't by
  itself guarantee a language is usable for actual programs. Worth remembering next time a "battle
  test" is due.
