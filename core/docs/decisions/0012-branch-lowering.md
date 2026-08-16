# ADR-0012: Implement Branch/CondBranch backend lowering (block params → LLVM phi)

**Status:** decided

## Context

`ROADMAP.md` M1's third exit-criterion clause — `Result<u64, Err>` via `?` propagation — inherently
needs a conditional (is this Ok or Err?) with two continuations, one of which returns early. DC-IR's
`Branch`/`CondBranch` instructions have existed since the very first `core/dc-ir` unit, but
`core/backend` threw `BackendError` on both — nothing had ever exercised them, and `core/dcc-lower`
has never produced a multi-block `DCFunction`.

Attempting `Result<T,E>` end to end in one pass would have meant designing the value representation,
the propagation-call recognition, AND the branch-lowering primitive simultaneously, with no way to
tell which part a bug came from. Split instead: prove the backend primitive is correct in isolation
first, with a hand-built `DCFunction` (not routed through `dcc-lower`), then build `Result<T,E>`
lowering against a primitive already known to work.

## Decision

Implemented real `Branch`/`CondBranch` lowering in `core/backend/lib/llvm_emit.dart`:

- Every DC-IR block gets an LLVM label (`_labelFor`: block 0 keeps "entry", matching already-verified
  M0/M1 output; others are `blk<index>`).
- `Branch(target, args)` → `br label %<target>`.
- `CondBranch(cond, trueTarget, trueArgs, falseTarget, falseArgs)` → `br i1 %cond, label %<true>,
  label %<false>` (throws if `cond`'s DCType isn't `DCBool` — added `DCBool → i1` to `_llvmType`,
  previously unmapped).
- DC-IR's **block parameters** (its only merge-point mechanism, deliberately not phi instructions —
  see `core/dc-ir/README.md`) are translated to real LLVM `phi` nodes here, in the backend — exactly
  where DC-IR's own design rationale says that translation belongs (a codegen concern, not something
  DC-IR or dcc-lower should carry). A pre-pass (`_collectPredecessors`) scans every block's terminator
  to build each target block's incoming-edge list before any text is emitted, since LLVM requires all
  of a `phi`'s incoming edges declared together.

**Verified independent of dcc-lower**, on purpose: a hand-built `DCFunction` for
`select(bool, u64, u64) -> u64` (`entry` conditionally branches to `blk1`/`blk2`, both merge into
`blk3` via a real 2-predecessor `phi`) was run through `emitModule`, producing textually correct LLVM
IR, compiled, linked against a small C harness, and run with 4 input combinations — all correct.
Confirmed the freestanding property still holds when compiled for the `x86_64-unknown-none-elf`
target. Confirmed no regression on all three existing conformance targets (M0's `add`, M1's `Pointer`
and `Struct` examples all still pass their build+freestanding-check steps).

## Consequences / what this does NOT do yet

`core/dcc-lower` still cannot produce a multi-block `DCFunction` — nothing in it recognizes a Dart
`if`/conditional expression, and there is no DC-IR comparison instruction (`==`, `is`, etc.) to
compute a `DCBool` from, which any real conditional needs. That's the actual remaining work for
`Result<T,E>`/`?`, tracked as **GAP-0007**. This ADR only proves the backend primitive the next step
depends on is correct — it does not itself implement `Result<T,E>`.
