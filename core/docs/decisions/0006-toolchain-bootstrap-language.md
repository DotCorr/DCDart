# ADR-0006: The whole dcc toolchain (dcc, dcc-lower, dc-ir, backend) is Stage-0 plain hosted Dart

**Status:** decided
**Supersedes/extends:** `0002-dcc-bootstrap-language.md`, which made this call for `core/dcc/` alone

## Context

ADR-0002 decided `core/dcc/`'s CLI driver is plain hosted Dart — real `dart:core`, no DCDart-specific
syntax — because writing the compiler's own entry point *in* DCDart is circular before a working
DCDart compiler exists.

`core/dc-ir/` was written concurrently by a separate unit, using DCDart-flavored sized-integer field
types (`u32 index`, `u64 bits`) per that unit's brief to express the shape in DCDart's own
conventions. That unit correctly noticed the inconsistency, declined to resolve it unilaterally
(it's a bootstrap-language decision, not a type-shape decision), and filed it as GAP-0004 for
someone to actually decide.

## The question

Does ADR-0002's reasoning apply only to `dcc`'s CLI entry point, or to the whole pipeline it drives
(`dcc-lower`, `dc-ir`, `backend`)?

## Decision

The whole pipeline. `dcc-lower`, `dc-ir`, and `backend` have the exact same circularity `dcc` does:
something has to parse Kernel IR, build `DCFunction` values, walk them, and emit LLVM IR, and none
of that can be DCDart source run by a DCDart compiler, because that compiler is what's being built.
`dart2wasm` — spec §1's own cited existence proof for forking at the Kernel boundary — is itself an
ordinary Dart program, not a Wasm program that somehow compiles Wasm programs. Same shape here.

So: `core/dc-ir/*.dart` and everything `core/dcc-lower/` and `core/backend/` add are **plain hosted
Dart**, matching `core/dcc/`. Concretely for `dc-ir` (already written): `ValueId.index`,
`BlockId.index`, and `ConstInt.bits` are retyped from `u32`/`u64` to plain `int`, with a doc comment
at each site stating the conceptual width and that no host-level range check enforces it — the same
"documented contract, not enforced" pattern the rest of `dc-ir`'s README already uses for SSA/
terminator invariants.

This is a Stage-0/self-hosting split, common in bootstrapped compilers: the tool that builds DCDart
programs is not itself a DCDart program, until some future milestone deliberately rewrites it as one
(genuine self-hosting, analogous to a C compiler eventually being written in C). Nothing here
forecloses that; it just says today's toolchain isn't there.

## Consequences

- `core/dc-ir/ssa.dart` and `instructions.dart` were edited to use `int` instead of `u32`/`u64`,
  closing GAP-0004.
- Every future file under `core/dcc-lower/`, `core/dc-ir/`, `core/backend/`, and `core/dcc/` should
  be written as plain, idiomatic hosted Dart from the start — no sized-integer field types, no
  DCDart-only syntax — so this question doesn't need re-litigating per-unit.
- `core/frontend/vendor/dart-sdk/pkg/front_end` and `pkg/kernel` (vendored per ADR-0005) are
  themselves plain Dart packages — this decision keeps the whole toolchain in one implementation
  language end to end, which is also what makes depending on them directly (rather than through some
  DCDart-side wrapper) sensible.
