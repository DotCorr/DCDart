# ADR-0016: Heap object construction/field access via real stored fields + PtrOffset

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-heap/box.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and
`core/tests/conformance/m2-heap/run.sh` reports an unqualified PASS under WSL/Ubuntu: 1000 real
alloc/construct/read/release cycles, heap returned to baseline every time. One real latent bug was
found and fixed along the way — see "A bug found along the way" below.

## Context

ADR-0015 proved `Alloc`/`Retain`/`Release` correct in isolation (a hand-built leak test). M2 needs
this wired to real DCDart source: construct a heap object, read its fields, release it correctly —
the actual exit criterion ("allocation-heavy programs run leak-free under `dc-test --leakcheck`").

## Decision

`core/runtime/dc-core-bare/prelude.dart` gained `HeapObject` — subclasses declare **real stored
Dart fields** (not the getter-pair approximation ADR-0011 used for `@packed`/`Struct`), because real
fields give `dcc-lower` genuine declaration-order (`Class.fields`) and constructor
`FieldInitializer`s to read — this is closer to real DCDart than another approximation would be, and
it's what a real heap object with a real destructor eventually needs anyway.

Empirically verified Kernel IR shapes: object construction is a `ConstructorInvocation` (target name
`""` for the default unnamed constructor); `Class.fields` preserves declaration order; a
`Constructor.initializers` list contains `FieldInitializer(field, value)` entries, where `value` for
the common `ThisClass(this.field)` shorthand is a `VariableGet` of the constructor's own parameter
(not the call site's argument — `dcc-lower` maps constructor parameters to call-site arguments by
position before resolving each initializer). Field reads are the same `InstanceGet` shape already
used for `@packed` struct fields.

New DC-IR instruction: `PtrOffset(dest: DCPointer, base: DCPointer|DCHeapPointer, offsetBytes)` —
`base + offsetBytes` as a raw pointer, usable directly with the existing `Load`/`Store`. Deliberately
**not** reusing ADR-0011's `ConstInt`+`IAdd`+`IntToPtr` chain (that path assumes a raw `u64` address,
not a `DCHeapPointer`) — a clean, minimal new instruction was simpler and clearer than retrofitting.
`@packed` struct field access is left exactly as it was; nothing broke it.

**Retain/release policy (naive, no elision yet — spec §3.2's elision passes are explicitly a later,
separate concern from mechanism correctness):** every heap-typed local variable not identical to the
function's return value gets a `Release` inserted before each `Return` in the function that declared
it. No escape analysis, no borrow inference, no move semantics — just enough to be *correct*
(everything a function allocates and doesn't return, it releases). This satisfies M2's "leak-free"
exit criterion; performance (M3's ARC-overhead gate) is explicitly out of scope for this first pass,
per spec §3.2's own framing ("naive ARC costs 15-40%... elision is what gets it to single digits" —
naive is slower, not incorrect).

## Rejected alternative

**Getter-pair fields, matching ADR-0011's `@packed` struct pattern.** Rejected: real stored fields
are closer to actual DCDart (and to what a real front_end fork will eventually parse natively
anyway), and give genuinely useful information (`Class.fields` order, `FieldInitializer`s) that a
getter-based approximation would have to fake with more prelude boilerplate for no benefit — `@bare`
heap objects don't need `@packed`'s pointer-backed-instance flexibility, they're always accessed
through their own `Alloc`-returned `DCHeapPointer`.

## A bug found along the way

Verifying this exposed a real, latent bug that predates this ADR: `_StructLayouts.extendsStruct`
(M1, ADR-0011) walks a class's supertype chain looking for the prelude's `Struct` marker, but every
Dart class implicitly extends `Object` eventually — and `dart:core::Object` is an unbound reference
under `--no-link-platform` (ADR-0008's frontend strategy). It never crashed before because every
prior caller matched within one hop. `_HeapLayouts.extendsHeapObject` hit the same pattern
immediately (an `InstanceGet` on any class calls `extendsStruct` unconditionally before checking
`extendsHeapObject`, per the dispatch order in `lower.dart`) — walking `Box → HeapObject → Object`
crashed trying to resolve `Object`. Fixed with a shared `_extendsPreludeMarker` helper that treats an
unresolvable ancestor as "chain ends here" (verified via direct introspection — `Supertype.classNode`
throws, `Supertype.className.canonicalName` doesn't) rather than crashing. This is exactly the kind
of thing this project's "verify against real output" discipline exists to catch before it ships.

## Consequences

- Only the `ThisClass(this.field, ...)` constructor shorthand is handled — a field initializer with
  real computation (`this.x = y + 1`) throws a clear `DccLowerError`, not a silent miscompile. Add
  when a real target needs it.
- The naive release policy handles straight-line and branching (`if`/`else`) functions correctly —
  verified: heap locals are scoped per-branch (snapshotted/truncated around each arm, so a return in
  one branch never double-releases a local declared in a sibling branch). Loops are unverified
  territory (`docs/known-gaps.md` GAP-0017).
- **No `Retain` is ever inserted anywhere in the source-driven path yet** (only `Release`) — this
  first target never aliases, passes, or returns a heap reference, so nothing needed retaining beyond
  `Alloc`'s own implicit strong=1. A heap reference assigned to a second variable, passed as an
  argument, stored inside another heap object, or returned from a function all need explicit
  `Retain` insertion at the ownership-transfer point (spec §3.1) that doesn't exist yet — tracked as
  `docs/known-gaps.md` GAP-0017.
- `ClassInfo`/destructor dispatch remains deferred (GAP-0003) — `Release`'s codegen (ADR-0015) still
  never reads the `cls` header field. A `HeapObject` subclass holding another heap reference (needing
  a real destructor to release it) is out of scope for this first target.
