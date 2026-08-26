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
//   4. A SURVIVING `Release` -- of ANY value, not just a matching one --
//      invalidates every pending retain (ADR-0063, closing GAP-0054).
//      A `Release` that this pass DELETES as half of a cancelled pair
//      does not, because it never executes. This is the rule that makes
//      pass 3 safe on its own terms rather than by accident; the long
//      note at the `Release` case below states the invariant and proves
//      it, and says what used to stand in for it.
//   5. Everything else (arithmetic, Load/Store/PtrOffset/IntToPtr,
//      ConstInt, Alloc and Retain on OTHER values, terminators) is
//      safe to skip over without invalidating an ORDINARY pending
//      retain: Alloc always allocates a fresh, previously-unused header
//      (can't alias a pending retain's object); PtrOffset/Load/Store
//      only ever touch a PAYLOAD offset (non-negative, ADR-0016), never
//      the header, which sits at a fixed NEGATIVE offset -- so no plain
//      memory op can corrupt a refcount. This does NOT extend to a
//      call-consumed candidate from rule 2 -- see its own note below for
//      why that one needs a strictly stronger rule.
//
//      NOTE what rules 2-4 have in common, because it is the whole
//      safety story: the ONLY three ways a refcount can go DOWN are an
//      executed `Release`, an opaque callee, and a weak op. Each is
//      handled by clearing. Nothing else in DC-IR can decrement a
//      refcount, so nothing else can end an object's life early.

import 'package:dc_ir/dc_ir.dart';

/// Applies redundant-pair removal to every block of [function], returning
/// a new `DCFunction` with the same signature and (functionally) the same
/// behavior, minus any provably-redundant `Retain`/`Release` pairs.
/// Why a pending `Retain` failed to pair, counted per function.
///
/// EXISTS BECAUSE "elision removes 5% here" does not say WHAT TO FIX. Two
/// unrelated constraints stop a pair, they need different fixes, and the
/// ratio between them was unknown until this was measured:
///
///   * [blockLimited] -- the retain reached the end of its block unmatched.
///     Fixed by cross-block tracking (the null-test extension), because
///     every nullable field read ends its block at the null test.
///   * [opaqueLimited] -- a `Call`, `IndirectCall` or weak op invalidated it.
///     NOT fixed by cross-block tracking at all: it needs interprocedural
///     analysis, or an ownership convention that says what a callee may do
///     with a borrowed reference.
///
/// A worked example of why the distinction matters: `json`'s `walk` reads a
/// nullable child, null-tests it, and CALLS `walk` on it. That looks like the
/// canonical null-test shape and is actually opaque-limited -- so the
/// null-test extension would not move it, and a plan built on the shape alone
/// would have aimed at the wrong constraint.
class ElisionStats {
  int elided = 0;
  int crossBlockElided = 0;
  int blockLimited = 0;
  int opaqueLimited = 0;
  int releaseLimited = 0;

  @override
  String toString() =>
      'elided=$elided crossBlock=$crossBlockElided blockLimited=$blockLimited '
      'opaqueLimited=$opaqueLimited releaseLimited=$releaseLimited';
}

DCFunction elideRedundantRetainReleasePairs(
  DCFunction function, [
  ElisionStats? stats,
]) {
  final perBlock = DCFunction(
    linkName: function.linkName,
    paramTypes: function.paramTypes,
    returnType: function.returnType,
    mode: function.mode,
    blocks: function.blocks.map((b) => _elideBlock(b, stats)).toList(),
  );
  return _elideCrossBlock(perBlock, stats);
}

/// Does [instruction] make it unsafe to carry a pending retain past it?
///
/// Exactly the file header's rules 2-4, in one place so the cross-block pass
/// and the per-block pass cannot drift apart on what "opaque" means. The ONLY
/// three ways a refcount can go down are an executed `Release`, an opaque
/// callee, and a weak op.
bool _isOpaqueForPendingRetain(DCInstruction instruction) =>
    instruction is Call ||
    instruction is IndirectCall ||
    instruction is MakeWeak ||
    instruction is WeakLoad ||
    instruction is DropWeak ||
    instruction is Release;

/// Cross-block redundant-pair removal, restricted to a shape that can be
/// checked without a full dataflow framework (GAP-0062).
///
/// THE PROBLEM IT EXISTS FOR. The per-block pass above drops every pending
/// retain at a block boundary, and **every nullable heap field read ends its
/// block at the null test** -- so on linked structures (a tree, a sibling
/// chain, a parser's node graph) it sees a program chopped into pieces
/// smaller than the pairs it is matching. Measured before this pass:
/// `json` 19 retains lowered, 19 survive.
///
/// THE SAFETY ARGUMENT, which is the whole of this function. A `Retain` in
/// block A and a `Release` in block Z may be cancelled only if BOTH execute
/// exactly once per call and nothing between them can decrement the count.
/// That is established here by four conditions, each cheap to check and each
/// refusing rather than approximating:
///
///   1. NO BACK EDGES. Every branch target has a strictly greater index than
///      its source, so no instruction executes twice. Without this a retain
///      inside a loop pairs with one release outside it -- N retains, one
///      release -- and cancelling them would under-release.
///   2. EXACTLY ONE `Return` BLOCK, called Z. All paths therefore end at Z,
///      so a `Release` in Z executes on every path.
///   3. A DOMINATES Z. The retain's block is on every path to Z, so the
///      retain also executes on every path. Condition 2 alone is NOT enough:
///      a retain in a conditional arm with a release in the merge block would
///      execute zero-or-one times against a release that always executes, and
///      cancelling that pair deletes a release the other path needed.
///   4. NOTHING OPAQUE IN BETWEEN, over a deliberate SUPERSET of the blocks
///      on any A->Z path: every block whose index lies between them, plus the
///      tail of A after the retain and the head of Z before the release. A
///      superset can only refuse a safe elision, never permit an unsafe one.
///
/// A function failing any of 1-3 is left entirely to the per-block pass.
DCFunction _elideCrossBlock(DCFunction function, ElisionStats? stats) {
  final blocks = function.blocks;
  if (blocks.length < 2) return function;

  final indexOfBlock = <int, int>{};
  for (var i = 0; i < blocks.length; i++) {
    indexOfBlock[blocks[i].id.index] = i;
  }

  // Condition 1: no back edges, and every target must exist.
  final successors = List<List<int>>.generate(blocks.length, (_) => <int>[]);
  for (var i = 0; i < blocks.length; i++) {
    final body = blocks[i].body;
    if (body.isEmpty) continue;
    final term = body.last;
    final targets = <int>[];
    if (term is Branch) {
      targets.add(term.target.index);
    } else if (term is CondBranch) {
      targets..add(term.trueTarget.index)..add(term.falseTarget.index);
    }
    for (final t in targets) {
      final ti = indexOfBlock[t];
      if (ti == null || ti <= i) return function; // back edge or unknown
      successors[i].add(ti);
    }
  }

  // Condition 2: exactly one block containing a Return.
  var exitIndex = -1;
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].body.any((x) => x is Return)) {
      if (exitIndex != -1) return function; // more than one exit
      exitIndex = i;
    }
  }
  if (exitIndex < 0) return function;

  // Condition 3: dominators, over a DAG already in topological order, so one
  // forward sweep suffices -- no fixpoint iteration needed.
  final preds = List<List<int>>.generate(blocks.length, (_) => <int>[]);
  for (var i = 0; i < blocks.length; i++) {
    for (final sIdx in successors[i]) {
      preds[sIdx].add(i);
    }
  }
  final dom = List<Set<int>>.generate(blocks.length, (_) => <int>{});
  dom[0] = {0};
  for (var i = 1; i < blocks.length; i++) {
    if (preds[i].isEmpty) {
      dom[i] = {i}; // unreachable; dominates only itself
      continue;
    }
    Set<int>? acc;
    for (final p in preds[i]) {
      acc = acc == null ? Set<int>.from(dom[p]) : acc.intersection(dom[p]);
    }
    dom[i] = (acc ?? <int>{})..add(i);
  }
  final domOfExit = dom[exitIndex];

  // Collect candidate pairs: a Retain in a block dominating the exit, and a
  // Release of the same value in the exit block.
  final removeFrom = <int, Set<int>>{}; // block index -> instruction indices
  final exitBody = blocks[exitIndex].body;

  for (var a = 0; a < blocks.length; a++) {
    if (a == exitIndex) continue; // same-block case is the per-block pass's
    if (!domOfExit.contains(a)) continue;
    final aBody = blocks[a].body;
    for (var ai = 0; ai < aBody.length; ai++) {
      final r = aBody[ai];
      if (r is! Retain) continue;
      final vid = r.object.id.index;

      // The matching Release in the exit block: the FIRST one on this value.
      var zi = -1;
      for (var k = 0; k < exitBody.length; k++) {
        final x = exitBody[k];
        if (x is Release && x.object.id.index == vid) {
          zi = k;
          break;
        }
      }
      if (zi < 0) continue;

      // Condition 4, over the superset.
      var safe = true;
      for (var k = ai + 1; k < aBody.length && safe; k++) {
        if (_isOpaqueForPendingRetain(aBody[k])) safe = false;
      }
      for (var b = a + 1; b < exitIndex && safe; b++) {
        for (final x in blocks[b].body) {
          if (_isOpaqueForPendingRetain(x)) {
            safe = false;
            break;
          }
        }
      }
      for (var k = 0; k < zi && safe; k++) {
        if (_isOpaqueForPendingRetain(exitBody[k])) safe = false;
      }
      // A second Retain on the same value anywhere between would make the
      // pairing ambiguous; refuse rather than guess which release matches.
      if (safe) {
        for (var b = a; b <= exitIndex && safe; b++) {
          final body = blocks[b].body;
          for (var k = 0; k < body.length; k++) {
            if (b == a && k <= ai) continue;
            final x = body[k];
            if (x is Retain && x.object.id.index == vid) safe = false;
          }
        }
      }
      if (!safe) continue;

      // Do not double-claim a Release already matched by an earlier retain.
      final exitClaimed = removeFrom[exitIndex] ?? <int>{};
      if (exitClaimed.contains(zi)) continue;

      (removeFrom[a] ??= <int>{}).add(ai);
      (removeFrom[exitIndex] ??= <int>{}).add(zi);
      stats?.crossBlockElided += 1;
      break; // one pair per retain
    }
  }

  if (removeFrom.isEmpty) return function;

  return DCFunction(
    linkName: function.linkName,
    paramTypes: function.paramTypes,
    returnType: function.returnType,
    mode: function.mode,
    blocks: List<DCBasicBlock>.generate(blocks.length, (i) {
      final drop = removeFrom[i];
      if (drop == null) return blocks[i];
      final body = <DCInstruction>[];
      for (var k = 0; k < blocks[i].body.length; k++) {
        if (drop.contains(k)) continue;
        body.add(blocks[i].body[k]);
      }
      return DCBasicBlock(id: blocks[i].id, params: blocks[i].params, body: body);
    }),
  );
}

DCBasicBlock _elideBlock(DCBasicBlock block, [ElisionStats? stats]) {
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
          stats?.elided += 1;
          kept[pendingIndex] = null; // drop the matched Retain
          kept.add(null); // drop this Release too
          // Deliberately NO invalidation of the OTHER pending retains here:
          // this Release does not survive, so it never executes and cannot
          // decrement anything. Only a SURVIVING Release is a real
          // decrement, which is what the branch below is about.
        } else {
          // ------------------------------------------------------------
          // (ADR-0063, closing GAP-0054) THIS RELEASE SURVIVES, so it runs,
          // so it decrements SOME object's refcount by one.
          //
          // It names a DCValue. A DCValue is not an object. Two distinct
          // DCValues routinely denote the SAME runtime object -- that is
          // the entire premise of ADR-0017's alias retain, where
          // `%b = Load %a.field` produces a second value for the object
          // `%a.field` already holds. So "this is not a Release of `%x`"
          // is NOT the statement "this cannot free `%x`'s object", and
          // pass 3's safety argument needs the second one.
          //
          // Every pending retain therefore has to go, exactly as for an
          // opaque `Call` (rule 2) or a weak op (rule 3).
          //
          // WHY THIS IS THE WHOLE FIX, stated as the invariant it
          // restores. Cancelling a pair is sound iff the object stays
          // alive across the interval the retain used to cover. Cut the
          // block at every surviving Release, and inside one such gap the
          // transformed program has NO decrement of anything at all --
          // deleted releases do not execute, and every remaining
          // decrement is a gap boundary by construction. Both members of
          // an elided pair now lie inside a single gap (a pair spanning a
          // boundary is invalidated here), so the refcounts of the
          // original and transformed programs agree AT every boundary,
          // and within a gap the transformed count only ever rises from a
          // boundary value that the original program already guaranteed
          // to be >= 1. So it can never reach zero inside the interval.
          //
          // Note what that argument does NOT mention: where dcc-lower
          // chooses to put `_releaseHeapLocals`, or whether the last use
          // of a value happens to precede the releases. GAP-0054 recorded
          // that the ONLY thing standing between pass 3 and a
          // use-after-free was that ordering -- a property of a different
          // file, asserted nowhere. This invariant is local to the pass
          // and holds whatever order lowering emits.
          // NOT NARROWED BY AN ALIAS ANALYSIS. This is blunt, it is not
          // free, and the measurement is in ADR-0063 rather than hidden:
          // across every example, the conformance suite and all four
          // benchmarks that exist on main, exactly THREE pairs stop being
          // elided -- `json`'s `parseArray`, `m2-loopheap`'s `lastKept`
          // and `m3-generic-class`'s `boxNode` -- and the first of those
          // costs a measured +4% on the json benchmark (two interleaved
          // A/B runs, 600 samples a side: +4.5% and +4.2%).
          //
          // The obvious narrowing was tried and REJECTED ON ITS NUMBERS,
          // not skipped. A pending retain on a value defined by `Alloc`
          // in this block that has not since escaped cannot be the object
          // some other value releases, so it could be spared. That
          // recovers `lastKept` -- and neither of the other two, because
          // both retain a value that came from a `Load` or a `Call`,
          // where nothing local establishes identity. So it buys back
          // none of that 4%, in exchange for a SECOND aliasing argument
          // living in the pass where a wrong aliasing argument is a
          // double free. That is the trade GAP-0054 was created by.
          //
          // What would actually recover `parseArray` is knowing that
          // `parseValue`'s RESULT is a freshly-allocated +1 distinct from
          // everything live -- a uniqueness fact about a return value,
          // which DCDart's ARC conventions do not currently carry.
          // ADR-0063 records it, escalation 0011 asks for it, and it is a
          // spec §3 question rather than something to invent here.
          stats?.releaseLimited += pendingRetain.length;
          pendingRetain.clear();
          callConsumed.clear();
          kept.add(instruction);
        }
      case Call():
        stats?.opaqueLimited += pendingRetain.length;
        _invalidateAcrossCall(
          args: instruction.args,
          argOwnership: instruction.argOwnership,
          pendingRetain: pendingRetain,
          callConsumed: callConsumed,
        );
        kept.add(instruction);
      case IndirectCall():
        // (ADR-0060) IDENTICAL treatment to a direct `Call` -- and that
        // identity is the entire claim of the indirect-call unit, not an
        // implementation shortcut.
        //
        // An indirect call is exactly as opaque as a direct one; neither is
        // analysed interprocedurally here, so the conservative invalidation
        // is unchanged. What could have differed is the EXCEPTION: `Call`
        // keeps a pending retain alive across a call that CONSUMES its
        // argument, and an indirect call would lose that -- making every
        // closure call site an elision barrier, docs/escalations/0008 §3 --
        // if ownership were unknowable through a value.
        //
        // It is knowable, because `DCFuncPtr` carries it. `argOwnership` here
        // is read off the callee's own TYPE, which `dcc-lower` built from the
        // target function's declaration at the `FuncRef` that produced the
        // pointer. So this is not the same code by coincidence: it is the
        // same fact, arriving by a different route.
        //
        // The CALLEE operand is deliberately not fed into the invalidation
        // below -- it is a `DCFuncPtr`, never a `DCHeapPointer`, so it can
        // never be the object of a pending retain. `referencedValueIds`
        // still reports it, which is where it matters (the `callConsumed`
        // sweep at the top of this loop).
        stats?.opaqueLimited += pendingRetain.length;
        _invalidateAcrossCall(
          args: instruction.args,
          argOwnership: instruction.argOwnership,
          pendingRetain: pendingRetain,
          callConsumed: callConsumed,
        );
        kept.add(instruction);
      case MakeWeak():
      case WeakLoad():
      case DropWeak():
        // Opaque w.r.t. this pass's per-ValueId tracking -- see the file
        // header for why each of these specifically can't be skipped
        // over safely. No argOwnership-style exception exists for these
        // (spec's weak-count elision is a separate, unstarted question).
        stats?.opaqueLimited += pendingRetain.length;
        pendingRetain.clear();
        callConsumed.clear();
        kept.add(instruction);
      default:
        kept.add(instruction);
    }
  }

  // Whatever is still pending when the block ends is BLOCK-limited: scope
  // rule 1. This is the count the null-test extension would reduce; the
  // opaque count above is the one it would not touch.
  stats?.blockLimited += pendingRetain.length;

  return DCBasicBlock(
    id: block.id,
    params: block.params,
    body: kept.whereType<DCInstruction>().toList(),
  );
}

/// Rule 2 of this file's header, applied to one call -- direct or indirect.
///
/// Every pending retain is invalidated by the call, EXCEPT one whose object
/// is an argument the call fully consumes; that one is promoted into
/// [callConsumed] and thereafter tracked under the strictly stronger rule
/// documented at that set's declaration.
///
/// Shared by `Call` and `IndirectCall` rather than written twice: the two
/// differ only in where `argOwnership` comes from (a field computed by
/// dcc-lower from the callee's declaration, versus the callee pointer's own
/// `DCFuncPtr` type), and nothing about the SAFETY argument depends on which.
/// Duplicating it would make it possible for the direct and indirect cases to
/// drift apart under a later edit -- in a pass where a divergence is a
/// double-free, not a missed optimization.
void _invalidateAcrossCall({
  required List<DCValue> args,
  required List<bool> argOwnership,
  required Map<int, int> pendingRetain,
  required Set<int> callConsumed,
}) {
  final ownedIds = <int>{
    for (var i = 0; i < args.length; i++)
      if (argOwnership[i]) args[i].id.index,
  };
  pendingRetain.removeWhere((id, _) {
    if (ownedIds.contains(id)) {
      callConsumed.add(id); // survives THIS call, now under the strict rule above
      return false;
    }
    return true; // ordinary conservative invalidation, unchanged from before
  });
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
    case FuncRef():
      break; // names a symbol, not a value; no operands (cf. AddressOfGlobal)
    case IndirectCall(:final callee, :final args):
      // The CALLEE is a real operand, unlike `Call`'s symbol name. Omitting
      // it here would let this pass believe the function pointer is dead
      // between the `FuncRef` that made it and the call that uses it.
      ref(callee);
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
