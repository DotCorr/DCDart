# ADR-0002: DC-IR uses id/arena references and block-parameter SSA, not object pointers or phi nodes

**Status:** decided (scoped to `dc-ir/`'s own type definitions; does not bind `backend/`'s LLVM output, which needs LLVM's own phi form)

## Context

`core/dc-ir/` needed a concrete representation for two related design
questions while defining the DC-IR type vocabulary (spec §1: "DC-IR — typed
SSA, explicit retain/release"):

1. How do IR nodes refer to each other — basic blocks to other basic blocks,
   instructions to the values they consume?
2. How does DC-IR represent SSA merge points (the join after an `if`, the
   back-edge of a loop)?

Both needed an answer before `DCBasicBlock`/`DCFunction` (`function.dart`)
could be written down, and both are exactly the kind of shape CLAUDE.md rule
4 wants settled before M2 (ARC insertion) and M3 (the elision benchmark
suite) get written against it.

## Options

**For references (Q1):**
1. Direct object pointers between IR nodes (an instruction holds a Dart
   reference to the `DCBasicBlock` it targets; a `DCValue` holds a reference
   to the instruction that defines it) — the traditional LLVM `Value*`/`User*`
   style.
2. Id-based references resolved through arena `List`s owned by the
   `DCFunction` (a `BlockId`/`ValueId` — a `u32` index) — the Cranelift/MLIR/
   `rustc` MIR style.

**For merge points (Q2):**
1. Phi instructions living in block bodies (LLVM IR's own form).
2. Basic-block parameters bound positionally by branch arguments (MLIR,
   Cranelift, Swift SIL).

## Decision

Option 2 for both: id/arena references, and block-parameter SSA.

**Why id-based references.** A direct object-pointer graph between
`DCBasicBlock`/`DCInstruction`/`DCValue` immediately raises the question
CLAUDE.md's "cycles" rule exists for: which of those pointers are strong and
which are `weak`/`unowned`? A loop's back-branch is exactly a "back
pointer" in the cyclic sense the rule targets. Answering that honestly means
either designing ARC-style ownership for the compiler's own IR data
structures — a real design task, and a distraction from what this unit was
asked to do — or picking `weak` by convention and hoping nobody gets it
wrong. An id into an arena sidesteps the question entirely: a `BlockId` is a
`u32`, not a reference, so there is nothing to retain and nothing that can
cycle. It also stays neutral on the open question of what host language
`dcc-lower`/`backend` are themselves implemented in (see `dc-ir/README.md`
"Open question") — an integer index means the same thing in any host
language; a pointer-based object graph would import that host language's own
reference/lifetime rules into DC-IR's definition for no reason connected to
what DC-IR needs to express.

**Why block-parameter SSA.** Phi nodes and function parameters are two
different mechanisms answering the same question ("what values are live
coming into this point, and where from"). Block parameters answer it once:
a function's formal parameters are exactly `blocks[0].params`, and every
other merge point uses the identical mechanism. This matters concretely for
M2: ARC insertion needs to know, at every block boundary, exactly which
values are live and what their ownership state is. A block's `params` list
is a direct, already-complete answer. Reconstructing it from phi placement —
which phis exist, which predecessor each incoming value came from, which
apparently-different phis are really the same logical value merged twice —
is strictly more derivation for every pass that needs the answer, and DC-IR
has no offsetting benefit from phi form at this level (LLVM's phi
requirement is a target-format concern that belongs in `backend/`'s
lowering, not in DC-IR itself).

## Consequences

- `backend/` (DC-IR → LLVM IR) must re-lower block parameters back into
  LLVM's phi form when it walks a `DCFunction`. This is a known, bounded,
  mechanical translation (the same one MLIR's LLVM dialect lowering and
  Cranelift's LLVM backend, where it exists, already do) — not a new design
  problem, just a cost being paid once in the right place instead of
  avoided.
- Any verifier written against `DCFunction` (see `dc-ir/README.md` "What
  isn't validated by construction") must check `ValueId`/`BlockId`
  references resolve within bounds of the owning `DCFunction`'s lists — the
  Dart type system does not do this for free the way it would catch a
  dangling object reference at compile time. This is the tradeoff being
  made explicitly: static safety on the id lookup is traded for freedom from
  the ownership-cycle question above.
- If `dcc-lower`/`backend` end up genuinely needing pointer-identity
  semantics for some later pass (e.g. a mutable in-place rewrite pass that
  wants to hold onto "this specific instruction" across a rebuild), that
  pass can still use `ValueId`/`BlockId` as a stable key into whatever
  structure it needs — the id scheme does not preclude it, it just doesn't
  hand it out by default.
