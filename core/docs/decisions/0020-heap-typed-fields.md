# ADR-0020: A HeapObject field can reference another HeapObject

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-heap-field/heap_field.dart` builds
via real `dcc build --mode bare`, passes `verify-freestanding.sh`, and
`core/tests/conformance/m2-heap-field/run.sh` reports an unqualified PASS under WSL/Ubuntu. All eight
pre-existing conformance harnesses re-verified with zero regressions.

**UPDATE (docs/decisions/0022-destructor-cascade.md):** the "honest, deliberate leak" section below
describes this ADR's ORIGINAL, correct state — at the time this ADR landed, `Release` could not
cascade into a parent's heap-typed fields at all (GAP-0003), so the leak it documents was real and
predicted. ADR-0022 subsequently added exactly that cascade. `core/examples/m2-heap-field/
heap_field.dart`'s conformance test was updated in place to match: it now asserts genuine, UNBOUNDED
leak-freedom (1000 real cycles) instead of the bounded, predicted-leak assertion described below. The
reasoning below is kept as the historical record of why the leak was correct *at the time* — read
ADR-0022 for the current, actual behavior.

## Context

ADR-0019 closed the "heap ref as function argument/return" half of GAP-0017's remaining
`Retain`-insertion scope. The other half — a `HeapObject` subclass holding a reference to *another*
`HeapObject` in one of its own fields — was still blocked, but by a different, narrower cause: not
`_lowerType` (parameter/return-type position, ADR-0019's fix), but `_lowerFieldType`, the separate
helper `_StructLayouts`/`_HeapLayouts` both use to lower a class's *own field* types. It only accepted
`u8`/`u32`/`u64`.

## Decision

**`_lowerFieldType` gains an optional `_HeapLayouts?` parameter.** When present (only
`_HeapLayouts.layoutFor` passes one, always `this`), an `InterfaceType` field whose class transitively
extends `HeapObject` lowers to `DCHeapPointer(DCVoid())` — the identical placeholder-pointee value
every other heap-typed value in this codebase uses (GAP-0003: no concrete `ClassInfo`/layout tracking
in the type itself yet). **`_StructLayouts.layoutFor` (`@packed`/`Struct`) never passes this
parameter, on purpose** — a `@packed` struct is a raw-memory, non-ARC'd layout (ADR-0011); a heap
reference embedded in one would be meaningless, since nothing about the `@packed` pattern ever
retains/releases anything. This restriction is a real, intentional design boundary, not an oversight
mirroring `_lowerType`'s.

**Embedding retains.** `_lowerHeapConstruction`'s per-field initializer loop now emits a `Retain`
before the `Store` when the field's type is `DCHeapPointer`. The value being stored always comes from
a constructor *parameter* (only the `ThisClass(this.field)` shorthand is supported, ADR-0016) — and
constructor parameters are always borrowed (ADR-0019: bound directly in `lower()`, never through the
tracked-local mechanism). Storing a borrowed reference into a field the new object now independently
outlives needs its own `Retain`, or the field pointer dangles the instant whichever caller-side owner
released its own copy.

**The `_lowerStatement` retain-insertion rule, generalized.** ADR-0017 only checked `init is
VariableGet` (aliasing) to decide whether binding a heap-typed value to a new local needed a `Retain`.
A borrowed field read (`final c = holder.inner;`, an `InstanceGet`) is exactly the same shape — an
existing reference someone else still owns — and needed the identical treatment, so the check is now
inverted and generalized: retain UNLESS the initializer is a known fresh-ownership source
(`ConstructorInvocation`, a fresh `Alloc`; or `StaticInvocation`, a call whose return ownership already
transferred per ADR-0019). Every other DCHeapPointer-producing shape — aliasing, a borrowed field read,
and any future shape that exposes rather than transfers a reference — is covered by one rule instead of
enumerating each shape as it's discovered.

## The honest, deliberate leak this ADR's own test proves it produces

`BoxHolder`'s `Release` does not, and cannot yet, cascade into releasing its own `inner` field —
`Release`'s backend codegen has never read the object header's `cls` field (GAP-0003, unchanged,
`docs/decisions/0015`'s own note). So every call to `makeHolderAndReadInner` in the conformance target
permanently loses exactly one arena slot: the inner `Box`'s. The `BoxHolder`'s own slot correctly
returns to the free list; the `Box` it once pointed to never does, because nothing ever runs the
(nonexistent) code that would decrement its strong count when its owner is destroyed.

This is not a defect in the `Retain`-on-embed mechanism this ADR adds — it is the **correct, predicted
consequence** of adding real nested ownership on top of a system that still has no destructor dispatch.
The conformance test does not paper over this: it asserts the *exact* expected leak rate
(`dc_free_top == 64 - (i + 1)` after call `i`) rather than "leak-free," and stops at 30 of the arena's
64 slots by design, leaving clear headroom, rather than running to exhaustion. Getting a wrong retain
count (too few, or one too many) would show up immediately as the wrong leak rate — verified: the exact
predicted rate held for all 30 calls, which is a stronger signal than a vague "didn't crash" would have
been.

## Rejected alternative

**Defer heap-typed fields entirely until destructors exist**, so no conformance target would ever need
to document an expected leak. Rejected: the `Retain`-on-embed mechanism itself is real, independently
correct, and needed either way — destructors (GAP-0003) will need to call `Release` on exactly the
fields this ADR now makes storable, so building and proving the storage/retain half first (with an
honestly-documented, bounded, and predicted leak) is strictly forward progress, not something to redo
once destructors land. Waiting would only delay finding out whether the retain accounting was right.

## Consequences

- `docs/known-gaps.md` GAP-0017 is narrowed to exactly one remaining item: a "consuming" ownership
  convention — a way for a function to actually *release* a heap reference it did not itself
  construct. Nothing built by ADR-0016 through this ADR provides that; it is now the sole missing piece
  before a `HeapObject` graph can be used beyond "construct, wire together, and (for anything but the
  outermost object) leak on the way out." This looked, at first, like the kind of ownership-policy
  question `CLAUDE.md` rule 4 would want escalated rather than decided in an implementation unit — but
  `DCDART_SPEC.md` §3.2 item 2 already specifies the answer explicitly ("Only `@owned` params
  transfer"), so this is implementation work against an existing spec decision, not a new one. See
  `docs/decisions/0021-owned-parameters.md`.
- `ClassInfo`/destructor dispatch (GAP-0003) is now a *sharper* gap than before: prior to this ADR, no
  conformance target could even construct the shape (a heap object holding another) that a destructor
  cascade would need to handle. **RESOLVED by ADR-0022**, same session — `BoxHolder` turned out to be
  exactly the concrete, verified example that made building the cascade tractable immediately, rather
  than sitting as a documented-but-unaddressed gap.
