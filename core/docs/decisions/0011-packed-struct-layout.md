# ADR-0011: @packed struct as getter/setter declaration order, zero new DC-IR instructions

**Status:** decided

## Context

`ROADMAP.md` M1's second exit-criterion clause: "defines a `@packed` struct matching a known C
layout (verified byte-for-byte against a C reference)." `DCDART_SPEC.md` §6 shows `@packed final
class ... extends Struct` with `external` fields — real `dart:ffi`-style struct sugar, which only
works because the Dart VM's FFI compiler has genuine magic for `external` fields on FFI `Struct`
subtypes. DCDart has no such magic (no compiler exists yet), so `external` fields as literally
written in the spec example won't compile under vanilla Dart at all.

## Decision

Same prelude-approximation approach as ADR-0008/0010: `Struct` (a real class, `core/runtime/dc-core-
bare/prelude.dart`) wraps a base address (`u64`, same "not plain `int`" reasoning as `Pointer`), and
subclasses declare fields as **getter/setter pairs** (bodies never executed, same as `Pointer.value`)
instead of `external` fields. `@packed` is a class-level annotation, same `InstanceConstant` pattern
as `@bare`.

Empirically verified (introspection, not assumed): `Class.procedures` preserves declaration order
exactly — a getter immediately followed by its setter, in source order across fields. `dcc-lower`'s
`_StructLayouts.layoutFor` walks this list, takes only `ProcedureKind.Getter` entries (a getter/
setter pair is one field), and computes packed byte offsets as a running sum of each field's width
(u8=1, u32=4, u64=8) — no alignment padding, matching a C reference compiled with `#pragma
pack(1)`/`__attribute__((packed))`.

**Zero new DC-IR instructions.** A struct "instance" is represented as nothing more than its base
address (`DCInt.u64`) — `Struct.fromAddress` is an identity pass-through at the DC-IR level, not a
new node. `instance.field` lowers to the exact same instruction sequence
`Pointer<u32>.fromAddress(x).value` already produces: `ConstInt(offset)` → `IAdd(base, offset)` →
`IntToPtr` → `Load`/`Store`. This sidesteps needing `DCStruct`/`ClassInfo` (`docs/known-gaps.md`
GAP-0003, which remains open and unrelated — that gap is about ARC'd heap objects with vtables, a
different concept from this stack/MMIO-style packed struct with no ARC involvement at all).

**Verified end to end**, with a genuinely strong check: `core/examples/m1-struct/header.dart` (a
`Header` struct with `u8 a` at offset 0, `u32 b` at offset 1 — packed, so `b` is NOT 4-byte-aligned)
compiles via real `dcc build --mode bare`, passes `verify-freestanding.sh`, and — retargeted natively
— links against `core/examples/m1-struct/main.c`, which defines an *independent* C reference struct
(`#pragma pack(1)`) and cross-checks: `sizeof`/`offsetof` match DCDart's computed layout, writing
through DCDart's `writeHeader` and reading the raw bytes via the C struct overlay matches, and
reading back through DCDart matches too. Exit code 0 — this is a real byte-for-byte cross-language
layout proof, not merely "DCDart's own read matches DCDart's own write."

## Rejected alternative

**Natural-alignment (non-packed) layout support.** `dcc-lower` requires `@packed` on every `Struct`
subclass and throws if absent (`_StructLayouts.layoutFor`) rather than silently defaulting to some
alignment rule. Rejected building natural alignment now: it's real, separate logic (per-field
alignment requirements, then padding insertion, then possibly tail padding for array-of-struct
cases) that this one conformance target — which specifically wants packed, C-compatible MMIO-style
layout — doesn't exercise. Throwing a clear error for the unhandled case is better than guessing an
alignment rule with no test pressuring it to be right.

## Consequences

- `core/dcc-lower/lib/lower.dart` grew a `_StructLayouts` helper (class-level, cached, shared across
  all functions in one module) — the first piece of dcc-lower state that isn't purely per-function.
- Field types are restricted to `u8`/`u32`/`u64` (whatever `_StructLayouts._lowerFieldType` and the
  general `_lowerType` recognize) — a struct field of a not-yet-supported type throws immediately,
  not silently miscomputes its width.
- `core/backend` needed **no changes at all** for struct support — everything routes through
  instructions it already emits (ConstInt/IAdd/IntToPtr/Load/Store). Worth noting explicitly: this is
  a sign the M0/M1 instruction set was scoped well, not a coincidence.
