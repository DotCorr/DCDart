# ADR-0009: Implement real overflow-trapping arithmetic codegen (M1 increment)

**Status:** decided

## Context

`DCDART_SPEC.md` §4.1: arithmetic "traps in both [debug and release] by default." M0's
`core/backend/lib/llvm_emit.dart` emitted plain `add`/`sub`/`mul` regardless of `Overflow.trapping`
vs `Overflow.wrapping` — a documented, deliberate M0-scope cut (see the original comment, and
`core/backend/m0-target.md` §4 item 2's forward note on how to do it properly). `add.dart`'s `a + b`
lowers to `IAdd(overflow: Overflow.trapping)` per `core/dcc-lower`, so M0's own example was silently
wrapping instead of trapping — correct per M0's stated scope, but a real semantic gap worth closing
before building more on top of it.

## Decision

Implemented exactly what `m0-target.md` §4 item 2 already specified: `Overflow.trapping` now emits
`llvm.{u|s}{add|sub|mul}.with.overflow.iN` + a conditional branch to a block calling `llvm.trap()` +
`unreachable`. Verified end to end: `dcc build --mode bare` still produces an `add.o` that passes
`verify-freestanding.sh` (these intrinsics lower to inline instructions on x86_64 — `add`+`seto`/`jo`
and `ud2` respectively — never an external symbol, exactly as the design doc predicted), and
`add(2,3)` still returns 5 (no overflow on this input, so the trap path is never taken).

This required `core/backend/lib/llvm_emit.dart` to emit **multiple LLVM basic blocks per function**
for the first time — one DC-IR instruction (a single `IAdd`) can now expand into three LLVM blocks
(the intrinsic call + branch, the trap block, the continuation block). Added `_FunctionEmitter`, a
small block-accumulator, to make that expansion mechanical rather than ad hoc string concatenation.
This is purely an LLVM-text-output concern — DC-IR's own functions are still single-block for
everything `dcc-lower` produces so far (no `Branch`/`CondBranch` DC-IR instructions exist yet).

`Overflow.wrapping` is unchanged: plain LLVM arithmetic already wraps on fixed-width integers, so no
expansion is needed for it.

## Consequences

- `core/backend/README.md`'s "what's implemented" section needs updating (done) — trapping arithmetic
  is no longer a documented gap.
- Any future `dcc-lower` addition that emits `IMul`/`ISub` with `Overflow.trapping` gets correct
  codegen automatically — this wasn't function-specific.
- `_FunctionEmitter`'s multi-block support is a real, if minimal, piece of general machinery: it's
  ready for `Branch`/`CondBranch` DC-IR lowering (needed for real control flow, M1+) without another
  rewrite of the emitter's block-handling.
