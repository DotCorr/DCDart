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
//   2. A `Call` instruction invalidates every pending retain. A call is
//      opaque to this pass -- the callee could retain, release, or store
//      the same object anywhere, and nothing here does interprocedural
//      analysis to rule that out (see docs/decisions/0025's worked
//      example of exactly this: m2-owned's makeAndDropViaCall has a
//      retain/call/release sequence that looks superficially cancelable
//      and is NOT -- the callee's own release is load-bearing).
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
//      safe to skip over without invalidating anything: Alloc always
//      allocates a fresh, previously-unused header (can't alias a
//      pending retain's object); PtrOffset/Load/Store only ever touch a
//      PAYLOAD offset (non-negative, ADR-0016), never the header, which
//      sits at a fixed NEGATIVE offset -- so no plain memory op can
//      corrupt a refcount.

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
  final kept = <DCInstruction?>[]; // null marks a removed slot

  for (final instruction in block.body) {
    switch (instruction) {
      case Retain():
        // A second Retain on the same value before it's matched simply
        // overwrites the pending index -- the earlier Retain is left in
        // `kept` as a real, unmatched instruction (correct: with two
        // retains and (as verified below) two releases outstanding,
        // cancelling exactly one pair and leaving the other net-zero
        // change is exactly as correct as cancelling any other pairing).
        pendingRetain[instruction.object.id.index] = kept.length;
        kept.add(instruction);
      case Release():
        final pendingIndex = pendingRetain.remove(instruction.object.id.index);
        if (pendingIndex != null) {
          kept[pendingIndex] = null; // drop the matched Retain
          kept.add(null); // drop this Release too
        } else {
          kept.add(instruction);
        }
      case Call():
      case MakeWeak():
      case WeakLoad():
      case DropWeak():
        // Opaque w.r.t. this pass's per-ValueId tracking -- see the file
        // header for why each of these specifically can't be skipped
        // over safely.
        pendingRetain.clear();
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
