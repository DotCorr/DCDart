# ADR-0028: Real `while`-loop control flow

**Status:** VERIFIED — `core/examples/m2-loop/loop.dart` builds via real `dcc build --mode bare`,
passes `verify-freestanding.sh`, and `core/tests/conformance/m2-loop/run.sh` reports an unqualified
PASS under WSL/Ubuntu: `sumTo` correct for 50 values (loop-carried-variable threading) and
`firstAtLeast` correct across 19×15 combinations (a nested early-`return` inside a loop body, composed
with the loop's own back edge). All 13 pre-existing conformance harnesses re-verified with zero
regressions, including after a real backend bug found and fixed along the way.

## Context

`docs/known-gaps.md` GAP-0017 item 6 named two independent prerequisites for a real loop: mutable
local variables (ADR-0027, done) and new DC-IR control flow for back-edges (this ADR). Recursion
(ADR-0026) covers "iterate toward a base case" but not a general loop — no iterating a fixed number of
times against a condition, no accumulator pattern without recursion's per-level heap-frame-equivalent
allocation.

## Decision

**DC-IR needed no new instructions.** `ssa.dart`'s own design already represents merge points via
block PARAMETERS, not a separate phi instruction (see `dc-ir/README.md`, "Why block-parameter SSA, not
phi nodes") — a loop header is just an ordinary block with two predecessors (the pre-loop entry edge
and the body's back edge), and `core/backend`'s phi-emission logic already scans EVERY predecessor of
every block in the whole function (`_collectPredecessors`), not just `if`/`else` merges. `_lowerWhile`
(`core/dcc-lower/lib/lower.dart`) lowers `while (cond) { body }` to:

- an entry `Branch` into a header block, passing the current values of every "loop-carried" local;
- the header block, declared with one param per loop-carried local, evaluating `cond` against those
  params, then a `CondBranch` to a body block or an exit block;
- the body block, lowered via the same `_lowerBranchBody`/`_lowerStatement` machinery every other
  statement uses (composes for free with nested `if`, including the guard-clause early-`return`
  pattern already supported for `if`/`else`), ending in a back-`Branch` to the header passing the
  body's final values for each loop-carried local — unless every path through the body already
  returned, in which case there's no reachable back edge (a legal, if degenerate, program).

**Loop-carried variables** are found by a pure Kernel-AST pre-scan (`_collectLoopCarriedCandidates`)
collecting every `VariableSet` target reachable in the body (recursing into `Block` and `IfStatement`
arms, throwing on a nested loop rather than silently mis-scoping the analysis), then filtering to only
the ones already tracked in `_values` before the loop starts — a variable declared fresh inside the
body every iteration is naturally excluded, since it isn't in `_values` yet at scan time. `_values` for
these variables is restored to the header's own phi params after the body closes, mirroring
`_lowerIf`'s ADR-0027 restore — the exit block is only reachable via the header's false edge, never
through the body, so what's live there is the header's params, not whatever the body last computed.

**Scope cuts, on purpose:** `while` only (no `for`/`do-while` — different Kernel AST shapes, no target
needs them yet); no `break`/`continue`; no nested loops; and **no heap- or weak-typed local may be
declared anywhere in the loop body** — enforced by checking `_heapLocals`/`_weakLocals` didn't grow
across the body. The naive release policy (ADR-0016/0017) releases tracked locals before each
`return`; a loop's back edge is not a `return`, so nothing would release a heap local declared inside
the body on any iteration but the function's last. Designing that policy (release before the back
edge? every iteration? what about a heap local escaping via a loop-carried reassignment, which isn't
even supported for scalars yet?) is real, undone work — see `docs/known-gaps.md`.

## A real backend bug found along the way

The first build of `m2-loop` failed with a genuine `clang`/LLVM verifier error, not a hypothetical:

```
error: invalid LLVM IR input: PHI node entries do not match predecessors!
  %v3 = phi i64 [ %v2, %entry ], [ %v6, %blk2 ]
label %blk2
label %ok7
```

Root cause, in `core/backend/lib/llvm_emit.dart`: `_collectPredecessors` computed each predecessor's
LLVM label as `_labelFor(block.id)` — the DC-IR block's own NOMINAL entry label. That's wrong whenever
the block's body contains an instruction that internally splits into more than one real LLVM block
before the DC-IR terminator — `IAdd`/`ISub` overflow trapping (`ok`/`trap` sub-blocks), `Alloc`'s OOM
check, `Release`'s destructor/free-slot path, `WeakLoad`'s dead/alive split all do this. Whichever
sub-block is current when the terminator is actually emitted is the TRUE predecessor label, and it can
differ from the block's nominal one. This bug is as old as M0's overflow-trapping arithmetic
(ADR-0009) but stayed invisible until now: `if`/`else`'s `CondBranch` has always passed empty
`trueArgs`/`falseArgs` (`_lowerIf` never needed to carry a value across a merge), so no `phi` ever
actually depended on a predecessor label being correct until this loop's back edge became the first
non-empty-args branch to follow a block containing arithmetic.

**Fix**: emission is now two-pass. Pass 1 emits every block's real instructions as before, but no
longer emits `phi` lines inline — instead it records each DC-IR block's TRUE final internal LLVM label
(`_FunctionEmitter.lastFinishedLabel`, the label of whichever sub-block `terminate()` most recently
closed) as it goes. Pass 2, now that every block's real final label is known — including a loop
header's back edge, whose source block is emitted textually AFTER the header itself — computes real
predecessor edges from these captured labels and prepends each block's `phi` lines to its own nominal
entry label (`_FunctionEmitter.prependToLabel`, new). `_emitPhiNodes` was refactored into `_phiLines`,
returning lines instead of writing them directly, so pass 2 can insert them after the fact. Verified
via the exact LLVM IR dump that first exposed the bug, then via the full 14-target conformance suite
with zero regressions — including every prior target that already used arithmetic (all of them) and
`WeakLoad` (`m2-weak`), neither of which had ever exercised the broken code path before now since
neither ever fed a value through a `phi`.

## Consequences

- `docs/known-gaps.md` GAP-0017 item 6 is resolved for `while`: both of a real loop's prerequisites
  (mutable scalar locals, ADR-0027; loop control flow, this ADR) now exist, verified together via
  `firstAtLeast`'s nested if-inside-loop composition.
- The backend's phi-predecessor tracking is now correct in general, not just for this one case —
  `core/backend`'s own architecture (real per-block emission, only two label-tracking primitives
  added) needed no further per-instruction special-casing, and no other conformance target's ARC
  codegen changed at all (confirmed by the unchanged pass/fail status and behavior of every other
  target).
- Heap- and weak-typed locals inside a loop body remain unimplemented and explicitly rejected at
  lowering time — real, separate work needing a real ARC-across-back-edge policy decision, tracked in
  `known-gaps.md`.
- `break`/`continue`, `for`/`do-while`, and nested loops remain unimplemented; add each when a real
  conformance target needs it, not speculatively, matching this project's whole-session discipline.
