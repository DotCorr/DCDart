# ADR-0018: Direct function-to-function calls (`Call` DC-IR instruction)

**Status:** decided, implemented, AND VERIFIED — `core/examples/m2-call/calls.dart` builds via real
`dcc build --mode bare`, passes `verify-freestanding.sh`, and
`core/tests/conformance/m2-call/run.sh` reports an unqualified PASS under WSL/Ubuntu: direct calls
(`doubleValue`, `addAndDouble`), a `Result`-returning callee (`checkPositive`), and a call composed
with `.propagate()` (`validateAndDouble`) all verified correct over hundreds of real values. All six
pre-existing conformance harnesses re-verified with zero regressions.

## Context

Scoping GAP-0017's "heap reference passed as a function argument" item surfaced a bigger, entirely
undocumented gap (recorded as GAP-0018 the moment it was found, per this project's own "no silent
scope cuts" rule): `core/dc-ir` had no function-call instruction at all, and `core/dcc-lower` had no
recognition of a `StaticInvocation` targeting a second user-defined `@bare` function. Every
conformance target from M0 through M2's alias slice happened to be satisfiable as a single
self-contained leaf function, so this was never exercised — not a deliberate cut, just never hit until
now. No DCDart program more complex than one function (no helpers, no recursion, no calling into a
future `dc:core.bare` stdlib) could be lowered before this.

## Decision

A new DC-IR instruction, `Call` (`core/dc-ir/lib/instructions.dart`):

```dart
final class Call extends DCInstruction {
  final DCValue? dest;       // null iff the callee returns void
  final String targetName;   // matches the callee DCFunction.linkName
  final List<DCValue> args;
}
```

**Direct calls only** — `targetName` names exactly one function in the same module. No vtable,
`ClassInfo`, or dynamic dispatch is involved (spec §4.3's monomorphized dispatch is M5+ scope, not
touched here). This is consistent with DCDart having no polymorphism story yet at all.

**Backend (`core/backend/lib/llvm_emit.dart`):** a plain LLVM `call`, e.g.
`%v3 = call i64 @doubleValue(i64 %v2)`, or `call void @foo(...)` when `dest` is null. The callee's
return-type text comes from `dest`'s own `DCType` (or `void` literally when `dest == null`) — same
"every instruction self-describes its own types, never cross-references another function's
declaration" pattern every other instruction in this file already follows (e.g. `Return` never looks
up `DCFunction.returnType` either). Since every function in a module is emitted as a top-level
`define` and LLVM resolves top-level symbols in one pass, call target order doesn't matter — a
function can call one declared later in the same source file with zero special handling.

**`dcc-lower` (`core/dcc-lower/lib/lower.dart`):** `_lowerBareCall`, reached from `StaticInvocation`
handling as the *last* case checked (after every prelude-member shape), so a real prelude member (like
`u64|+`) can never be misread as a user function call — it would already have matched and returned by
that point. Recognized via `_hasMarkerAnnotation(target.annotations, '_Bare', preludeUri)` — the exact
same check `lowerToDCModule` uses to decide which top-level procedures to lower as functions in the
first place, so "callable" and "lowered as a function" are, by construction, the same set. The
callee's parameter/return types are lowered on demand via the existing `_lowerType` (called against
the *target* `Procedure`'s signature, not the caller's own) — no separate signature pre-pass is
needed, since Kernel IR has already fully resolved `StaticInvocation.target` to the real `Procedure`
node regardless of declaration order.

**Scope cut, deliberate:** only scalar (`u8`/`u32`/`u64`/`Result`) parameter and return types are
handled — `_lowerType` still throws on anything else, including a `DCHeapPointer`-typed parameter or
return. This is exactly GAP-0017's still-open item; `Call` existing at all is what makes that item
tractable next (needs `_lowerType` extended to recognize `HeapObject` subclasses for parameter/return
position, not just constructor/field-access position as it does today), but doing both at once would
have made this single unit harder to verify in isolation.

**Scope cut, deliberate:** a void-returning callee cannot be called as an *expression* — `_lowerBareCall`
throws a clear error naming this, rather than silently producing a `DCValue` with no real Dart-level
type to attach it to. Calling a void function as a bare statement needs `_lowerStatement`'s
`ExpressionStatement` case extended to handle a `StaticInvocation` (today it only handles
`InstanceSet`), which no conformance target has needed yet.

**Ownership convention for a future heap-typed argument (recorded now, not exercised yet):** borrowed,
not retained — the caller does not `Retain` before the call, and the callee must not track its own
heap-typed parameters in its naive release list (`_heapLocals`, ADR-0016/0017). This mirrors the
"guaranteed" parameter convention real ARC languages default to. Documented in the `Call` instruction's
own doc comment now so it's decided once, ahead of GAP-0017's remaining work, rather than improvised
per call site later.

## Rejected alternative

**Inline the callee at every call site instead of a real `call` instruction.** Rejected outright, not
seriously considered: DCDart's design (spec §1, a real Kernel-IR-consuming pipeline with its own
codegen) assumes real function boundaries exist — recursion alone makes naive inlining impossible in
general, and this project's own discipline is "build the real mechanism, not an approximation that
happens to pass the one test written for it."

## Consequences

- `core/examples/m2-call/calls.dart` exercises: a direct call from a `return` expression
  (`addAndDouble` → `doubleValue`), a direct call from a `final` local's initializer (the `sum`
  intermediate in the same function), a `Result`-returning callee (`checkPositive`), and — with zero
  additional plumbing needed — a call's result immediately having `.propagate()` invoked on it
  (`validateAndDouble`), proving `Call` composes with ADR-0014's existing mechanism for free (a call
  site is just another expression to `_lowerExpression`, and `.propagate()`'s receiver-lowering was
  always generic).
- GAP-0018 is resolved for direct, scalar-typed calls. GAP-0017's remaining item (heap references as
  function arguments) still needs `_lowerType` extended for `HeapObject` subclasses in
  parameter/return position — tracked there, not duplicated here.
- Recursion is untested — nothing about the design should prevent it (Kernel IR resolves
  self-references the same way as any other reference, and LLVM handles recursive `call`s natively),
  but "should work by inspection" is exactly the kind of claim this project's own rules say not to make
  without a real test, so it stays unclaimed until a conformance target actually exercises it.
