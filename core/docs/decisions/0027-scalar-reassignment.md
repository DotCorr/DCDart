# ADR-0027: Scalar local variable reassignment

**Status:** VERIFIED — `core/examples/m2-mutable/mutable.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and `core/tests/conformance/m2-mutable/
run.sh` reports an unqualified PASS under WSL/Ubuntu: 400 checks (200 straight-line reassignments,
200 branch-scoped reassignments spanning both the taken and not-taken paths of an `if` with no
`else`), all correct. All 12 pre-existing conformance harnesses re-verified with zero regressions.

## Context

`docs/known-gaps.md` GAP-0017 item 6 (corrected in ADR-0026) established that `@bare` DCDart has no
loop construct at all — `_lowerStatement` has no `WhileStatement`/`ForStatement`/`DoStatement` case.
A real loop needs two independent prerequisites: new DC-IR control flow for back-edges, AND mutable
local variables (a loop that can't change its own state can't do anything a `return` can't already
do). Mutable *scalar* locals (`u8`/`u32`/`u64`) have zero ARC interaction — no retain/release
bookkeeping, no ownership questions — making them the lower-risk half to build first, independent of
the loop-control-flow work. This ADR implements that half.

## Decision

**Recognize `VariableSet` in `_lowerStatement`.** An `ExpressionStatement` wrapping a `VariableSet`
(Kernel IR's node for `x = <expr>;`) looks up the variable's current `DCValue` in `_values`, lowers
the right-hand side, and rebinds `_values[variable]` to the new value — after two checks: the
variable must already be tracked (a `VariableSet` for something dcc-lower never bound is a real
error, not silently ignored), and the assignment must be scalar-to-scalar of the *same* `DCInt`
width (no implicit widening, matching the existing arithmetic rule). Heap- and weak-typed
reassignment is explicitly rejected with an error pointing at `known-gaps.md` — that needs a real
ownership policy (release the old value? require it already be null? this project has not decided,
see the "move semantics" discussion in ADR-0025/GAP-0017) that is out of scope here.

## A bug found along the way

The first implementation built `mutable.dart` successfully for the straight-line case
(`mutateStraightLine`, reassigning `x` twice with no branches) but failed for the branch-scoped case
(`mutateInBranch`, reassigning `x` inside an `if` with no `else`) with a real `clang` failure:

```
error: invalid LLVM IR input: Instruction does not dominate all uses!
  %v4 = extractvalue { i64, i1 } %t0, 0
  ret i64 %v4
```

Dumping the raw emitted LLVM IR (via a temporary debug script, deleted after use) showed the cause
directly: `mutateInBranch`'s fallthrough block (entered when the `if`-condition is false) contained
`ret i64 %v4`, where `%v4` was defined inside the *then*-block (entered only when the condition is
true) — a value from one branch leaking into a sibling/fallthrough block that does not dominate it.

Root cause: `_values` (the `Map<VariableDeclaration, DCValue>` binding table in
`_BareFunctionLowerer`) had no snapshot/restore scoping around `_lowerIf`'s branches. `_heapLocals`
and `_weakLocals` already get this treatment (ADR-0017, extended by ADR-0023) — snapshotted before a
branch starts, truncated back after it closes, so a heap local declared inside one branch can't leak
into a sibling. `_values` was never given the same treatment, because before this ADR nothing ever
*rebound* an existing entry — declarations only ever added new keys, and reading a variable from an
outer scope inside a branch is safe (it's the same DCValue everywhere). Reassignment breaks that
assumption: it mutates an existing binding in place, and the branch that performs the mutation isn't
necessarily the branch (or the fallthrough continuation) that reads it next.

**Fix**: `_lowerIf` now snapshots `_values` with `Map.from(_values)` before each branch starts, and
restores it with `_values..clear()..addAll(snapshot)` immediately after that branch closes —
mirroring the exact existing `_heapLocals`/`_weakLocals` pattern in the same function, for the same
reason. This also correctly discards any variable *declared* inside a branch once it closes, matching
Dart's own lexical block-scoping, as a side effect of the same mechanism.

Verified via the raw LLVM IR dump before and after the fix, then via the full conformance suite.

## Consequences

- Scalar local reassignment works, verified, including the branch-scoped case that exposed the bug.
- `docs/known-gaps.md` GAP-0017 item 6 is partially resolved: mutable scalar locals now exist. A real
  loop still needs the other half — DC-IR control flow for back-edges — which remains unimplemented.
- Heap- and weak-typed reassignment remains unimplemented and explicitly rejected at lowering time,
  tracked as a `known-gaps.md` item pending an ownership-policy decision.
- The `_values`-scoping gap this ADR fixed is a general lesson worth restating: any per-branch mutable
  state in `_BareFunctionLowerer` needs the same snapshot/restore discipline as `_heapLocals`/
  `_weakLocals`, not just the ones that happened to need it first. No other currently-mutated
  per-branch state was found to have the same gap (checked: `_heapLocals`, `_weakLocals`, `_values`
  are the only three), but a future addition should default to scoping unless proven unnecessary.
