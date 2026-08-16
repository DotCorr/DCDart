# ADR-0017: Retain insertion for heap-local aliasing, tracked by declaration not value

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-alias/alias.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and
`core/tests/conformance/m2-alias/run.sh` reports an unqualified PASS under WSL/Ubuntu: 2000 real
alias/read/release cycles (1000 straight-line, 1000 split across both `if`/`else` branches),
`dc_free_top` returned to baseline every time. All five pre-existing conformance harnesses (M0,
M1-pointer, M1-struct, M1-result, M2-heap) re-verified with zero regressions.

## Context

ADR-0016's naive release policy tracked heap locals as a `List<DCValue>`: every `HeapObject`-typed
`VariableDeclaration`'s DCValue was pushed on declaration, and released (except the one matching the
return value) before each `return`. This was correct for "construct, use once, drop" — the only
pattern M2's first slice proved — but `docs/known-gaps.md` GAP-0017 named the very next thing that
breaks it: aliasing (`final b2 = b;`).

`dc-ir` has no copy/move instruction. Lowering `final b2 = b;` evaluates the initializer
(`VariableGet(b)`), which returns the *exact same* `DCValue` `b` already holds — there is no
mechanism to give `b2` a distinct SSA identity. Two real bugs fall out of this once you track
`DCValue`s in a list:

1. **Push side:** `b`'s DCValue gets pushed to `_heapLocals` twice (once for `b`, once for `b2`) with
   no `Retain` between them — the object's strong count is still 1, but two Releases are now queued
   against it. The second Release either double-decrements an already-zero strong count or (worse)
   pushes the same now-freed arena slot back onto the free list a second time, corrupting it — a later
   `Alloc` could then hand the same slot out to two live objects simultaneously.
2. **Except side:** `_lowerReturn`'s exclusion check compared the returned `DCValue` against tracked
   entries by *value* equality. `return b2;` and `return b;` produce the identical `DCValue`, so
   excluding "the returned value" would exclude *both* tracked entries (b and b2 are indistinguishable
   by value) even when only one of the two local slots is actually being returned — under-releasing
   and leaking the other one's reference count permanently.

Verified this would actually happen (not just theorized): writing `core/examples/m2-alias/alias.dart`
against the *pre-fix* code and reasoning through `makeAliasAndReadValue`'s emitted DC-IR confirmed
scenario 1 exactly — two Releases against one Alloc'd object with no Retain in between.

## Decision

Two changes, both in `core/dcc-lower/lib/lower.dart`:

1. **Track `_heapLocals` by `VariableDeclaration` identity, not `DCValue` identity** (`List<
   VariableDeclaration>` instead of `List<DCValue>`). Two distinct local declarations can now share
   one underlying `DCValue` and still be released or excepted independently — exactly what aliasing
   needs. `_releaseHeapLocals` looks up each declaration's current `DCValue` via the existing `_values`
   map at the point of emission.
2. **Emit a `Retain` when a `VariableDeclaration`'s initializer is a direct `VariableGet` of an
   existing heap-typed value** (in `_lowerStatement`'s `VariableDeclaration` case) — i.e. exactly the
   aliasing shape, and only that shape. A fresh heap construction (`Box(v)`, going through
   `_lowerHeapConstruction`) needs no additional `Retain`: `Alloc` already establishes strong=1 for a
   brand-new object.
3. **`_lowerReturn`'s exclusion is now "except the `VariableDeclaration` named by a bare
   `VariableGet` return expression"**, not "except the returned `DCValue`". `return b2;` now correctly
   excepts only `b2`'s declaration, leaving `b`'s still queued for release — `return b.value;` (a field
   read, not a `VariableGet`) excepts nothing, since no tracked local is the thing being returned.

This is still the same naive, non-elided policy from ADR-0016 — no escape analysis, no borrow
inference. It now correctly handles one more shape (direct local-to-local aliasing) than it did
before, nothing more. GAP-0017's other items (heap references passed as function arguments, stored
inside another heap object's field, or returned as the heap pointer itself rather than read through)
remain exactly as unimplemented as before this ADR — none of those shapes are lowerable at all yet
(functions only take `u8`/`u32`/`u64`/`Result` parameters; `_lowerFieldType` only accepts
`u8`/`u32`/`u64` field types), so there was nothing to fix for them yet, only for aliasing.

## Rejected alternative

**Give every `VariableDeclaration` its own fresh `DCValue` by inserting a trivial "copy" IR
instruction on aliasing**, so `_heapLocals` could stay `DCValue`-keyed. Rejected: `dc-ir` has no
concept of a value-preserving copy for a pointer type (a copy of a `DCHeapPointer` is just... the same
pointer — the backend has nothing meaningful to emit for a "copy" beyond aliasing the SSA register,
which LLVM already does for free by construction). Introducing an instruction whose only job is "exist
so two names can both refer to it" is pure ceremony with no backend codegen behind it. Tracking by
declaration identity solves the exact same problem with no new DC-IR surface at all.

## Consequences

- Verified: straight-line aliasing (`makeAliasAndReadValue`) and aliasing scoped to one `if` branch
  while the other branch never sees the alias (`makeAliasBranch`) both release exactly once regardless
  of path, confirmed via 2000 real cycles with `dc_free_top` checked after every single call.
- Still NOT implemented (`docs/known-gaps.md` GAP-0017, updated): heap references as function
  parameters, heap references stored inside another heap object's field, returning the heap pointer
  itself through a chain of aliases (only returning *through* an alias via a scalar field read is
  exercised — `return b2;` itself, where the heap pointer crosses the function boundary, is untested;
  the exclusion logic above should handle it correctly by inspection, but "should handle it by
  inspection" is exactly the kind of claim this project's own rules say not to make without a real
  test, so it stays an open item, not a done one).
- `ClassInfo`/destructor dispatch remains deferred (GAP-0003, unchanged) — nothing here touches it.
