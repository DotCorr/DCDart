# ADR-0021: `@owned` parameters — the consuming counterpart to borrowed-by-default

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-owned/owned.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and `core/tests/conformance/m2-owned/run.sh`
reports an unqualified PASS under WSL/Ubuntu: **1000 real construct/transfer/consume cycles, genuinely
leak-free and UNBOUNDED** — the first M2 heap-signature target that didn't need to stop short of the
arena's 64-slot capacity (ADR-0019 and ADR-0020's targets both had to, for exactly the reason this ADR
resolves). All nine pre-existing conformance harnesses re-verified with zero regressions.

## Context

ADR-0019 and ADR-0020 both closed real gaps but each left the same honest gap open behind them: a
function could receive or construct a heap reference, but had no way to actually *release* one it did
not itself construct. Every "leak-free" claim through ADR-0020 was either bounded (ADR-0019's `makeBox`
test, ADR-0020's `BoxHolder` test) or scoped to values that never crossed a consuming boundary
(ADR-0016/0017's construct-and-drop, alias tests).

Before writing this up as a new memory-model design question for escalation (per `CLAUDE.md` rule 4:
"Any change to §3... escalate"), `DCDART_SPEC.md` §3.2 item 2 was checked directly:

> **Borrow inference.** Function parameters default to *borrowed* (no retain/release at the call).
> Only `@owned` params transfer.

**This is not a new decision to make — the spec already specifies it.** `@owned` is the named,
explicit annotation the spec itself uses for a consuming parameter. ADR-0019's borrowed-by-default
convention (implemented without any `@owned` mechanism yet) was already the correct default per this
same spec line; what was missing was the OTHER half of the same sentence. This is implementation work
against an existing spec decision, the same category as every other ADR this session, not a new
memory-model choice requiring a human call.

**One wrinkle worth recording:** spec §3.2 frames borrow-inference/`@owned` under "Elision," and
`ROADMAP.md`/`CLAUDE.md` treat elision as M3+ scope, with M2's own job being "naive, not elided" (spec
§3.2: "naive ARC costs 15-40%... elision is what gets it to single digits" — naive is slower, not
missing features). Read narrowly, this could suggest `@owned` shouldn't exist until elision does. It
reads more consistently the other way: `@owned` is a *source-level ownership contract* (part of what a
function signature means), not itself an optimization — the real "elision" work spec §3.2 groups it
under is *borrow inference*, the analysis that PROVES additional un-annotated parameters could also
safely skip their retain/release pair, which is not implemented here and remains real M3+ work. What
this ADR implements is the mechanical minimum the contract requires: an `@owned` parameter is tracked
and released; that's naive ARC operating on an explicit annotation, not elision.

## Decision

`core/runtime/dc-core-bare/prelude.dart` gains `@owned` (`_Owned` marker class, mirroring `@bare`'s own
`_Bare`/`bare` pattern) — usable on a `HeapObject`-typed parameter: `@bare u64 f(@owned Box b) { ... }`.

**Callee side** (`core/dcc-lower/lib/lower.dart`'s `lower()`): Kernel represents parameters as
`VariableDeclaration` nodes — the exact same type `_heapLocals` already tracks for locals (ADR-0016).
An `@owned`-annotated heap-typed parameter is simply added to `_heapLocals` during parameter binding.
No new tracking structure, no new release logic — `_releaseHeapLocals` (unchanged since ADR-0016)
already releases every tracked local before each `return`, and the existing except-by-declaration logic
(ADR-0017) already handles "the function returns its own owned parameter back out" correctly, for
free.

**Caller side** (`_lowerBareCall`): when an argument is passed to an `@owned` parameter, a `Retain` is
emitted — UNLESS the argument expression is a known fresh-ownership source (a fresh `Alloc` via
`ConstructorInvocation`, or a call whose return ownership already transferred, ADR-0019). This is the
exact same distinction ADR-0017 introduced for binding a value to a new local, ADR-0020 introduced for
embedding one into a field, and this ADR now applies a third time for passing one to an owned
parameter — extracted into one shared helper, `_isFreshHeapOwnership`, instead of re-deriving the rule
per call site as each new case was discovered.

## Rejected alternative

**A syntax marker on the CALL SITE instead of the parameter declaration** (e.g. `f(consume(b))`,
Rust-`mem::take`-flavored). Rejected: spec §3.2 explicitly frames this as a parameter-declaration-level
property ("function parameters default to borrowed... only `@owned` params transfer") — the function's
signature is what states its own ownership contract, not each individual call site restating it. This
also matches real prior art the spec cites (Swift's `borrowing`/`consuming` parameter modifiers) more
directly than a call-site marker would.

## Consequences

- `docs/known-gaps.md` GAP-0017 is now resolved for M2's own scope (naive, non-elided ARC insertion at
  every ownership-transfer point spec §3.1 describes: fresh construction, local aliasing, heap-typed
  field storage, function parameters/returns both borrowed and owned). What remains beyond it is
  explicitly LATER-milestone work, not undone M2 scope: elision itself (escape analysis, borrow
  inference proper, redundant-pair removal, move semantics, uniqueness/reuse — spec §3.2's passes 1,
  3, 4, 5; M3's overhead gate), `weak`/`unowned` (spec §3.3 layer 1), cycle collection (layer 2/3), and
  destructors/`ClassInfo` (GAP-0003 — still open; an `@owned` parameter holding a `BoxHolder` still
  wouldn't cascade-release its own `inner` field, same limitation ADR-0020 already documented).
- Verified: passing a value to an `@owned` parameter while the caller independently keeps its own
  reference alive (the retain-needed case) and passing one where the caller has no other reference at
  all (straight from a fresh construction, or straight from C across the ABI boundary, where no retain
  is needed or emitted) both produce exactly correct, genuinely leak-free behavior over 1000 real
  cycles each.
- The `@owned` annotation only makes sense on a `HeapObject`-typed parameter; nothing currently checks
  or rejects `@owned` on a scalar parameter (harmless today — `_hasMarkerAnnotation` is only consulted
  when `type is DCHeapPointer` — but not actively validated as a source-level error either). Not fixed
  here since no conformance target has hit it; noted for whoever eventually adds real `@bare` semantic
  diagnostics (ADR-0008's deferred front_end-fork territory).
