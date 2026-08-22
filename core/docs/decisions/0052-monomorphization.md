# ADR-0052: Generics, monomorphized

**Status:** decided — implemented and verified (`tests/conformance/generics/`)

## Context

`DCDART_SPEC.md` §4.2 specifies monomorphized generics. Nothing implemented them: a generic function
failed with `unsupported type TypeParameterType`, which blocked every container and therefore M3's
hashmap benchmark (GAP-0035).

## Decision

A generic function is a **template, not a function**. It has no machine representation — `T` has no
size, no calling convention, no layout — so nothing is emitted for it. One specialization per distinct
type argument is emitted instead, named `pick$u64`.

`$` cannot appear in a Dart identifier, so a specialization can never collide with a hand-written
name. That matters because `linkName` is emitted verbatim (spec §9) with no mangling downstream.

**Specializations are discovered from call sites, and queued during lowering rather than in a separate
discovery pass.** Which specializations exist is only knowable by walking call sites; walking them
twice — once to discover, once to lower — would be two implementations of the same traversal, free to
disagree. The queue drains in a loop rather than a single pass, because lowering one specialization
can discover others (a generic calling a generic).

**The whole mechanism touches one function.** `_lowerType` resolves `TypeParameterType` through a
substitution map; once `T` is a concrete type there, every downstream pass — `dc-elide`, `dc-objdump`,
the backend — sees an ordinary function and needs no knowledge of generics whatsoever. That property
is why monomorphization is the right choice for this compiler and not merely the spec's choice: the
alternative (boxing, or passing type descriptors) would have touched the ARC conventions, the calling
convention and the C ABI story all at once.

## The part that was not obvious

A callee's signature mentions **its own** type parameters, which the caller's substitution knows
nothing about. Lowering `pick<T>`'s return type from inside `useU64` using `useU64`'s (empty)
substitution fails with *"type parameter T has no binding"* — reported at the caller, which is a
confusing place to see it.

Callee signature types are therefore resolved against the **call site's type arguments**, in
`_lowerCalleeType`. And that argument may itself be a type parameter — when a generic calls a generic,
`pick<T>(...)` inside `firstOfSecond<T>` — so it is resolved through the *current* substitution before
being handed on. Both the return type and every parameter type needed this; missing the second is what
the third failed build was.

## Verification

`tests/conformance/generics/` asserts the **symbol table**, not just the values:

```
pick$u64  pick$u32  pick$u8  second$u64  firstOfSecond$u64     and no bare `pick`
```

That distinction is the point. A wrong implementation that emitted one shared body would still compute
every right answer in the behavioural test; only the symbols show whether specialization actually
happened. The absence check matters equally — a bare `pick` symbol would mean something lowered `T` as
if it had a machine representation.

## Consequences

- M3's hashmap benchmark becomes writable, and containers generally. **`String` is the last
  prerequisite** (GAP-0035).
- Code size grows with the number of instantiations, which is monomorphization's known cost and the
  reason the spec chose it deliberately rather than by default. Nothing measures it yet.
- **Generic CLASSES are not implemented**, only generic functions. A `Box<T>` needs per-instantiation
  field layout, which interacts with `_HeapLayouts` and the destructor cascade (ADR-0022). Filed as
  GAP-0040 — the containers M3 wants will need it.
- Recursion through a type parameter (`f<T>` calling `f<Box<T>>`) would queue specializations forever.
  Nothing rejects it yet; it is unreachable while generic classes do not exist, and is recorded in
  GAP-0040 rather than guarded speculatively.
