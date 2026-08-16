# ADR-0019: Heap-typed function parameters and return types

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-heap-param/heap_param.dart` builds
via real `dcc build --mode bare`, passes `verify-freestanding.sh`, and
`core/tests/conformance/m2-heap-param/run.sh` reports an unqualified PASS under WSL/Ubuntu: 1000 real
borrowed-parameter construct/call/read/release cycles (leak-free) plus 60 bounded
construct-return-read calls proving ownership transfer out of a function. All seven pre-existing
conformance harnesses re-verified with zero regressions.

## Context

ADR-0018 added real function calls but deliberately scoped them to scalar
(`u8`/`u32`/`u64`/`Result`) parameter/return types — `_lowerType` still threw on a `HeapObject`
subclass used as a signature type. This was GAP-0017's actual remaining blocker for "heap reference
passed as a function argument": not the absence of `Call` (ADR-0018 fixed that), but `_lowerType`
never recognizing a heap type outside constructor/field-access position.

## Decision

Extended `_lowerType` (`core/dcc-lower/lib/lower.dart`) with one more `InterfaceType` case: if the
referenced class transitively extends the prelude's `HeapObject` marker (checked via the same
`heapLayouts.extendsHeapObject(cls)` already used for constructor/field-access recognition, ADR-0016),
return `DCHeapPointer(DCVoid())` — the identical placeholder-pointee value `_lowerHeapConstruction`
already produces for a freshly-`Alloc`'d object (GAP-0003: DC-IR doesn't track a heap object's
concrete field layout as part of its own type yet, so there's nothing more precise to put there). This
one addition is enough to let a `HeapObject` subclass appear as a parameter type or a function's
declared return type — no other lowering code needed to change, because field access
(`_lowerHeapFieldLoad`) already determines which class's layout to use from the Kernel IR access site
itself (`InstanceGet.interfaceTarget.enclosingClass`), never from the receiver `DCValue`'s own
`DCType` — the placeholder pointee was never actually load-bearing for that path.

**Ownership convention for parameters: borrowed, exactly as ADR-0018 already recorded in `Call`'s doc
comment.** This required zero new code, not just a design choice: a function's parameters are bound
directly in `lower()`'s own loop (`_values[param] = value`), never through `_lowerStatement`'s
`VariableDeclaration` case — which is the ONLY place anything gets pushed onto `_heapLocals`
(ADR-0016/0017). A parameter is therefore never tracked for release by construction, with no special-
case code needed to make it so. Symmetrically, `_lowerBareCall`'s argument-lowering
(`_lowerExpression(callArgs[i])`) never emits a `Retain` either — passing a heap-typed local as an
argument is exactly as cheap as passing a scalar one.

**Ownership convention for return types: unchanged from ADR-0016/0017, now reachable through a real
declared return type.** `return b;` already excepted `b`'s own tracked entry from the naive release
loop when the enclosing function's return type happened to require it implicitly (a `HeapObject`
local); now the function signature itself can say `Box` as its return type, making this an intentional
API, not an implicit side effect.

## Rejected alternative

**A "consuming" parameter convention** (the callee takes ownership and is responsible for releasing
its heap-typed parameter before returning) alongside the borrowed one. Rejected for this ADR
specifically: it would resolve the "how do you ever free a returned heap pointer" question this ADR's
own conformance test deliberately leaves open (see Consequences), but designing a second ownership
convention is real spec-level work (which functions get which convention? syntax to declare it? does
it interact with `.propagate()`-style early returns?) that has not been asked for and would be
guessing ahead of a real need, against this project's own "don't design past what's needed"
discipline. Recorded as the honest next question, not answered here.

## Consequences

- Verified: a borrowed heap-typed parameter (`readBoxValue(Box b)`) composes correctly with the
  existing naive release policy — calling it from a function that owns its own local
  (`makeAndReadViaCall`) doesn't disturb that local's normal release-on-return, confirmed via 1000 real
  cycles with `dc_free_top` checked after every single call.
- Verified, but deliberately bounded: `makeBox(u64) -> Box` correctly constructs and returns a fresh
  heap object, ownership transferred to the caller unreleased — confirmed via 60 calls (of the arena's
  64 slots, `docs/decisions/0015`), each checked against the exact expected `dc_free_top` decrement and
  a correct field read-back through a second, borrowed-parameter call. **NOT verified, and not
  claimed:** a full alloc-then-free cycle for a *returned* heap pointer — there is still no way for a
  DCDart function to actually release a heap reference it did not itself construct (see the rejected
  "consuming convention" above), so `core/tests/conformance/m2-heap-param/run.sh` stops at 60/64 slots
  by design rather than running an unbounded loop that would eventually exhaust the arena and fail for
  a reason unrelated to what this ADR set out to prove.
- `docs/known-gaps.md` GAP-0017's remaining items, narrowed by this ADR: heap references stored inside
  another heap object's field (`_lowerFieldType`, not `_lowerType`, still only accepts
  `u8`/`u32`/`u64` — a separate, not-yet-touched code path) and the "consuming convention" /full free-
  cycle question raised above.
