# dc-ir/ — DC-IR type definitions

Maps to `DCDART_SPEC.md` §1: "DC-IR — typed SSA, explicit retain/release", the
stage between `dcc-lower` (monomorphize, ARC insert, elide, unbox) and
`backend/` (DC-IR → LLVM IR → object file).

**Status:** real pub package (`dc_ir`), consumed for real by `core/dcc-lower` (builds `DCFunction`
values from Kernel IR) and `core/backend` (emits LLVM IR from them) — confirmed end to end: `dcc
build --mode bare` produces a real object file that passes `verify-freestanding.sh`, for all fourteen
conformance targets (M0 through M2's real `while`-loop slice, `docs/decisions/0028-while-loop.md`).
The loop slice needed zero new DC-IR instructions — a loop header is just an ordinary block-parameter
merge point (this file's own "why block-parameter SSA, not phi nodes" design), which `core/backend`
already handled generically once its predecessor-label tracking was fixed (ADR-0028's own "bug found
along the way").
`Alloc` (`instructions.dart`) gained an optional `destructorName` for the destructor-cascade slice
(ADR-0022) — `Release` itself needed no shape change at all. A new `DCWeakPointer` type (`types.dart`)
and `MakeWeak`/`WeakLoad`/`DropWeak` instructions were added for weak references (ADR-0023). Grown
well past M0's original `IAdd`-only scope (see "Scope cuts" below, corrected to reflect this) — do not
read "consumed for real" as "the type system stopped changing."

## File map

| File | Contents |
|---|---|
| `lib/types.dart` | `DCType` hierarchy — the value types every `DCValue` is typed with |
| `lib/ssa.dart` | `ValueId`, `BlockId`, `DCValue` — the id-based reference model |
| `lib/instructions.dart` | `DCInstruction` hierarchy — constants, arithmetic, ARC, terminators |
| `lib/function.dart` | `DCBasicBlock`, `DCFunction`, `DCModule` — the container structure |
| `lib/dc_ir.dart` | barrel export of the four files above — `import 'package:dc_ir/dc_ir.dart'` |

Read the first four in that order; each imports the ones before it.

## What this is and isn't

This is a **type/interface design**, not an implementation. The files above
are written as DCDart source — sealed classes, sized integers, `const`
constructors, structural `==` — per this task's instruction to express the
shape in DCDart's own conventions rather than prose, so the next agent
implementing `dcc-lower` has concrete typed signatures to build against
instead of a description to re-derive them from.

**Resolved:** `docs/decisions/0006-toolchain-bootstrap-language.md` decided the whole toolchain
(`dcc`, `dcc-lower`, `dc-ir`, `backend`) is Stage-0 plain hosted Dart, extending
`0002-dcc-bootstrap-language.md`'s reasoning for `dcc` alone. `ValueId.index`, `BlockId.index`
(`ssa.dart`), and `ConstInt.bits` (`instructions.dart`) are `int`, not `u32`/`u64` — each with a doc
comment stating the conceptual width, since nothing at the host-Dart level enforces it. `GAP-0004` is
closed. Everything else in this directory (the sealed-class shapes, structural equality, block-
parameter SSA) was already ordinary Dart and needed no change.

## Design decisions

### Typed SSA, block-parameter form (not phi nodes)

DC-IR represents merge points as basic-block parameters (`DCBasicBlock.params`
in `function.dart`) bound positionally by `Branch`/`CondBranch` arguments
(`instructions.dart`), the way MLIR, Cranelift, and Swift SIL do it — not as
phi instructions scattered through block bodies the way LLVM IR (and DC-IR's
own eventual output) does.

Two reasons this is the right shape for *this* IR specifically, even though
the backend will need to re-lower it to LLVM's phi form:

1. A function's parameters and a block's parameters become the same
   mechanism (`function.dart`'s `DCFunction` note) — one thing to define,
   not two.
2. ARC insertion (M2) has to reason about "what's live, and who owns it, at
   this block boundary." A block's `params` list is a direct, complete
   answer to that question. Reconstructing the same answer from phi
   placement — which phis exist, which block each corresponds to, which are
   really the same value — is strictly more work for every pass that needs
   it, for no benefit at the DC-IR level (LLVM's phi form is a codegen
   concern belonging to `backend/`'s lowering, not to DC-IR).

Recorded as `docs/decisions/0003-dc-ir-id-based-references.md` alongside the
id-reference decision below, since both shape the same files.

### Id/arena references, not object pointers, between IR nodes

`DCBasicBlock`s refer to each other by `BlockId` (a `u32` index), and
`DCValue`s are named by `ValueId`, both resolved through the `List`s a
`DCFunction` owns — never a direct Dart-object reference from one IR node to
another. See `ssa.dart`'s header comment for the full reasoning; in short:

- It means the IR graph itself has no strong-reference cycles to worry about
  (a loop's back-branch is an integer, not a pointer), so CLAUDE.md's
  "back-pointers are `weak`/`unowned`" rule has nothing to bite on inside
  `DCBasicBlock`/`DCInstruction` — there are no back-pointers, structurally.
- It keeps this design portable across the open host-language question
  above: an id into an array means the same thing in any host language,
  where a pointer-based object graph would carry that host language's
  reference/lifetime semantics into the IR's own definition.

### `Overflow` as an enum, not a `bool wrapping` field

`IAdd`/`ISub`/`IMul` (`instructions.dart`) carry `Overflow overflow`
(`trapping` or `wrapping`), not a bare boolean. Spec §4.1 makes overflow
behavior a named, load-bearing, source-visible distinction (`+` vs. `&+`,
with a mandatory comment on the wrapping form) — the IR should say
`Overflow.trapping` at every read site, not force every reader to remember
which polarity `wrapping: false` means.

### `DCHeapPointer` as a distinct type from `DCPointer`

`Retain`/`Release` (`instructions.dart`) take an operand typed
`DCHeapPointer`, a new `DCType` (`types.dart`) distinct from the existing
`DCPointer` (spec §6's raw `Pointer<T>`). This is the minimum type
distinction needed to make "you can't retain a raw pointer" a compile-time
fact instead of a convention, without designing the full heap-object /
`ClassInfo` / vtable layout that a complete ARC implementation eventually
needs. See "Why Retain/Release exist in an M0 deliverable" below, and
`docs/known-gaps.md` GAP-0003 for what's explicitly deferred.

## Why Retain/Release exist in an M0 deliverable

`add(u64, u64)` needs zero ARC operations — `u64` is a value type, nothing in
M0 is heap-allocated. `Retain`/`Release` are in `instructions.dart` anyway
because CLAUDE.md rule 4 freezes memory-model conventions after M3, and ARC
node *shape* is a memory-model convention in the sense that matters here:
once M2's ARC-insertion pass and M3's elision benchmarks are written against
a particular `Retain`/`Release` signature, changing that signature means
rewriting both. Getting the shape right at M0 — while the cost of being wrong
is "edit two class definitions" rather than "rewrite an inserter and its
test suite" — is cheaper than bolting it on later. This does not freeze the
*memory model itself* (§3, still open until M3 per the roadmap); it freezes
only these two node's field lists, which is a much smaller commitment.

## Worked example: M0's `add.dart`

See `function.dart`'s `DCFunction` doc comment for the full lowering of
`core/examples/m0-seam/add.dart`'s `@bare u64 add(u64 a, u64 b) => a + b;`
into a `DCFunction` literal — one block, one `IAdd` (`Overflow.trapping`,
because plain `+` traps per spec §4.1), one `Return`, zero ARC ops.

## Scope cuts — what is not here

This section was originally written for M0 and said "no comparisons, no
field/element access, no calls, no allocation, no weak/unowned reads" — all
now false, corrected below rather than left stale (M1 added `ICmp`/`Load`/
`Store`/`IntToPtr`/`Branch`/`CondBranch`/`MakeStruct`/`ExtractField`; M2
added `PtrOffset`/`Alloc`/`Retain`/`Release` (real codegen, not just
placeholder shape), `Call` (`docs/decisions/0018-function-calls.md`), and
`MakeWeak`/`WeakLoad`/`DropWeak` (`docs/decisions/0023-weak-references.md`
— `weak` reads specifically; `unowned` still absent). Still genuinely
absent, on purpose: no generics, no vtables/interfaces, no full class/
`ClassInfo` layout for genuine dynamic dispatch (`types.dart`'s header
note, `docs/known-gaps.md` GAP-0003 — a direct-call destructor cascade
exists, ADR-0022, which is not the same thing), `unowned` reads, no casts,
no bit ops, no float instructions, no indirect/virtual calls (`Call` is
direct-only, ADR-0018). Every instruction that does exist was added
against a real conformance target's actual pressure, not speculatively —
see each instruction's own doc comment in `instructions.dart` for which
target and ADR motivated it.

## What isn't validated by construction

These types describe *legal* DC-IR; nothing in this module *checks*
legality. In particular, none of the following are enforced by the Dart
type system as written — they are invariants a future verifier pass (part of
whoever builds the first real `dcc-lower`) must check explicitly:

- A `DCBasicBlock.body`'s last element is a `DCTerminator` and no earlier
  element is.
- `DCFunction.paramTypes` equals `blocks[0].params.map((v) => v.type)`.
- Every `DCValue` naming a given `ValueId` is defined exactly once (the SSA
  property itself).
- Operand/result type agreement (`IAdd.lhs.type == IAdd.rhs.type ==
  IAdd.dest.type`; `Retain.object.type` is a `DCHeapPointer`;
  `CondBranch.cond.type` is `DCBool`; branch argument lists match target
  block parameter lists in length and type) — these are documented on each
  instruction as a contract, not checked in the constructor. A well-formed
  `DCFunction` is one property up from what a type checker alone can prove;
  it needs a real verifier once one exists to run.

This is a normal division of labor for an IR (LLVM's C++ classes don't
self-verify either — that's what `llvm::verifyFunction` is for) and is
called out explicitly here so nobody mistakes "the types compile" for "the
IR is well-formed."
