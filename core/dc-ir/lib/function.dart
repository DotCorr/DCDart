// core/dc-ir/function.dart
//
// The container structure: basic blocks, functions, and modules. This is
// the shape `dcc-lower` builds and `backend/` consumes.

import 'instructions.dart';
import 'ssa.dart';
import 'types.dart';

/// One basic block: an id, its SSA parameters, and a straight-line body
/// ending in exactly one terminator.
///
/// `params` are the values other blocks' `Branch`/`CondBranch` (see
/// instructions.dart) bind their `args` into when jumping here — this is
/// DC-IR's only merge-point mechanism (no phi instruction; see
/// README.md "Why block-parameter SSA, not phi nodes").
///
/// INVARIANT (not enforced by this type — see README "What isn't validated
/// by construction"): every element of `body` except the last must NOT be
/// a `DCTerminator`, and the last MUST be one. A verifier pass over
/// `DCFunction` — not yet written, belongs with whoever writes the first
/// real `dcc-lower` — is where this gets checked mechanically.
final class DCBasicBlock {
  final BlockId id;
  final List<DCValue> params;
  final List<DCInstruction> body;
  const DCBasicBlock({
    required this.id,
    required this.params,
    required this.body,
  });
}

/// Compilation mode, spec §2. Threaded onto `DCFunction` (not left implicit
/// from "whichever file it came from") because the backend's lowering
/// genuinely diverges on it — no ORC calls, no allocator-implicit paths, no
/// exceptions-shim — and because `scripts/verify-freestanding.sh`
/// (CLAUDE.md rule 1) only makes sense to run against something that
/// claims to be `bare`.
enum DCMode { bare, hosted }

/// One function: a fixed signature, a mode, and its basic blocks.
///
/// `blocks[0]` is always the entry block, and the function's formal
/// parameters ARE `blocks[0].params` — there is no separate parameter
/// list distinct from block parameters. This is one mechanism doing both
/// jobs on purpose: a function's parameters are exactly "the SSA values
/// live at entry", which is precisely what a block's `params` represents
/// for every other block already. `paramTypes` is kept alongside as the
/// function's externally-visible signature (what `backend/` needs to
/// generate a C-ABI-compatible symbol per spec §9, before it has looked at
/// any block) — it must equal `blocks[0].params.map((v) => v.type)`
/// exactly; this redundancy is deliberate; see README "What isn't
/// validated by construction".
///
/// WORKED EXAMPLE. `core/examples/m0-seam/add.dart`'s
/// `@bare u64 add(u64 a, u64 b) => a + b;` lowers to:
///
/// ```dart
/// DCFunction(
///   linkName: 'add',
///   paramTypes: [DCInt.u64, DCInt.u64],
///   returnType: DCInt.u64,
///   mode: DCMode.bare,
///   blocks: [
///     DCBasicBlock(
///       id: BlockId(0),
///       params: [
///         DCValue(ValueId(0), DCInt.u64), // a
///         DCValue(ValueId(1), DCInt.u64), // b
///       ],
///       body: [
///         IAdd(
///           dest: DCValue(ValueId(2), DCInt.u64),
///           lhs: DCValue(ValueId(0), DCInt.u64),
///           rhs: DCValue(ValueId(1), DCInt.u64),
///           overflow: Overflow.trapping, // plain `+` traps, spec §4.1
///         ),
///         Return(value: DCValue(ValueId(2), DCInt.u64)),
///       ],
///     ),
///   ],
/// )
/// ```
///
/// Zero `Retain`/`Release` anywhere in this function — `u64` is a value
/// type (spec §3.1's `DCObject` header is a heap-object concept; nothing
/// here is heap-allocated), so ARC insertion in dcc-lower has nothing to
/// do for `add`. That is the expected M0 output, not a gap: the ARC node
/// shapes (instructions.dart `Retain`/`Release`) exist so M2's inserter has
/// something correct to target later, not because M0 needs to emit them.
final class DCFunction {
  final String linkName; // e.g. "add" from @linkName, or the mangled name
  final List<DCType> paramTypes;
  final DCType returnType;
  final DCMode mode;
  final List<DCBasicBlock> blocks;

  const DCFunction({
    required this.linkName,
    required this.paramTypes,
    required this.returnType,
    required this.mode,
    required this.blocks,
  });
}

/// A compilation unit — what `dcc-lower` hands to `backend/` as one job,
/// and roughly what becomes one object file. M0 only ever has one function
/// in one module (`add`); `DCModule` exists as a thin wrapper now so that
/// "one function per module" isn't accidentally load-bearing anywhere
/// downstream.
final class DCModule {
  final String name;
  final List<DCFunction> functions;
  const DCModule({required this.name, required this.functions});
}
