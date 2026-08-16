# ADR-0003: DC-IR gets a `DCHeapPointer` type now; `ClassInfo`/vtable layout waits for M1/M2

**Status:** decided

## Context

`core/dc-ir/instructions.dart` needed `Retain`/`Release` node shapes now
(CLAUDE.md rule 4 — memory-model conventions are frozen after M3, so the
node shape should be right before M2's ARC-insertion pass is written against
it), per this task's brief: "even though M0's `add` itself needs zero of
them ... the node shapes need to exist because ARC conventions are frozen
after M3."

But `Retain`/`Release` need a typed operand — something that says "this
value is a reference to a heap object with a `DCObject` header" (spec §3.1:
`strong`, `weak`, `cls` fields) as opposed to a raw FFI/MMIO pointer
(`DCPointer`, spec §6) that ARC has no business touching. Defining that
properly in full would mean designing `ClassInfo` (vtable + destructor +
layout descriptor) — which is explicitly out of scope for this task ("do not
design the full type system (no generics, no vtables, that's M1/M2)") and
is genuinely M1/M2 work: vtables need the class/interface model from spec
§4.3, which doesn't exist in DC-IR terms yet.

## Options

1. Skip `Retain`/`Release`'s operand typing — take a bare `DCValue` with no
   constraint, and let convention (a comment) say "this should be a heap
   pointer."
2. Design the full heap-object type now: a `DCType` that encodes the
   `DCObject` header layout and a `ClassInfo` reference, so `Retain`/
   `Release` are fully specified end to end.
3. Add one new, minimal `DCType` — `DCHeapPointer(pointee)` — that marks "ARC
   operates on this" without encoding what's inside `ClassInfo`.

## Decision

Option 3. `DCHeapPointer` (`types.dart`) wraps a `pointee` type and is
structurally distinct from `DCPointer`; `Retain.object`/`Release.object` are
documented as requiring a `DCHeapPointer` operand. What's inside — the
`ClassInfo` layout, whether it's reached through a fixed-offset header field
or something else, how `weak`/`unowned` (spec §3.3) end up represented — is
left undesigned, tracked as `docs/known-gaps.md` GAP-0002.

Option 1 was rejected because it defeats the point of getting the node shape
right now: a convention enforced only by a comment is exactly the kind of
thing CLAUDE.md rule 4 is trying to avoid needing to fix retroactively once
M2 code depends on it. Option 2 was rejected because it's substantially more
than this task's scope, would be a real class/vtable design decision made
without the M1/M2 context that should inform it (interface dispatch,
monomorphization interaction, `weak`/`unowned` representation), and isn't
needed to get `Retain`/`Release`'s shape right — the *operand type category*
is what's load-bearing for the instruction shape, not the operand type's
internal layout.

## Consequences

- `Retain`/`Release` can be type-checked against "is this a heap pointer" as
  soon as a verifier exists, without waiting on the class model.
- Whoever designs the class/vtable model in M1/M2 has one job constrained by
  this decision: make sure the eventual heap-object representation is
  expressible as (or compatible with) `DCHeapPointer(pointee)`, or come back
  and revise this ADR and `types.dart` together. That's a normal follow-up,
  not a violation of the freeze — the freeze is on `Retain`/`Release`'s
  field list (`instructions.dart`), not on `DCHeapPointer`'s internals.
- `weak`/`unowned` (spec §3.3) are explicitly not represented in DC-IR yet.
  When they are, the likely shapes are "a distinct `DCType` per reference
  kind" or "a flag on `DCHeapPointer`" — both are compatible extensions of
  this decision, not competitors to it. Recorded so the M2 agent isn't
  choosing blind.
