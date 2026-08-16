# ADR-0010: M1 Pointer<u32> via prelude extension + dcc-lower pattern match + Load/Store/IntToPtr

**Status:** decided

## Context

`ROADMAP.md` M1 exit criterion (first clause): "a `@bare` program reads and writes a memory-mapped
register through `Pointer<u32>`." `DCDART_SPEC.md` §6 shows the target shape:
```dart
final reg = Pointer<u32>.fromAddress(0xFEE0_00F0);
reg.value = reg.value | 0x100;
```

Same bootstrap-circularity situation M0 solved (ADR-0008): no real front_end fork exists, so
`Pointer<T>` needs to be expressible as ordinary Dart the ADR-0008 prelude approach already
established, extended with a new pattern.

## Decision

Extended `core/runtime/dc-core-bare/prelude.dart`: `u32` (a second sized-int extension type, same
shape as `u64`) and `Pointer<T>` (a real generic class with a named constructor `.fromAddress` and a
`.value` getter/setter whose bodies are never executed — see the file's header comment for why that's
fine, same reasoning as `u64 operator+`'s body in ADR-0008).

`Pointer.fromAddress`'s address parameter is typed `u64`, not plain `int` — verified necessary:
`core/dcc-lower` compiles with `--no-link-platform` (ADR-0008), so a genuine `dart:core::int`
reference is an *unbound* platform class node; inspecting it (even just `.classNode.name`) throws
("Reference to dart:core::int is not bound to an AST node"). `u64` is a local prelude declaration,
always fully bound, so it's safe to inspect. Confirmed empirically before writing any dcc-lower code
against it (same discipline as ADR-0008's introspection).

Empirically verified Kernel IR shapes (re-derivable the same way ADR-0008's were):
- `final reg = Pointer<u32>.fromAddress(address);` — a `VariableDeclaration` whose `.initializer` is
  a `ConstructorInvocation` with `target.name.text == 'fromAddress'`,
  `target.enclosingClass.name == 'Pointer'`, `target.enclosingLibrary.importUri` == prelude, and
  `arguments.types == [ExtensionType(u32)]` (the generic instantiation's type argument, preserved in
  full by Kernel IR).
- `reg.value = value;` — an `ExpressionStatement` wrapping `InstanceSet` with
  `.interfaceTarget.name.text == 'value'`, same class/library checks.
- `reg.value` (as an expression) — `InstanceGet`, same shape.

`core/dc-ir` gained three instructions: `Load`, `Store`, `IntToPtr` (see
`core/dc-ir/lib/instructions.dart`). `core/dcc-lower/lib/lower.dart` was generalized from "one
`ReturnStatement`" to a real statement-sequence walker (locals via `VariableDeclaration`, property
set/get, return) sharing one `VariableDeclaration -> DCValue` table for both parameters and locals.
`core/backend/lib/llvm_emit.dart` emits `inttoptr`/`load`/`store` against LLVM's opaque `ptr` type.

**Verified end to end**, not just type-checked: `dcc build --mode bare` on
`core/examples/m1-pointer/mmio.dart` produces an object passing `verify-freestanding.sh`, and the
same code retargeted natively, linked against `core/examples/m1-pointer/main.c` (which checks the
memory at the given address was *actually* mutated, not just that a return value matched), returns
exit 0 — real memory read/write through a compiler-generated pointer, confirmed correct.

## Rejected alternative

**A real generic monomorphizer**, recognizing `Pointer<T>` for arbitrary `T` rather than pattern-
matching the single `Pointer<u32>` instantiation. Rejected for now: `DCDART_SPEC.md` §4.2's
monomorphization is real, larger, general machinery (dedup identical instantiations at link time,
handle arbitrary generic classes/functions) that this one conformance target doesn't pressure-test.
`dcc-lower`'s `_pointeeTypeFromTypeArgs` already reads the real type-argument list from Kernel IR
(not hardcoded to ignore it) — extending it to a second instantiation (e.g. `Pointer<u64>`) is a
straightforward addition to the existing type-matching, not a redesign. Building the general
monomorphizer now, before a second/third instantiation actually needs it, would be exactly the kind
of premature generality this project's own conventions warn against.

## Consequences / known gap

**No `@volatile` semantics.** `DCDART_SPEC.md` §6 requires the compiler to never reorder or elide
MMIO access; the emitted plain `load`/`store` carry no such guarantee (LLVM's optimizer is free to
reorder/eliminate them under its normal aliasing rules, since `dcc build` doesn't currently run any
LLVM optimization passes at all this wouldn't bite today, but it's a real correctness gap the moment
optimization passes are added). Logged as GAP-0006 in `core/docs/known-gaps.md`. Fix is small when
needed: mark the emitted `load`/`store` `volatile` in `llvm_emit.dart` (and thread a `@volatile`
recognition through `dcc-lower`) — not built now because nothing yet forces the distinction (no
optimizer runs), and building it blind risks guessing the wrong DC-IR-level representation (a flag on
`Load`/`Store`? a separate instruction?) before real pressure clarifies which.
