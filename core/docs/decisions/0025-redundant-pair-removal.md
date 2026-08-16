# ADR-0025: Redundant-pair removal (spec §3.2 pass 3) — the first elision pass

**Status:** decided, implemented, AND VERIFIED — 4 isolated unit tests pass
(`core/dc-elide/test/elision_test.dart`), all 11 conformance harnesses still pass with zero
regressions once wired into the real pipeline, and `dc-objdump --arc` (ADR-0024) shows the pass
firing exactly where safe and correctly refusing to fire where not:

```
core/examples/m2-alias/alias.dart (BEFORE this ADR)          (AFTER, verified)
  makeAliasAndReadValue: retain=1 release=2        ->          retain=0 release=1
  makeAliasBranch:       retain=1 release=3        ->          retain=0 release=2

core/examples/m2-owned/owned.dart  (call-spanning pair)  — UNCHANGED: retain=1 release=1
core/examples/m2-weak/weak.dart    (weakload-spanning)   — UNCHANGED: all counts identical
```

This is the concrete, checkable "elision firing" `ROADMAP.md`'s M2 exit criterion names.

## Context

Scoping "what's actually left for M2" surfaced a real correction (recorded in
`docs/known-gaps.md` GAP-0017 item 2): earlier framing in this project's own memory and gap-tracking
treated elision as purely M3 scope. Re-reading `ROADMAP.md` directly (not from a summary) shows M2's
own exit criterion literally includes *"`dc-objdump --arc` shows elision firing on the reference
benchmark"* — distinct from M3's own exit, which is specifically the ≤10%-overhead **measurement**
against a benchmark suite. M2 needed at least one real elision pass, demonstrably firing; it did not
have one.

## Decision

**Spec §3.2 pass 3** ("`retain(x); ...; release(x)` with no release of `x` in between → delete both")
is the most mechanical of the five listed elision passes, and the natural starting point.

**A new package, `core/dc-elide/`, not `core/dcc-lower/lib/elide.dart`.** Purely for dependency
hygiene: `elideRedundantRetainReleasePairs` only needs `package:dc_ir` (zero transitive
dependencies), which is what lets its own test suite depend on `package:test`. `dcc_lower`'s own
pubspec cannot: it path-depends on the vendored `kernel` package, which pins `_fe_analyzer_shared` to
a local path version — `package:test`'s dependency tree wants a *hosted* `_fe_analyzer_shared`, and
pub's version solver correctly refuses to reconcile "from path" against "from hosted" for the same
package in one pubspec. Rather than accept zero automated test coverage for something this
safety-sensitive, the pass lives in its own small package (matching this project's existing pattern:
`dc_ir`, `dcc_lower`, `backend`, `dcc`, `dc-objdump` are all separate, focused packages already) that
`dcc_lower` depends on as an ordinary path dependency — a dependency's OWN `dev_dependencies` are never
inherited by whoever depends on it, so this adds no conflict.

**The algorithm, deliberately conservative** (see `lib/elide.dart`'s own extensive header comment for
the full reasoning): single-basic-block only (no cross-block tracking — a block boundary means the
value might flow into a path this pass can't see all of); a `Call` instruction invalidates every
pending retain (opaque — the callee could do anything to any object, and this pass has no
interprocedural analysis to rule that out); `MakeWeak`/`WeakLoad`/`DropWeak` ALSO invalidate every
pending retain, even on a *different* `DCValue* — a weak pointer's address is numerically identical to
the strong pointer it was made from (ADR-0023), and this pass cannot prove non-aliasing at the DC-IR
level, so treating every weak op as opaque (not just ones on the literal same value) is the safe
choice. Everything else (arithmetic, `Load`/`Store`/`PtrOffset`, `Alloc`/`Retain`/`Release` on
*other* values, terminators) is safe to skip over: `Alloc` always allocates a fresh, previously-unused
header; `PtrOffset`/`Load`/`Store` only ever touch a non-negative payload offset, never the header
(fixed negative offset, ADR-0016), so no plain memory op can corrupt a refcount.

**Wired into `lowerToDCModule`, applied to every function** — both user-lowered ones and the
synthesized destructors (ADR-0022) — right before the module is returned.

## Two safety tests that matter more than the "it works" test

`core/dc-elide/test/elision_test.dart` has four cases, but the two that justify the whole design are
the negative ones: a hand-built function with `Retain(x); Call(...); Release(x)` (mirrors
`m2-owned/owned.dart`'s `makeAndDropViaCall` — the callee's own release, in a *different* function
entirely, is load-bearing; removing the caller's pair would free the object one decrement too early)
and one with `Retain(x); WeakLoad(differentValue); Release(x)` (mirrors nothing existing yet, but
proves the weak-op conservatism specifically, since `WeakLoad`'s own codegen conditionally retains).
Both assert the pass leaves the pair completely untouched. The real end-to-end confirmation that these
aren't just paranoia: `dc-objdump --arc` on `m2-owned/owned.dart` and `m2-weak/weak.dart` shows
byte-for-byte identical counts before and after this ADR landed.

## Rejected alternative

**Cross-block tracking** (following a pending retain across a `Branch`/`CondBranch` into a successor
block, matching it against a `Release` there). Rejected for this first pass: DC-IR's block-parameter
form (ADR-0012) means a value crossing a block boundary might arrive at the successor under a
*different* `ValueId` (bound as that block's own parameter) — correctly tracking identity across that
rename is real, additional work this first, deliberately mechanical pass doesn't attempt. Every
existing conformance target's redundant-pair opportunities happen to be single-block (aliasing,
release, done, all before any branch), so this restriction costs nothing observable yet.

## Consequences

- `docs/known-gaps.md` GAP-0017 item 2 (elision) is now PARTIALLY resolved: pass 3 (redundant-pair
  removal) is done and verified firing. Passes 1 (escape analysis), 2 (borrow inference proper — NOT
  the `@owned`/borrowed-by-default *contract* ADR-0019/0021 already built, but the analysis that would
  prove MORE un-annotated parameters could also skip retain/release), 4 (move semantics), and 5
  (uniqueness/reuse analysis) remain unimplemented — each a real, larger analysis, appropriately
  sequenced after this first, narrowest pass proved the mechanism (and `dc-objdump --arc`) work.
- `core/tests/conformance/`'s own targets are now genuinely running SLIGHTLY less naive code than when
  their ADRs (0016-0023) were originally written and verified — re-verified against the CURRENT,
  elided pipeline in this same unit, not assumed still-correct from an earlier state.
- M2's exit criterion (`ROADMAP.md`: "...`dc-objdump --arc` shows elision firing on the reference
  benchmark") is now demonstrably met for at least one real pass on at least one real target. Whether
  the FULL exit criterion (all of spec §3.2's passes, informally) is required before M2 is "complete,"
  versus "at least one pass firing" being sufficient per the literal exit text, is a matter of
  interpretation — flagged here rather than silently resolved either way.
