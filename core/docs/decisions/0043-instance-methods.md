# ADR-0043: Instance methods lower to functions with the receiver as parameter 0

**Status:** decided — implemented and verified (`tests/conformance/methods/`)

## Context

DCDart had only top-level functions. A `HeapObject` subclass could hold fields but could not have
behaviour, so no DCDart program could be written in the shape the language's own syntax suggests.

That is a gate problem, not an ergonomics one. GAP-0035 established that four of M3's five benchmarks
— a JSON parser, a hashmap workload, a tree traversal — describe object-oriented workloads. Without
methods they would have to be written as top-level functions taking an explicit receiver, which is
not the code anyone means when they say "measure ARC on realistic hosted code".

## Decision

A non-static method on a `HeapObject` subclass lowers to an ordinary `DCFunction` whose **first
parameter is the receiver**, named `Class_method`.

Kernel does not put `this` in `positionalParameters` — it is implicit, reached through
`ThisExpression` — so the receiver is prepended during lowering and bound to a `_thisValue` rather
than to a `VariableDeclaration`. `ThisExpression` then resolves to parameter 0.

At the call site, `InstanceInvocation` becomes a direct `Call` with the receiver as argument 0.

**No dynamic dispatch, and this is not a deferral.** ADR-0022 established the same fact for
destructors: every heap object's concrete class is statically known at its `Alloc` site, because
DCDart has no subtype polymorphism yet. A vtable would be machinery with nothing to dispatch on. When
real dynamic dispatch arrives (spec §4.3, GAP-0003) this becomes the static-call fast path rather than
something to undo.

### Details that are decisions rather than mechanics

**`Class_method` rather than a mangling scheme.** `linkName` is emitted verbatim (spec §9) with no
mangling anywhere downstream, so the name has to disambiguate on its own — two classes may declare
`net()`. A readable `Account_net` keeps the symbol callable from C and greppable in a disassembly, and
DCDart has no overloading for a mangling scheme to disambiguate anyway.

**The receiver is BORROWED.** It takes ADR-0019's default: the caller holds its reference across the
call, so the callee must not release it. Making the receiver `@owned` would mean every method call
consumed its object, which is not what `a.net()` means in any language.

**Getters, setters and operators are REJECTED, not ignored.** A getter on a `HeapObject` subclass
throws a specific error naming the kind. Silently not lowering it would produce the confusing
downstream failure `"Account" has no field "net"` at the call site — the shape GAP-0028 established is
worse than a compile error. They are a straightforward extension; they are simply not built.

## Verification

`tests/conformance/methods/` builds freestanding first (a method is just a function and must not drag
in a runtime — the spine check passes), then builds for the host and runs against the **generated**
header, so a wrong receiver type is a compile error rather than silent corruption.

The two cases worth having a target for:

- **A method calling another method on the receiver** (`netAfterDeposit` → `afterDeposit`), which is
  exactly what breaks if `this` is not threaded through correctly.
- **Two live receivers in one function**, so the receiver argument genuinely varies rather than being
  a constant the optimizer folds away.

## Consequences

- One M3 prerequisite closed. Six remain (GAP-0035): `null`/nullable heap refs, heap-typed field
  stores (escalation 0006), generics, closures, `String`, `for` loops.
- Methods compose with everything already built — ARC, `Result`, the new operators — because they are
  ordinary functions from DC-IR down. Nothing in `dc-elide`, `dc-objdump` or the backend needed to
  change, which is the practical argument for this lowering over a dispatch mechanism.
- Constructors are still the only other class member that lowers, and they remain special-cased at the
  `Alloc` site rather than being functions. Unifying them is not obviously right and was not attempted.
