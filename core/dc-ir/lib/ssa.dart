// core/dc-ir/ssa.dart
//
// The identity/reference model for DC-IR: how one part of the IR refers to
// another. Nodes refer to each other by id (ValueId, BlockId) resolved
// through arena-style Lists owned by exactly one DCFunction (function.dart),
// not by direct object pointers. Two consequences, both deliberate:
//
// 1. The IR graph itself never needs `weak`/`unowned` back-pointers (spec
//    §3.3, CLAUDE.md "cycles" rule) to stay acyclic in the ARC sense,
//    because there are no strong pointers between IR nodes to begin with.
//    A `Branch` "pointing back" to an earlier block (a loop) is a `u32` in
//    a `BlockId`, not a reference — nothing to retain, nothing that can
//    cycle. `DCBasicBlock` and `DCInstruction` hold no pointer back to the
//    `DCFunction` that owns them at all.
// 2. It sidesteps a bootstrapping question this project has not answered
//    yet: what host language `dcc-lower`/`dc-ir`/`backend` are themselves
//    implemented in before DCDart self-hosts (see README.md "Open
//    question"). Id/arena references translate to a plain integer index
//    into an array in essentially any host language; a direct object graph
//    with parent/sibling pointers would force a decision about that
//    language's own reference/lifetime model now, for a reason unrelated to
//    what that decision should actually turn on. See
//    docs/decisions/0003-dc-ir-id-based-references.md.

import 'types.dart';

/// Identifies a value within one `DCFunction` — either an instruction's
/// `dest` or a basic block's parameter. Not meaningful across functions;
/// there is no cross-function `ValueId`, on purpose (spec §9's C ABI is how
/// functions refer to each other, not a shared value namespace).
final class ValueId {
  // Plain `int`, not `u32`: see ADR-0006 — this whole package is Stage-0
  // tooling (plain hosted Dart), same as `dcc`. Conceptually a u32 index;
  // callers must not hand it a negative value or one that would not fit in
  // 32 bits — there is no host-level check for that here, same as every
  // other DC-IR invariant this module documents but does not enforce (see
  // README "What isn't validated by construction").
  final int index;
  const ValueId(this.index);

  @override
  bool operator ==(Object other) => other is ValueId && other.index == index;

  @override
  int get hashCode => index.hashCode;
}

/// Identifies a basic block within one `DCFunction`. Block `0` is always
/// the entry block, and by convention (function.dart `DCFunction`) the
/// function's formal parameters ARE `blocks[0].params` — see the note
/// there for why.
final class BlockId {
  // Plain `int` — see the same note on `ValueId.index` above.
  final int index;
  const BlockId(this.index);

  @override
  bool operator ==(Object other) => other is BlockId && other.index == index;

  @override
  int get hashCode => index.hashCode;
}

/// An SSA value: an id plus the `DCType` it carries. Each `DCValue` is
/// defined exactly once — as one instruction's `dest`, or as one entry in
/// one basic block's `params` — per the SSA invariant. `DCValue` itself
/// does not enforce that (see README "What isn't validated by
/// construction"); it is a plain pair, deliberately too dumb to lie about
/// what it represents.
///
/// Equality/hashing are by `id` only, not by `(id, type)`: within one
/// function a given `ValueId` has exactly one type for its entire lifetime
/// (SSA), so two `DCValue`s naming the same id can never legitimately carry
/// different types. If dcc-lower ever constructs two `DCValue`s with the
/// same id and different types, that is a dcc-lower bug to catch in a
/// verifier pass, not a case for `DCValue.==` to paper over.
final class DCValue {
  final ValueId id;
  final DCType type;
  const DCValue(this.id, this.type);

  @override
  bool operator ==(Object other) => other is DCValue && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
