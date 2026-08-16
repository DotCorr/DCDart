# ADR-0022: Destructor cascade via a direct call through `cls` (not yet a real vtable)

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-heap-field/heap_field.dart`'s
conformance test (`core/tests/conformance/m2-heap-field/run.sh`) was rewritten from asserting a
deliberate, bounded, nonzero leak rate (ADR-0020's own honest limitation) to asserting **1000 real
nested-construct/read cycles, genuinely leak-free and UNBOUNDED** — this ADR is what fixed the exact
gap ADR-0020 documented. All nine other conformance harnesses re-verified with zero regressions.

## Context

ADR-0020 built `HeapObject`-typed fields (a `HeapObject` holding a reference to another `HeapObject`)
and was explicit that it could not close the loop: `Release`'s codegen never read the object header's
`cls` field (spec §3.1), so a parent object's own destruction never cascaded into releasing its own
heap-typed fields — every such field's reference permanently leaked. This is GAP-0003, and ADR-0020's
own conformance test intentionally proved the EXACT, predicted leak rate rather than pretending it
didn't exist.

`DCDART_SPEC.md` §3.1 already specifies the mechanism: `struct DCObject { u32 strong; u32 weak;
ClassInfo* cls; }`, and "`dc_release` calls the destructor and frees at zero." What's genuinely
undesigned is the CONCRETE shape of `ClassInfo` — the spec calls it "vtable + destructor + layout
descriptor" without pinning down the details, and GAP-0003's own text names this as unresolved.

## Decision

**A direct destructor call, not a real `ClassInfo` vtable.** DCDart has no dynamic dispatch yet (spec
§4.3's monomorphization is M5+ scope) — every heap object's concrete class is always statically known
at its own `Alloc` call site, never chosen among several possibilities at runtime. Building a full
vtable (multiple virtual slots, runtime type resolution) now would be real complexity serving a
capability — polymorphic dispatch — that doesn't exist anywhere else in the compiler yet. So:

- **`Alloc`** (`core/dc-ir/lib/instructions.dart`) gains an optional `destructorName` — resolved once,
  in `dcc-lower`'s `_lowerHeapConstruction`, at the one place a heap object's concrete class is always
  known for certain. The backend writes this function's own address into the header's `cls` field
  (`store ptr @<destructorName>, ptr %clsPtr`) — a real function pointer is a valid `ptr` value under
  LLVM's opaque pointers, no wrapper struct needed for a single "virtual slot."
- **`Release` needed NO shape change at all** — exactly as its ORIGINAL doc comment already said it
  should ("resolved when `Release` is lowered to LLVM IR in `backend/`... not something DC-IR bakes
  into the instruction itself"). Its codegen is now uniform: after strong hits zero, load `cls`; if
  non-null, call through it (`call void %clsVal(ptr %object)`) before pushing the slot back onto the
  free list. `dcc-lower` never needs to know a release SITE's class — only `Alloc` sites need class
  info, and they already had it.
- **`dcc-lower` synthesizes one destructor `DCFunction` per `HeapObject` subclass that has ≥1
  heap-typed field** (`_buildDestructor`) — never sourced from user Dart code. Its body: for each
  heap-typed field, `PtrOffset`+`Load` (identical to a normal field read) then `Release` on what was
  loaded. **Cascading to a field's OWN destructor needs no extra logic** — releasing a field just
  emits a plain `Release`, and `Release`'s now-uniform codegen already checks THAT object's own `cls`
  at runtime, populated correctly back when it was itself `Alloc`'d. Depth is handled by composition,
  not by `_buildDestructor` walking the class graph recursively.
- **`_StructField` gains `heapFieldClass`** (`Class?`, non-null iff the field is heap-typed) — the
  CONCRETE class a heap-typed field points to, which the field's own `DCType`
  (`DCHeapPointer(DCVoid())`, GAP-0003's placeholder) can't say. `_HeapLayouts.destructorNameFor`
  (cached) uses this to decide whether a class needs a destructor at all.

## Rejected alternative

**A real `ClassInfo` global struct per class (`{ dtor: ptr }` or richer) with `cls` pointing to IT**,
`Release` reading `cls` then loading the destructor pointer FROM that struct, rather than `cls` being
the destructor's address directly. Rejected for now, not forever: this is real forward-compatible
infrastructure for when a genuine multi-slot vtable is needed (spec §4.3, M5+), but building it today
adds a layer of indirection (an extra global definition per class, an extra load) with zero behavioral
difference from the simpler direct-call design, since nothing varies at runtime yet that would need a
SECOND virtual slot. When real dynamic dispatch lands, `cls` can be repointed at a proper `ClassInfo`
struct without changing `Release`'s shape again — its codegen already only cares that `cls` is
"either null or something callable as `void (ptr)`," which a future richer `ClassInfo`'s first field
being the destructor slot would still satisfy.

## Consequences

- `docs/known-gaps.md` GAP-0003 is resolved for DCDart's CURRENT (non-polymorphic) scope: a
  `HeapObject` holding another `HeapObject` now correctly releases it when the parent dies, cascading
  to arbitrary depth, verified over 1000 real cycles. **What GAP-0003 does NOT resolve**: a genuine
  runtime-dispatched `ClassInfo` vtable for when DCDart eventually has subtype polymorphism — that
  remains real, deferred M5+ design work, not implemented here. Renamed/re-scoped in `known-gaps.md`
  rather than closed outright, since the spec's own `ClassInfo` concept is still only partially built.
- `core/examples/m2-heap-field/heap_field.dart`'s conformance test changed meaning: ADR-0020 designed
  it to prove an exact, predicted, nonzero leak rate; this ADR made that leak disappear, so the test
  now proves the opposite (genuine, unbounded leak-freedom) — same source file, same program, honestly
  updated expectations as the compiler's own capability moved past what the earlier test could prove.
  This is exactly the kind of "verify against real output, not stale assumptions" discipline this
  project's own rules ask for — the moment the mechanism changed the correct answer, the test SHOWED
  it (failed loudly, exit code 3, until updated) rather than silently passing on outdated expectations.
