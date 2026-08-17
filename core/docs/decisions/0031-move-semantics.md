# ADR-0031: Move semantics — the call-consumed, single-owned-argument case

**Status:** VERIFIED — `core/dc-elide/test/elision_test.dart` reports 6/6 passing (2 new: the positive
case and the critical "used again afterward" negative safety case, plus the 4 pre-existing tests
unchanged). `dc-objdump --arc` on the real compiled `core/examples/m2-owned/owned.dart` confirms
`makeAndDropViaCall` now shows `alloc=0 retain=0 release=0` — down from `retain=1 release=1` before
this change, the exact number `docs/known-gaps.md`'s own entry already named as the target. The full
16-target conformance suite re-verified with zero regressions, including `m2-owned` itself still
reporting genuinely leak-free across 1000 real execution cycles — this elision is correct at runtime,
not just at compile time.

## Context

Spec §3.2 pass 4 (move semantics: "last use of a binding is a move, not a copy. No refcount traffic")
is the fourth of five required elision passes; only pass 3 (redundant-pair removal, ADR-0025) existed
before this. `known-gaps.md`'s own entry for this had already scoped the problem precisely from a real
example — `m2-owned/owned.dart`'s `makeAndDropViaCall(v) { final b = makeBox(v); return
dropBoxAndReadValue(b); }` — and identified the exact architectural gap: `Call` carried no per-argument
ownership metadata, so `dc-elide`'s existing pass couldn't tell a load-bearing borrowed-argument
`Retain`/`Release` pair apart from a redundant owned-consuming one; both look identical as a plain
opaque `Call`. This ADR resolves that one specific case — not a general move-semantics system.

## Decision

**`Call` gained `argOwnership: List<bool>`** (`core/dc-ir/lib/instructions.dart`), parallel to `args`.
`dcc-lower`'s `_lowerBareCall` already computed this exact fact per argument (it's what decided whether
to emit a caller-side `Retain` before the call, per ADR-0019/0021's `@owned` convention) — this just
also records it instead of discarding it.

**`dc-elide` extended, not replaced.** A `Call` still invalidates every pending retain by default
(unchanged, conservative); the one exception is a pending retain whose value is exactly one of this
call's `argOwnership`-true arguments — that specific pending retain survives, but is now tracked under
a **strictly stronger rule** than an ordinary pending retain.

## The critical correctness subtlety

The existing (ADR-0025) pass safely skips over ordinary instructions between a `Retain(x)`/`Release(x)`
pair — a `Load` through `x`, arithmetic, etc. — because `x` stays alive via *some other reference*
throughout; cancelling the pair doesn't change that. This case is different: once cancelled, the
object's *last* reference is what gets handed directly to the callee. If source code reads the value
again after the call (`return b.value;` right after `dropBoxAndReadValue(b)` — genuinely safe **today**,
since two references are alive across the call and one survives it), naively cancelling the pair would
turn that into a real use-after-free: only one reference would have ever existed, and the callee's own
release would drop it to zero.

**The fix**: a new generic helper, `referencedValueIds(DCInstruction)` — an exhaustive `switch` over
every `DCInstruction` subtype (the sealed hierarchy means the analyzer refuses to compile this file if
a future instruction is added without updating it) returning every `ValueId` an instruction reads,
excluding its own `dest`/`result`. Applied to every instruction after a call-consumed candidate is
created, up to its own matching `Release`: **any** reference at all — not just an opaque op — fully
invalidates that specific candidate (falls back to the pre-existing behavior of leaving the pair alone).
Verified directly: a dedicated negative test constructs exactly this "owned-call, then read again" shape
and asserts the pair survives.

## What this does NOT cover

Deliberately scoped to one case, matching this project's whole-session discipline of building exactly
what a real example needs:
- Moving a value into a struct field or another heap object's field.
- Moving on the last *plain* use of a variable (e.g. a final `return b;` with no intervening call) —
  this is closer to escape analysis (pass 1) territory, a separate, larger, unstarted piece.
- Moving across a loop back-edge (loops with heap locals remain unsupported at all, GAP-0017 item 6).
- `Weak<T>`'s own `@owned` convention — `argOwnership` is only ever `true` for `DCHeapPointer`
  arguments; a `DCWeakPointer` `@owned` parameter has no elision story built yet (weak-count elision is
  a separate, unstarted question, noted explicitly in `_lowerBareCall`'s own comment).

## Consequences

- `docs/known-gaps.md` GAP-0017 item 2 updated: pass 4 partially resolved (this one case); still open
  for the general cases above.
- `core/dc-ir`'s `Call` shape changed (an additive, required field) — every existing call site updated;
  no other package needed changes beyond `dc-elide` and its own test fixtures.
- Next natural candidate per the roadmap: uniqueness/reuse (pass 5), which needs a real move/ownership
  foundation to build on — or escape analysis (pass 1), the largest remaining piece. Neither designed
  here; each gets its own scoping pass when picked up, per `known-gaps.md`'s own "pick whichever a real
  workload pressures first" note.
