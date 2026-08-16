# ADR-0023: Weak references (spec §3.3 layer 1) via zombie-slot semantics

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-weak/weak.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and `core/tests/conformance/m2-weak/run.sh`
reports an unqualified PASS under WSL/Ubuntu: **1000 real weak-reference cycles, genuinely leak-free
and UNBOUNDED**, both the "target already died" path (correctly nils out) and the "target still alive"
path (correctly retains and returns the live reference), with EXACT zombie-slot arena counts matching
the predicted values at every intermediate step, not just at the end of each cycle. All ten
pre-existing conformance harnesses re-verified with zero regressions. Passed on the first real build —
every intermediate arena-count prediction in this ADR's own design matched empirically without needing
a single fix.

## Context

`DCDART_SPEC.md` §3.3 layer 1 is `weak`/`unowned` — a reference that does not keep its target alive
and "nils out when the target dies." This was untestable until ADR-0022's destructor cascade existed:
without a real, observable "target death" event, there was nothing for a weak reference to nil out
*at*. With that event now real, this was the natural next slice.

## Decision

**A new `DCWeakPointer` type** (`core/dc-ir/lib/types.dart`), distinct from `DCHeapPointer` for the
same reason `DCHeapPointer` is distinct from raw `DCPointer` — so `MakeWeak`/`WeakLoad`/`DropWeak`
reject the wrong operand category at construction time rather than silently no-op'ing.

**Three new DC-IR instructions**, mirroring `Alloc`/`Retain`/`Release`'s three-instruction shape:
- **`MakeWeak(dest, object)`** — increments the target's `weak` header count (spec §3.1's
  `DCObject.weak`, offset 4 in the 16-byte header) without touching `strong`. `dest`'s numeric value
  equals `object`'s (weak and strong pointers name the same payload address); the distinct `DCType`
  is what keeps them from being confused, not a different address.
- **`WeakLoad(dest, weak)`** — checks `strong`. Dead (zero): `dest` is the null pointer, no retain.
  Alive (nonzero): retains (increments `strong`) and `dest` is the live address — a genuine
  fresh-owned `DCHeapPointer` (or null), extending `_isFreshHeapOwnership` (ADR-0017/0020/0021's
  shared helper) to recognize this `InstanceGet` shape as fresh too, alongside `ConstructorInvocation`
  and `StaticInvocation`. Deciding "alive or dead" and "retain if alive" together in ONE instruction
  (rather than a separate liveness check plus a caller-side conditional retain) is what makes it
  impossible to ever retain a null pointer, which would corrupt memory (`Retain`'s codegen computes
  `object - 16` unconditionally).
- **`DropWeak(object)`** — decrements `weak`; if `weak` is now zero AND `strong` is also zero, finally
  frees the slot.

**Zombie-slot semantics — the actual design decision.** `Release`'s "strong hits zero" path (ADR-0022)
now checks `weak` before freeing: if `weak > 0`, the slot is left as a **zombie** — `strong == 0` (so
`WeakLoad` correctly reports "dead"), destructor already run, but NOT yet pushed onto the free list (so
a `WeakLoad` reading a slot that's already been handed to a new `Alloc` can't happen). `DropWeak` is
what actually frees a zombie slot, once the last weak reference to it also goes away. Both free-list-
push code paths (`Release`'s and `DropWeak`'s) share one helper, `_emitFreeSlotPushback`
(`core/backend/lib/llvm_emit.dart`), rather than duplicating the pointer arithmetic.

**`WeakLoad`'s internal control flow needed a real `phi`**, not just sequential blocks like every
other multi-block instruction here (`_emitArith`'s trapping path, `_emitAlloc`) — those all define
their destination value in exactly ONE place before branching and let later blocks reference it by
dominance. `WeakLoad` needs a DIFFERENT value on each of its two paths (null vs. the live address), so
the two paths' results must be merged with an actual `phi ptr [ null, %dead ], [ %v, %alive ]` at the
join block — the one place in this project's backend, outside the DC-IR block-parameter lowering
(`_emitPhiNodes`), that hand-writes LLVM `phi` syntax directly.

**Prelude surface**: `Weak<T>` (mirroring `Pointer<T>`'s pattern) — `Weak<Box>.fromStrong(myBox)` to
construct, `.value` to read. No stored fields at all (unlike `HeapObject` subclasses) — dcc-lower
substitutes real codegen for the whole class's shape, never reading a field layout from it.

**Scope cuts, deliberate, both throwing clear errors rather than silently miscompiling:**
- **No weak-to-weak aliasing.** `final w2 = w1;` (where `w1` is `Weak<T>`) would need its own
  weak-count increment (a "weak retain") from an EXISTING `DCWeakPointer` source, which `MakeWeak`
  doesn't support (it only accepts a `DCHeapPointer` object). Rather than silently under-counting and
  double-`DropWeak`-ing — the exact bug class ADR-0017 fixed for heap-local aliasing — both
  `_lowerStatement`'s weak-local tracking and `_lowerBareCall`'s `@owned Weak<T>`-argument handling
  throw a clear `DccLowerError` for this shape instead.
- **`unowned` is not implemented.** Spec §3.3's other layer-1 variant (traps on a dead access instead
  of nilling) is a real, separate design — not attempted here.

## Rejected alternative

**Always free the slot immediately when `strong` hits zero, regardless of `weak`**, and have `WeakLoad`
detect staleness some other way (a generation counter stored alongside the weak pointer, checked
against a counter in the slot). Rejected: this needs an EXTRA piece of state per weak pointer (the
generation it was made at) that `DCWeakPointer`'s current shape (a bare address, matching
`DCHeapPointer`'s own shape exactly) doesn't carry, and would mean `MakeWeak`/`WeakLoad` need to
thread a generation value through in addition to the address — real added complexity to avoid keeping
one already-dead 64-byte slot reserved a little longer. The zombie-slot approach needs no new value
shape at all, just an extra header-field check at two points that already read the header.

## Consequences

- `docs/known-gaps.md` GAP-0017 item 3 (`weak`/`unowned`, spec §3.3 layer 1) is resolved for `weak`;
  `unowned` remains open, correctly deferred (no conformance target has needed it).
- Cycle collection (GAP-0017 item 4, spec §3.3 layers 2/3, ORC) is now more concretely scoped than
  before: a real `weak` mechanism exists to build the cycle-breaking pattern on top of, and a real
  "did this object die" signal (the destructor cascade) exists for ORC's own bookkeeping to hook into.
  Still not started — a genuine next milestone, not a quick follow-on to this ADR.
- The zombie-slot mechanism means a program that creates many weak references to short-lived objects
  and holds onto those weak references for a long time will exhaust the 64-slot arena faster than one
  that doesn't (each such object's slot stays reserved until its LAST weak reference drops, not just
  its last strong one) — an inherent, expected property of `weak` semantics in general, not specific to
  this arena; a real allocator (spec §12's still-open decision, `escalations/0002`) would face the
  identical tradeoff.
