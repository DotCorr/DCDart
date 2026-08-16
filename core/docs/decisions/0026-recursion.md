# ADR-0026: Recursion — verified, not implemented (it already worked)

**Status:** VERIFIED — `core/examples/m2-recursion/recursion.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and `core/tests/conformance/m2-recursion/
run.sh` reports an unqualified PASS under WSL/Ubuntu: self-recursive calls at depths 0 through 60,
every sum correct, `dc_free_top` back to baseline (64) after every single top-level call — including
the deepest one, where up to 60 `Box` objects are simultaneously alive mid-recursion before any of
them release. Passed on the first real build. All 11 pre-existing conformance harnesses re-verified
with zero regressions.

## Context

ADR-0018 (function calls) explicitly flagged: "Recursion is untested — nothing about the design should
prevent it... but 'should work by inspection' is exactly the kind of claim this project's own rules
say not to make without a real test, so it stays unclaimed until a conformance target actually
exercises it." Separately, `docs/known-gaps.md` GAP-0017 item 6 (recently corrected from "loops with
heap locals — unverified" to "no loop construct exists in `dcc-lower` at all") left open the question
of how a "loop-like" heap-allocation-per-iteration pattern could be tested at all, given `@bare` DCDart
currently has no `while`/`for` statement AND no mutable local variables (both real, separate,
unimplemented prerequisites for a true loop). Recursion is the one iteration mechanism that already
works with zero new lowering logic — this ADR closes both loose ends at once.

## Decision

**No lowering changes were needed for recursion itself.** `_lowerBareCall` recognizes a
`StaticInvocation` targeting any `@bare`-annotated `Procedure` by its Kernel-IR-resolved `target` —
nothing in that logic distinguishes "a different function" from "the function currently being
lowered." A self-recursive call is, at the DC-IR and LLVM level, just an ordinary `Call`/`call`
referencing the enclosing function's own `linkName` — exactly as unremarkable as any other function
symbol calling itself, which LLVM (and every real compiler) has always supported natively.

**One real gap did exist and got fixed**: `u64` only had `+` and `<` operators (M0/M1 built exactly
what their own conformance targets needed, per this project's whole-session discipline). A natural
countdown recursion (`sumBoxValues(n - u64(1))`) needs subtraction to make progress toward its base
case. `core/dc-ir/instructions.dart`'s `ISub` has had real backend codegen since M0 (included
alongside `IAdd` from the start, per that file's own "arithmetic is inseparable as a vocabulary"
note) — only the source-level `u64 operator -` and its `dcc-lower` recognition (`u64|-` →
`ISub(overflow: Overflow.trapping)`, mirroring `u64|+`'s existing pattern exactly) were missing.

**Verification design**: `sumBoxValues(n)` constructs a fresh `Box` at EVERY recursion level, not just
the outermost call — this is what actually exercises the "loop-like heap allocation" question GAP-0017
item 6 raised, not just "does a bare recursive call return the right number." Each stack frame's
`Box` is released by the SAME naive per-function-invocation policy (ADR-0016) every other function
already gets — recursion needed nothing special here either, since each recursive invocation is,
correctness-wise, indistinguishable from a call to any other function; it only happens to share a
name and body with its caller.

**A real, worth-recording subtlety about WHEN objects release across a recursive chain**: because a
function's return EXPRESSION is evaluated before its own tracked locals are released
(`_lowerReturn`'s existing order, unchanged since ADR-0016), and `sumBoxValues`'s return expression
(`v + sumBoxValues(n - u64(1))`) contains the recursive call itself, the ENTIRE call chain descends
all the way to the base case — allocating a `Box` at every level — BEFORE any of them start releasing.
Releases then happen in LIFO order as the recursion unwinds. This means **peak simultaneous
allocation equals the recursion depth**, not 1 — the conformance harness deliberately bounds `n` to 60
(of the arena's 64 slots, `docs/decisions/0015`) rather than running to a depth that would exhaust it,
the same "bounded on purpose, not silently truncated" discipline every other M2 target in this project
already follows.

## Consequences

- ADR-0018's "recursion is untested" flag is resolved: recursion works, verified, with zero design
  changes — the strongest possible confirmation that `Call`'s design (ADR-0018) was right the first
  time.
- `docs/known-gaps.md` GAP-0017 item 6 is clarified further: recursion is a real, verified alternative
  to iteration for anything expressible as "do X, then recurse toward a base case" — but it is NOT a
  substitute for a general loop construct (no way to iterate over a collection, no arbitrary mutable
  loop state, and Dart's own stack-depth limits apply at the LLVM/native level the same way they would
  for any recursive C function). A real `while`/`for` statement, and the mutable local variables it
  would need, remain unimplemented and are a separate, real, larger unit of work.
- `u64` now has `+`, `-`, and `<` — still missing `*`, `/`, `>`, `<=`, `>=`, and every bitwise operator
  spec §4.1 eventually wants; added exactly as needed, same discipline as everywhere else in this
  project, not speculatively.
