// core/dc-elide/lib/elide.dart
//
// Spec §3.2 pass 3: redundant-pair removal. "retain(x); ...; release(x)
// with no release of x in between -> delete both." The first elision
// pass this project implements (docs/decisions/0025-redundant-pair-
// removal.md) -- ROADMAP.md's M2 exit criterion literally names
// "dc-objdump --arc shows elision firing on the reference benchmark" as
// part of M2, not M3 (M3 is specifically the LATER ≤10%-overhead
// measurement gate) -- see docs/known-gaps.md GAP-0017 item 2's
// correction. `dc-objdump --arc` (ADR-0024) is what makes "firing"
// concretely checkable: the same source should show smaller retain/
// release counts after this pass runs than before.
//
// A SEPARATE package from dcc-lower (not lib/elide.dart there), purely
// for dependency hygiene: this file only needs `dc_ir` (zero transitive
// dependencies), which is what lets its own test suite depend on
// `package:test` at all -- `dcc_lower`'s pubspec also depends on the
// vendored `kernel` package (path dependency, pinning `_fe_analyzer_shared`
// to a local path version), which pub cannot reconcile with `package:test`'s
// own (hosted) `_fe_analyzer_shared` requirement in the SAME pubspec. Kept
// here, imported BY dcc-lower, rather than accepting no test coverage for
// something this safety-sensitive (CLAUDE.md: "Regressions in elision are
// invisible at runtime and catastrophic in aggregate").
//
// SAFETY, read before touching this file: every simplification below is
// deliberately conservative, chosen because it is PROVABLY safe at the
// DC-IR level, not because it is maximally aggressive. Getting this wrong
// means a double-free or a premature free that no conformance test's
// normal "does it crash" check would reliably catch (the arena is tiny --
// 64 slots -- so it tends to surface eventually, but "tends to" is not a
// proof).
//
// Scope, deliberately conservative:
//   1. Single basic block only. No cross-block tracking -- a block
//      boundary means the value might flow into a path this pass can't
//      see all of (DC-IR block params, ADR-0012), so a retain that
//      hasn't been matched by the time a block ends is left alone.
//   2. A `Call` instruction invalidates every pending retain, EXCEPT one
//      matching an argument the call fully consumes (`Call.argOwnership`,
//      docs/decisions/0031-move-semantics.md, spec §3.2 pass 4) -- see
//      that ADR for why this specific case is provably safe and every
//      other `Call` argument still isn't (the callee could retain,
//      release, or store a BORROWED reference anywhere; nothing here does
//      interprocedural analysis to rule that out -- ADR-0025's own worked
//      example of exactly this ambiguity, m2-owned's makeAndDropViaCall,
//      is what motivated adding the ownership tag rather than assuming).
//      A pending retain that survives this way is tracked more strictly
//      than an ordinary one, below.
//   3. `MakeWeak`/`WeakLoad`/`DropWeak` ALSO invalidate every pending
//      retain, even though they operate on a DIFFERENT DCValue (a
//      DCWeakPointer, not the DCHeapPointer a pending retain tracks).
//      Why: a weak pointer's numeric address is identical to the strong
//      pointer it was made from (ADR-0023) -- this pass has no way to
//      prove, at the DC-IR level, that some OTHER value's WeakLoad isn't
//      quietly retaining the SAME object my pending retain is tracking
//      (WeakLoad's own codegen increments `strong` when the target is
//      alive). Treating these as opaque, exactly like Call, is the safe
//      choice.
//   4. Everything else (arithmetic, Load/Store/PtrOffset/IntToPtr,
//      ConstInt, Alloc/Retain/Release on OTHER values, terminators) is
//      safe to skip over without invalidating an ORDINARY pending
//      retain: Alloc always allocates a fresh, previously-unused header
//      (can't alias a pending retain's object); PtrOffset/Load/Store
//      only ever touch a PAYLOAD offset (non-negative, ADR-0016), never
//      the header, which sits at a fixed NEGATIVE offset -- so no plain
//      memory op can corrupt a refcount. This does NOT extend to a
//      call-consumed candidate from rule 2 -- see its own note below for
//      why that one needs a strictly stronger rule.

import 'package:dc_ir/dc_ir.dart';

/// Applies redundant-pair removal to every block of [function], returning
/// a new `DCFunction` with the same signature and (functionally) the same
/// behavior, minus any provably-redundant `Retain`/`Release` pairs.
DCFunction elideRedundantRetainReleasePairs(DCFunction function) {
  return DCFunction(
    linkName: function.linkName,
    paramTypes: function.paramTypes,
    returnType: function.returnType,
    mode: function.mode,
    blocks: function.blocks.map(_elideBlock).toList(),
  );
}

DCBasicBlock _elideBlock(DCBasicBlock block) {
  // pendingRetain[valueId] = index into `kept` of an as-yet-unmatched
  // Retain on that value (or absent if none is currently pending).
  final pendingRetain = <int, int>{};

  // Subset of pendingRetain.keys that survived a Call specifically
  // because they matched one of ITS `argOwnership`-true arguments
  // (docs/decisions/0031-move-semantics.md). Unlike an ordinary pending
  // retain (rule 4 above), a call-consumed candidate is invalidated by
  // ANY subsequent reference to it, not just an opaque op -- because
  // once its pair is cancelled, the object's LAST reference is what gets
  // handed directly to the callee. An ordinary pair's object stays alive
  // via some OTHER reference throughout (safe to skip over ordinary
  // uses); this one's does not, so a later read (e.g. `return b.value;`
  // after passing `b` to an @owned param) would become a genuine
  // use-after-free if not caught here.
  final callConsumed = <int>{};

  final kept = <DCInstruction?>[]; // null marks a removed slot

  for (final instruction in block.body) {
    if (callConsumed.isNotEmpty) {
      final isOwnMatchingRelease = instruction is Release && callConsumed.contains(instruction.object.id.index);
      if (!isOwnMatchingRelease) {
        for (final id in referencedValueIds(instruction)) {
          if (callConsumed.remove(id)) {
            // Fully invalidate, not just downgrade to "ordinary" -- the
            // whole reason this candidate was tracked at all was the
            // owned-consuming Call it survived; once it's known unsafe to
            // cancel that specific pair, there's no more specific
            // reasoning left to fall back on. Worst case this misses an
            // optimization; it never miscompiles.
            pendingRetain.remove(id);
          }
        }
      }
    }

    switch (instruction) {
      case Retain():
        // A second Retain on the same value before it's matched simply
        // overwrites the pending index -- the earlier Retain is left in
        // `kept` as a real, unmatched instruction (correct: with two
        // retains and (as verified below) two releases outstanding,
        // cancelling exactly one pair and leaving the other net-zero
        // change is exactly as correct as cancelling any other pairing).
        pendingRetain[instruction.object.id.index] = kept.length;
        callConsumed.remove(instruction.object.id.index); // fresh, not yet call-consumed
        kept.add(instruction);
      case Release():
        final id = instruction.object.id.index;
        final pendingIndex = pendingRetain.remove(id);
        callConsumed.remove(id);
        if (pendingIndex != null) {
          kept[pendingIndex] = null; // drop the matched Retain
          kept.add(null); // drop this Release too
        } else {
          kept.add(instruction);
        }
      case Call():
        final ownedIds = <int>{
          for (var i = 0; i < instruction.args.length; i++)
            if (instruction.argOwnership[i]) instruction.args[i].id.index,
        };
        pendingRetain.removeWhere((id, _) {
          if (ownedIds.contains(id)) {
            callConsumed.add(id); // survives THIS call, now under the strict rule above
            return false;
          }
          return true; // ordinary conservative invalidation, unchanged from before
        });
        kept.add(instruction);
      case MakeWeak():
      case WeakLoad():
      case DropWeak():
        // Opaque w.r.t. this pass's per-ValueId tracking -- see the file
        // header for why each of these specifically can't be skipped
        // over safely. No argOwnership-style exception exists for these
        // (spec's weak-count elision is a separate, unstarted question).
        pendingRetain.clear();
        callConsumed.clear();
        kept.add(instruction);
      default:
        kept.add(instruction);
    }
  }

  return DCBasicBlock(
    id: block.id,
    params: block.params,
    body: kept.whereType<DCInstruction>().toList(),
  );
}

/// Every `ValueId.index` [instruction] reads as an operand -- everything
/// EXCEPT its own `result`/`dest` (a freshly-defined value can't already
/// be "in use" by the instruction that creates it). Exhaustive over every
/// `DCInstruction` subtype on purpose: the sealed hierarchy in
/// `core/dc-ir/lib/instructions.dart` means the analyzer refuses to
/// compile this if a new instruction is ever added without updating it
/// here too, which is exactly the safety net a generic "does X reference
/// value V" helper needs for something this correctness-sensitive
/// (docs/decisions/0031-move-semantics.md's own "critical correctness
/// subtlety" section is what this helper exists to make provable, not
/// just assumed).
Set<int> referencedValueIds(DCInstruction instruction) {
  final ids = <int>{};
  void ref(DCValue v) => ids.add(v.id.index);

  switch (instruction) {
    case ConstInt():
      break; // no operands, only a dest
    case IAdd(:final lhs, :final rhs):
    case ISub(:final lhs, :final rhs):
    case IMul(:final lhs, :final rhs):
    case IDiv(:final lhs, :final rhs):
    case IRem(:final lhs, :final rhs):
    case IAnd(:final lhs, :final rhs):
    case IOr(:final lhs, :final rhs):
    case IXor(:final lhs, :final rhs):
    case IShl(:final lhs, :final rhs):
    case IShr(:final lhs, :final rhs):
    case ICmp(:final lhs, :final rhs):
      ref(lhs);
      ref(rhs);
    case MakeStruct(:final fields):
      fields.forEach(ref);
    case IConvert(:final source):
      ref(source);
    case ExtractField(:final struct):
      ref(struct);
    case Load(:final pointer):
      ref(pointer);
    case Store(:final pointer, :final value):
      ref(pointer);
      ref(value);
    case IntToPtr(:final address):
      ref(address);
    case PtrToInt(:final pointer):
      ref(pointer);
    case PtrOffset(:final base):
      ref(base);
    case PortOut(:final port, :final value):
      ref(port);
      ref(value);
    case PortIn(:final port):
      ref(port);
    case AtomicLoad(:final pointer):
      ref(pointer);
    case AtomicStore(:final pointer, :final value):
      ref(pointer);
      ref(value);
    case AtomicRmw(:final pointer, :final value):
      ref(pointer);
      ref(value);
    case Fence():
      break; // orders other instructions; has no operands of its own
    case NullRef():
      break; // a constant; no operands
    case AddressOfGlobal():
      break; // names a symbol, not a value; no operands
    case Alloc():
      break; // always a fresh header; no operands
    case AllocRaw(:final sizeBytes):
      // The SIZE is a real operand, unlike Alloc's compile-time constant.
      // Missing it here would let the elision pass treat the value computing
      // the size as dead between its definition and this use (ADR-0058).
      ref(sizeBytes);
    case FreeRaw(:final pointer):
      ref(pointer);
    case Call(:final args):
      args.forEach(ref);
    case Retain(:final object):
    case Release(:final object):
    case DropWeak(:final object):
      ref(object);
    case MakeWeak(:final object):
      ref(object);
    case WeakLoad(:final weak):
      ref(weak);
    case Return(:final value):
      if (value != null) ref(value);
    case Branch(:final args):
      args.forEach(ref);
    case CondBranch(:final cond, :final trueArgs, :final falseArgs):
      ref(cond);
      trueArgs.forEach(ref);
      falseArgs.forEach(ref);
  }

  return ids;
}
