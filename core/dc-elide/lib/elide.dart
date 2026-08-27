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
//   1. Per-block matching first; then ADR-0066 rule F's cross-block
//      FRONTIER pass (`_elideCrossBlock`) extends it to a retain whose
//      matching release sits on every path out of its block -- refusing
//      on missing dominance, anything opaque in between, or (ADR-0068) a
//      retain or frontier release whose own block lies on a CFG cycle;
//      ARC-free interior loops BETWEEN the pair are walked through.
//      A retain neither pass can match is left alone.
//   2. A `Call` instruction invalidates every pending retain, EXCEPT (a)
//      one matching an argument the call fully consumes
//      (`Call.argOwnership`, docs/decisions/0031-move-semantics.md, spec
//      §3.2 pass 4 -- see that ADR for why this specific case is provably
//      safe; a pending retain that survives this way is tracked more
//      strictly than an ordinary one, below), and (b) ALL ordinary
//      pending retains when the callee is in the module's
//      REFCOUNT-TRANSPARENT set (ADR-0066 rule T,
//      `computeRefcountTransparentCallees`: proven, transitively, to
//      contain only per-vid-covered releases -- so it can never decrement
//      any object below its call-entry count). Every other call is as
//      opaque as ever: the callee could release a borrowed reference's
//      object, and m2-owned's makeAndDropViaCall is ADR-0025's own worked
//      example of exactly that ambiguity.
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
  int nullElided = 0;
  int blockLimited = 0;
  int opaqueLimited = 0;
  int releaseLimited = 0;

  @override
  String toString() =>
      'elided=$elided crossBlock=$crossBlockElided nullOps=$nullElided '
      'blockLimited=$blockLimited '
      'opaqueLimited=$opaqueLimited releaseLimited=$releaseLimited';
}

DCFunction elideRedundantRetainReleasePairs(
  DCFunction function, [
  ElisionStats? stats,
  Set<String> transparentCallees = const <String>{},
]) {
  final noNullOps = _elideNullArcOps(function, stats);
  final perBlock = DCFunction(
    linkName: noNullOps.linkName,
    paramTypes: noNullOps.paramTypes,
    returnType: noNullOps.returnType,
    mode: noNullOps.mode,
    blocks:
        noNullOps.blocks.map((b) => _elideBlock(b, stats, transparentCallees)).toList(),
  );
  return _elideCrossBlock(perBlock, stats, transparentCallees);
}

// ---------------------------------------------------------------------------
// ADR-0066 rule N: ARC ops on a statically-null value are runtime no-ops.
// ---------------------------------------------------------------------------

/// Deletes every `Retain`/`Release` whose object is defined by a `NullRef`
/// in the same function.
///
/// SAFETY ARGUMENT. A `NullRef` defines a constant null, and SSA means the
/// value can never be anything else. `dc_retain(null)` and `dc_release(null)`
/// are DEFINED no-ops (ADR-0049: the backend emits an explicit null test
/// before touching the header, precisely so nullable references are legal to
/// retain/release). Removing an instruction that provably does nothing at
/// runtime changes no refcount, ever. The rule matches on the DEFINITION, not
/// on the type or a dataflow guess: a block PARAMETER that happens to be null
/// on one path (`Branch b1(vNull)`) is NOT matched -- its retain is dynamic
/// and must survive. That refusal is the negative test.
///
/// Why it is worth having: dcc-lower stores `null` into every reference field
/// a constructor initializes to null, and each such store emits a
/// `Retain <NullRef>`. On linked-structure code that is a large share of all
/// lowered retains (json's parseNumber: 6 of 6), and each one costs a real
/// call-shaped null-check-and-branch at runtime.
DCFunction _elideNullArcOps(DCFunction function, ElisionStats? stats) {
  final nullVids = <int>{};
  for (final block in function.blocks) {
    for (final instruction in block.body) {
      if (instruction is NullRef) nullVids.add(instruction.dest.id.index);
    }
  }
  if (nullVids.isEmpty) return function;

  var dropped = 0;
  final blocks = <DCBasicBlock>[];
  for (final block in function.blocks) {
    final body = <DCInstruction>[];
    for (final instruction in block.body) {
      final isNullArcOp = (instruction is Retain &&
              nullVids.contains(instruction.object.id.index)) ||
          (instruction is Release &&
              nullVids.contains(instruction.object.id.index));
      if (isNullArcOp) {
        dropped++;
        continue;
      }
      body.add(instruction);
    }
    blocks.add(DCBasicBlock(id: block.id, params: block.params, body: body));
  }
  if (dropped == 0) return function;
  stats?.nullElided += dropped;
  return DCFunction(
    linkName: function.linkName,
    paramTypes: function.paramTypes,
    returnType: function.returnType,
    mode: function.mode,
    blocks: blocks,
  );
}

// ---------------------------------------------------------------------------
// ADR-0066 rule T: refcount-transparent callees ("borrows-only" summary).
// ---------------------------------------------------------------------------

/// Computes the set of functions in [functions] that are REFCOUNT-
/// TRANSPARENT: calling one can never decrement any object's strong count
/// below its value at the moment of the call. A pending retain may be
/// carried across a `Call` to a member of this set (per-block AND
/// cross-block), because the whole safety argument of this pass -- "inside
/// an elided pair's interval, the transformed program decrements nothing"
/// (ADR-0063) -- survives such a call unchanged.
///
/// A function qualifies iff ALL of:
///
///   1. Its body has no weak op (`MakeWeak`/`WeakLoad`/`DropWeak`) and no
///      `IndirectCall` (no summary exists for a value-typed callee).
///   2. Every `Release` in it is COVERED: for every ValueId, along every
///      path, the running (#Retain - #Release) balance for that exact vid
///      never goes negative. A covered release only ever undoes an increment
///      the function itself performed on the SAME SSA value -- so per object,
///      the count never dips below its call-entry value, and (since a live
///      object enters at >= 1 and a covering retain precedes each release)
///      never reaches zero inside the callee. No destructor can therefore
///      fire from inside a qualifying function, which closes the "release
///      triggers a hidden destructor cascade" hole without a call edge to
///      the destructor existing anywhere in DC-IR.
///   3. Every direct `Call` targets a function in the module that itself
///      qualifies (transitively). A call to a symbol with no body here (an
///      extern) disqualifies.
///
/// Condition 2 is checked per-vid, NOT per-object: two vids can alias the
/// same object (ADR-0017), but a cover on the SAME vid is a fortiori the same
/// object, so per-vid coverage is strictly conservative. The field-overwrite
/// shape (`Store p <- new; Release old`) releases a vid with no prior retain
/// of that vid and correctly disqualifies -- `tinsert`/`unlinkFrom` in the
/// hashmap benchmark genuinely CAN free an object a caller is holding, and
/// they must stay opaque (that is this rule's own GAP-0054 test).
///
/// Recursion is handled as bad-REACHABILITY, not as an inductive proof
/// obligation: a function is disqualified iff a disqualifying instruction is
/// reachable from it in the module call graph. A self-recursive function with
/// only covered releases (json's `walk`, hashmap's `tlookup`) qualifies,
/// which is exactly the case the M3 gate needs.
///
/// The summary is computed on PRE-elision IR and remains valid for the
/// POST-elision module: elision deletes only (a) provably-paired
/// retain/release intervals -- inside which the transformed count sits
/// exactly one below the original, which condition 2 already keeps at or
/// above entry+1 -- and (b) null no-ops. See ADR-0066 for the full argument.
Set<String> computeRefcountTransparentCallees(List<DCFunction> functions) {
  final byName = <String, DCFunction>{
    for (final f in functions) f.linkName: f,
  };

  // Pass 1: local verdicts + call edges.
  final locallyBad = <String>{};
  final callees = <String, Set<String>>{};
  for (final f in functions) {
    final targets = <String>{};
    var bad = false;
    for (final block in f.blocks) {
      for (final instruction in block.body) {
        if (instruction is MakeWeak ||
            instruction is WeakLoad ||
            instruction is DropWeak ||
            instruction is IndirectCall) {
          bad = true;
        } else if (instruction is Call) {
          targets.add(instruction.targetName);
        }
      }
    }
    if (!bad && !_allReleasesCovered(f)) bad = true;
    if (bad) locallyBad.add(f.linkName);
    callees[f.linkName] = targets;
  }

  // Pass 2: propagate badness backwards over the call graph to a fixpoint.
  final callers = <String, Set<String>>{};
  for (final entry in callees.entries) {
    for (final t in entry.value) {
      (callers[t] ??= <String>{}).add(entry.key);
      if (!byName.containsKey(t)) locallyBad.add(entry.key); // extern callee
    }
  }
  final worklist = List<String>.of(locallyBad);
  final bad = Set<String>.of(locallyBad);
  while (worklist.isNotEmpty) {
    final b = worklist.removeLast();
    for (final caller in callers[b] ?? const <String>{}) {
      if (bad.add(caller)) worklist.add(caller);
    }
  }

  return {
    for (final f in functions)
      if (!bad.contains(f.linkName)) f.linkName,
  };
}

/// Condition 2 of [computeRefcountTransparentCallees]: for every ValueId,
/// along every path, the running per-vid (#Retain - #Release) balance never
/// goes negative.
///
/// A forward dataflow over blocks. Per block and vid: the net `delta` and the
/// lowest prefix value `minPrefix` inside the block. The lower bound of the
/// balance at block entry is the min over predecessors of (their entry bound
/// + their delta), starting from 0 at function entry (meet = min is exact for
/// "can any path make it negative"). The check is
/// `entryBound + minPrefix >= 0` everywhere. A back-edge cycle with net
/// negative delta drives the bound down forever; the iteration cap converts
/// that into a refusal rather than a spin.
bool _allReleasesCovered(DCFunction function) {
  final blocks = function.blocks;
  final indexOfBlock = <int, int>{};
  for (var i = 0; i < blocks.length; i++) {
    indexOfBlock[blocks[i].id.index] = i;
  }

  // Which vids have ARC traffic at all -- everything else can be ignored.
  final delta = List<Map<int, int>>.generate(blocks.length, (_) => <int, int>{});
  final minPrefix =
      List<Map<int, int>>.generate(blocks.length, (_) => <int, int>{});
  final arcVids = <int>{};
  for (var i = 0; i < blocks.length; i++) {
    final running = <int, int>{};
    for (final instruction in blocks[i].body) {
      int? vid;
      int step = 0;
      if (instruction is Retain) {
        vid = instruction.object.id.index;
        step = 1;
      } else if (instruction is Release) {
        vid = instruction.object.id.index;
        step = -1;
      }
      if (vid == null) continue;
      arcVids.add(vid);
      final now = (running[vid] ?? 0) + step;
      running[vid] = now;
      final low = minPrefix[i][vid];
      if (low == null || now < low) minPrefix[i][vid] = now;
    }
    delta[i] = running;
  }
  if (arcVids.isEmpty) return true;

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
      if (ti == null) return false; // malformed; refuse
      successors[i].add(ti);
    }
  }

  // entryBound[b][vid], missing = "not yet reached" (top). Entry block: 0.
  final entryBound = List<Map<int, int>?>.generate(blocks.length, (_) => null);
  entryBound[0] = {for (final v in arcVids) v: 0};
  var changed = true;
  var rounds = 0;
  final maxRounds = blocks.length * 4 + 16;
  while (changed) {
    if (++rounds > maxRounds) return false; // net-negative cycle: refuse
    changed = false;
    for (var i = 0; i < blocks.length; i++) {
      final inBound = entryBound[i];
      if (inBound == null) continue;
      for (final s in successors[i]) {
        final out = <int, int>{
          for (final v in arcVids) v: (inBound[v] ?? 0) + (delta[i][v] ?? 0),
        };
        final existing = entryBound[s];
        if (existing == null) {
          entryBound[s] = out;
          changed = true;
        } else {
          for (final v in arcVids) {
            final candidate = out[v] ?? 0;
            final current = existing[v] ?? 0;
            if (candidate < current) {
              existing[v] = candidate;
              changed = true;
            }
          }
        }
      }
    }
  }

  for (var i = 0; i < blocks.length; i++) {
    final inBound = entryBound[i];
    if (inBound == null) continue; // unreachable block: nothing executes
    for (final entry in minPrefix[i].entries) {
      if ((inBound[entry.key] ?? 0) + entry.value < 0) return false;
    }
  }
  return true;
}

/// Does [instruction] make it unsafe to carry a pending retain past it?
///
/// Exactly the file header's rules 2-4, in one place so the cross-block pass
/// and the per-block pass cannot drift apart on what "opaque" means. The ONLY
/// three ways a refcount can go down are an executed `Release`, an opaque
/// callee, and a weak op. A direct `Call` to a refcount-transparent callee
/// (ADR-0066 rule T) is proven to be none of the three, so it does not
/// count -- UNLESS it consumes an `@owned` argument, in which case the
/// cross-block walk refuses (the per-block pass has its own, stricter
/// `callConsumed` machinery for that case; the walk does not).
bool _isOpaqueForPendingRetain(
  DCInstruction instruction,
  Set<String> transparentCallees,
) {
  if (instruction is Call) {
    return !transparentCallees.contains(instruction.targetName) ||
        instruction.argOwnership.contains(true);
  }
  return instruction is IndirectCall ||
      instruction is MakeWeak ||
      instruction is WeakLoad ||
      instruction is DropWeak ||
      instruction is Release;
}

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
/// THE SAFETY ARGUMENT (ADR-0066 rule F, superseding ADR-0025's single-exit
/// form). A `Retain` of `v` in block A is cancelled against a FRONTIER of
/// `Release v` instructions -- one release on every path leaving the retain
/// -- when all of the following hold, each refusing rather than
/// approximating:
///
///   1. THE RETAIN'S BLOCK AND EVERY FRONTIER BLOCK EXECUTE AT MOST ONCE
///      PER CALL: none of them lies on a CFG cycle (is reachable from
///      itself). Without this a retain inside a loop pairs with one release
///      outside it -- N retains, one release -- and cancelling them would
///      under-release (and symmetrically for a release inside a loop).
///      Blocks BETWEEN the retain and the frontier MAY lie on cycles
///      (ADR-0068 extends ADR-0066 rule F here): an interior loop is safe
///      exactly because condition 2's walk scans every block it can visit,
///      so a loop body containing any `Release`, any opaque op, or a
///      `Retain v` fails the candidate anyway -- what executes N times is
///      then provably refcount-irrelevant to this pair. The live case is
///      NEON's `loaderNextBatch`: retain in the entry block, two ARC-free
///      copy loops, release in the single exit.
///   2. EVERY PATH from the retain reaches exactly one frontier member
///      before anything that could decrement a refcount. Established by a
///      forward walk from the instruction after the retain: the walk STOPS
///      a path at the first unclaimed `Release v` (that release joins the
///      frontier) and FAILS the whole candidate on any of -- a `Retain v`
///      (ambiguous pairing), anything opaque (`_isOpaqueForPendingRetain`:
///      a surviving `Release` of ANY other value per ADR-0063, a
///      non-transparent or owned-consuming `Call`, any `IndirectCall` or
///      weak op), or a `Return` reached with no release (a path that would
///      leak). Instructions already CLAIMED by a previously-accepted pair
///      are skipped: they are deleted, so they never execute (same
///      reasoning as the per-block pass's deleted-release rule).
///   3. A DOMINATES every frontier block. Every execution of a frontier
///      release was therefore preceded by this retain -- no path can lose a
///      release without also having lost the retain. (The retain's own
///      block executing implies the retain executed: blocks are
///      straight-line.)
///   4. NO FRONTIER MEMBER REACHES ANOTHER. If one frontier block could
///      flow into a second, a single execution would shed one retain and
///      TWO releases -- an over-release avoided by refusing outright. (In
///      the shapes this pass exists for, frontier blocks end in `Return`,
///      so the check is trivially met; it is still checked.)
///
/// With 1-4, each execution through the retain deletes exactly one retain
/// and exactly one release, and inside the deleted interval the transformed
/// program performs no decrement of anything -- so ADR-0063's gap invariant
/// (counts agree at boundaries, only rise inside, boundary >= 1) holds
/// verbatim, per path. Spelled out for the loop-tolerant form (ADR-0068):
/// the retain's block A is not on a cycle, so the retain executes at most
/// once per call; every frontier release's block likewise; condition 3 makes
/// every frontier execution follow the retain; condition 2's walk visited --
/// and fully scanned -- every block any interval execution can touch,
/// interior loop bodies included, so however many times such a body runs
/// inside the interval it decrements nothing. A path that enters an interior
/// loop and never leaves performs no decrement either and never reaches a
/// Return, so no balance is ever observed on it. Dominance is computed by
/// the standard iterative fixpoint, valid on cyclic CFGs; the DAG shortcut
/// the ADR-0066 form used is gone along with its whole-function back-edge
/// refusal.
///
/// Compared to the ADR-0025 version this replaces: multiple `Return` blocks
/// are handled (the frontier), opacity is checked over exactly the blocks
/// REACHABLE from the retain rather than an index-range superset, and a
/// direct call to a refcount-transparent callee (rule T) is not opaque.
/// Everything the old form accepted, this form accepts.
///
/// What ADR-0068's loop form still deliberately refuses: a retain or a
/// frontier release ON a cycle. The retain-and-release-both-inside-one-
/// iteration shape (both in the same loop body, pair complete before the
/// back edge) is NOT accepted -- it needs an alternation argument ("each
/// retain occurrence is followed by exactly one frontier occurrence before
/// the next retain occurrence") this pass does not currently make, and the
/// one live instance (json parseArray's `Retain tail`) is independently
/// blocked by an aliasing store-release inside the interval, so there is no
/// measured case the missing argument would recover (GAP-0067).
DCFunction _elideCrossBlock(
  DCFunction function,
  ElisionStats? stats,
  Set<String> transparentCallees,
) {
  final blocks = function.blocks;
  if (blocks.length < 2) return function;

  final indexOfBlock = <int, int>{};
  for (var i = 0; i < blocks.length; i++) {
    indexOfBlock[blocks[i].id.index] = i;
  }

  // Successors. Back edges no longer refuse the whole function (ADR-0068);
  // only an unknown target (malformed IR) does.
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
      if (ti == null) return function; // unknown target: refuse
      successors[i].add(ti);
    }
  }

  // Full forward reachability, cycle-safe. Used twice: condition 1's
  // "executes at most once" test (a block can execute twice per call iff it
  // is reachable from itself), and condition 4's frontier disjointness.
  final reachableFrom = List<Set<int>>.generate(blocks.length, (_) => <int>{});
  for (var i = 0; i < blocks.length; i++) {
    final stack = [...successors[i]];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (reachableFrom[i].add(n)) stack.addAll(successors[n]);
    }
  }
  bool onCycle(int i) => reachableFrom[i].contains(i);

  // Dominators, by the standard iterative fixpoint -- valid on cyclic CFGs
  // (the previous single-forward-sweep relied on the DAG's topological
  // order, which back edges break). Entry = {0}; everything else starts at
  // "all blocks" and only ever shrinks, so termination is by finite
  // monotone descent. An unreachable block keeps an over-large set, which
  // is harmless: condition 3 only ever queries dom[z] for a frontier block
  // z, and the walk that produced z started from a block the lowering made
  // reachable (and had it not, every instruction involved is dead code and
  // deleting it changes nothing).
  final preds = List<List<int>>.generate(blocks.length, (_) => <int>[]);
  for (var i = 0; i < blocks.length; i++) {
    for (final sIdx in successors[i]) {
      preds[sIdx].add(i);
    }
  }
  final allBlocks = <int>{for (var i = 0; i < blocks.length; i++) i};
  final dom = List<Set<int>>.generate(
      blocks.length, (i) => i == 0 ? {0} : Set<int>.of(allBlocks));
  var domChanged = true;
  while (domChanged) {
    domChanged = false;
    for (var i = 1; i < blocks.length; i++) {
      Set<int>? acc;
      for (final p in preds[i]) {
        acc = acc == null ? Set<int>.of(dom[p]) : acc.intersection(dom[p]);
      }
      final next = (acc ?? <int>{})..add(i);
      if (next.length != dom[i].length) {
        dom[i] = next;
        domChanged = true;
      }
    }
  }

  final removeFrom = <int, Set<int>>{}; // block index -> instruction indices
  bool isClaimed(int b, int k) => removeFrom[b]?.contains(k) ?? false;

  // Scan one block for the walk of condition 2, starting at [from].
  // Returns null on failure; otherwise the frontier release's index in this
  // block (or -1, meaning "clean through -- continue into successors").
  int? scanBlock(int b, int from, int vid) {
    final body = blocks[b].body;
    for (var k = from; k < body.length; k++) {
      final x = body[k];
      if (isClaimed(b, k)) continue; // deleted: never executes
      if (x is Release && x.object.id.index == vid) return k;
      if (x is Retain && x.object.id.index == vid) return null;
      if (x is Return) return null; // path ends with no release: refuse
      if (_isOpaqueForPendingRetain(x, transparentCallees)) return null;
    }
    return -1;
  }

  // Process retains in block order, restarting after every accepted pair so
  // later walks see the newly-claimed (hence non-executing) instructions.
  // Terminates: each acceptance strictly grows the claimed set.
  var changedAny = true;
  while (changedAny) {
    changedAny = false;
    for (var a = 0; a < blocks.length && !changedAny; a++) {
      final aBody = blocks[a].body;
      for (var ai = 0; ai < aBody.length && !changedAny; ai++) {
        final r = aBody[ai];
        if (r is! Retain || isClaimed(a, ai)) continue;
        // Condition 1, retain half (ADR-0068): the retain must execute at
        // most once per call, i.e. its block must not lie on a CFG cycle --
        // otherwise N retains would cancel against one frontier release.
        if (onCycle(a)) continue;
        final vid = r.object.id.index;

        // Condition 2: the forward walk. `frontier` maps block index ->
        // release instruction index; `visited` memoizes full-block scans
        // (every continuation enters a block at index 0, so one scan per
        // block is exact, not an approximation).
        final frontier = <int, int>{};
        final visited = <int>{};
        var ok = true;
        final first = scanBlock(a, ai + 1, vid);
        if (first == null) continue; // failed in A itself
        final work = <int>[];
        if (first >= 0) {
          frontier[a] = first;
        } else {
          work.addAll(successors[a]);
          if (successors[a].isEmpty) continue; // fell off A with no release
        }
        while (ok && work.isNotEmpty) {
          final b = work.removeLast();
          if (!visited.add(b)) continue;
          final hit = scanBlock(b, 0, vid);
          if (hit == null) {
            ok = false;
          } else if (hit >= 0) {
            frontier[b] = hit;
          } else {
            if (successors[b].isEmpty) {
              ok = false; // no terminator successor and no release: refuse
            } else {
              work.addAll(successors[b]);
            }
          }
        }
        if (!ok || frontier.isEmpty) continue;

        // Condition 1, release half (ADR-0068): every frontier release must
        // execute at most once per call -- a release on a cycle could run N
        // times against this retain's one execution.
        var frontierOnce = true;
        for (final z in frontier.keys) {
          if (onCycle(z)) {
            frontierOnce = false;
            break;
          }
        }
        if (!frontierOnce) continue;

        // Condition 3: A dominates every frontier block.
        var dominated = true;
        for (final z in frontier.keys) {
          if (z != a && !dom[z].contains(a)) {
            dominated = false;
            break;
          }
        }
        if (!dominated) continue;

        // Condition 4: no frontier block reaches another frontier block
        // (cycle-safe: reachableFrom was built with a visited set).
        var disjoint = true;
        for (final z in frontier.keys) {
          for (final other in frontier.keys) {
            if (other != z && reachableFrom[z].contains(other)) {
              disjoint = false;
              break;
            }
          }
          if (!disjoint) break;
        }
        if (!disjoint) continue;

        // Accept: claim the retain and every frontier release.
        (removeFrom[a] ??= <int>{}).add(ai);
        for (final entry in frontier.entries) {
          (removeFrom[entry.key] ??= <int>{}).add(entry.value);
        }
        stats?.crossBlockElided += 1;
        changedAny = true;
      }
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

DCBasicBlock _elideBlock(
  DCBasicBlock block, [
  ElisionStats? stats,
  Set<String> transparentCallees = const <String>{},
]) {
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

  final body = block.body;
  for (var idx = 0; idx < body.length; idx++) {
    final instruction = body[idx];
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
        // ------------------------------------------------------------
        // (ADR-0068) RUN-ATOMIC MATCHING. A maximal run of CONSECUTIVE
        // `Release` instructions -- an epilogue, a scope exit, a store's
        // old-value release directly abutting them -- is processed as one
        // unit: FIRST every pending retain whose matching release sits
        // ANYWHERE in the run cancels, THEN the surviving releases (kept
        // in their original order) invalidate whatever is still pending.
        //
        // WHY: dcc-lower emits an exit's releases in *some* order, and
        // under one-at-a-time processing that order decided elision -- a
        // surviving `Release a` one slot before a pending pair's
        // `Release b` killed the pair, while the opposite order cancelled
        // it. Same multiset, one executed pair of difference. The
        // emission-order study this ADR records tried fixing that in
        // dcc-lower with a static order (most-recently-used first): it
        // recovered NEON epochReduce's pair and un-elided
        // m2-heap-field's, because the pending retain is NOT reliably on
        // the most-recently-used local. No static order dominates; the
        // fix is to make THIS pass order-independent across a run.
        //
        // SAFETY. Equivalent to (1) commuting adjacent `Release`
        // instructions until the matched one is first, then (2) the
        // ordinary one-at-a-time rule. Step (2) is the pass as it was.
        // Step (1) is sound because between two adjacent releases NOTHING
        // executes: releases are pure decrements, decrements commute, and
        // every object's count at the END of the run is order-independent
        // -- so an object is freed by the run iff it was freed under the
        // original order, and no instruction that could USE it runs in
        // between. What order CAN move is which release site drops a
        // shared count to zero, i.e. destructor-cascade order within the
        // run -- and DCDart destructors are all compiler-synthesized
        // field-release cascades (ADR-0022, never user code), and a
        // managed object's address is not exposed to programs (GAP-0061:
        // no conversion exists in either direction), so no conforming
        // program can observe the difference. This is the same argument a
        // dcc-lower emission-order change would have needed; making it
        // here means it is checked against literal ADJACENCY in the
        // block body rather than against a lowering convention asserted
        // in a different file -- exactly the dependence ADR-0063
        // complained about when GAP-0054's safety hung on
        // `_releaseHeapLocals` placement.
        //
        // ADR-0063's gap invariant, restated for a cancelled pair whose
        // interval now contains earlier SURVIVING members of its own run:
        // up to the run, the interval is decrement-free as before (a
        // surviving release or opaque op there would have cleared the
        // pending). Inside the run, the transformed program's count for
        // the pair's object sits exactly one below the original's, and
        // both end the run at the same value; if the transformed count
        // reaches zero mid-run, the original also reaches zero by run end,
        // and between those two points only releases execute -- no use,
        // no weak load, nothing that could touch the freed object.
        // ------------------------------------------------------------
        var end = idx;
        while (end < body.length && body[end] is Release) {
          end++;
        }
        // Phase 1: cancellations, position-independent within the run.
        final cancelledAt = <int>{};
        for (var j = idx; j < end; j++) {
          final id = (body[j] as Release).object.id.index;
          final pendingIndex = pendingRetain.remove(id);
          if (pendingIndex == null) continue;
          callConsumed.remove(id);
          stats?.elided += 1;
          kept[pendingIndex] = null; // drop the matched Retain
          cancelledAt.add(j); // and drop this Release
          // Deliberately NO invalidation of the OTHER pending retains for
          // a cancelled release: it does not survive, so it never executes
          // and cannot decrement anything.
        }
        // Phase 2: survivors, original order. The first one to EXECUTE
        // invalidates every remaining pending retain; emitting them all
        // before clearing once is equivalent, since no cancellation
        // happens after phase 1.
        var anySurvived = false;
        for (var j = idx; j < end; j++) {
          if (cancelledAt.contains(j)) continue;
          kept.add(body[j]);
          anySurvived = true;
        }
        idx = end - 1; // the loop's ++ moves past the whole run
        if (anySurvived) {
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
          //
          // (ADR-0068 postscript.) Of the three pairs named above,
          // `boxNode`'s and one of `parseArray`'s now cancel under the
          // run-atomic rule at the top of this case -- their releases are
          // literally adjacent, so no ordering assumption is involved --
          // while `lastKept` (releases separated by the loop counter's
          // IAdd) and `parseArray`'s two field-store pairs still land
          // here. This branch is every bit as blunt as ADR-0063 made it;
          // only the population reaching it shrank.
          stats?.releaseLimited += pendingRetain.length;
          pendingRetain.clear();
          callConsumed.clear();
        }
      case Call():
        // (ADR-0066 rule T) A direct call to a refcount-transparent callee
        // is proven unable to decrement ANY object's count below its value
        // at the call -- so, uniquely among calls, it is safe to carry every
        // ORDINARY pending retain across it. Arguments passed to an @owned
        // parameter still get the strict `callConsumed` treatment (the
        // consuming-transfer reasoning of ADR-0031 is orthogonal to whether
        // the callee ever decrements), and `callConsumed` candidates were
        // already invalidated by the reference sweep at the top of this
        // loop if the call mentions them.
        final transparent =
            transparentCallees.contains(instruction.targetName);
        final invalidated = _invalidateAcrossCall(
          args: instruction.args,
          argOwnership: instruction.argOwnership,
          pendingRetain: pendingRetain,
          callConsumed: callConsumed,
          transparent: transparent,
        );
        stats?.opaqueLimited += invalidated;
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
        // Rule T never applies here: transparency is a fact about a NAMED
        // function's body, and an indirect callee has no name to look up.
        final invalidatedIndirect = _invalidateAcrossCall(
          args: instruction.args,
          argOwnership: instruction.argOwnership,
          pendingRetain: pendingRetain,
          callConsumed: callConsumed,
          transparent: false,
        );
        stats?.opaqueLimited += invalidatedIndirect;
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
///
/// With `transparent: true` (ADR-0066 rule T -- direct calls only) ordinary
/// pending retains are NOT invalidated: the callee is proven unable to
/// decrement anything. Owned-argument matches are still promoted to
/// [callConsumed] exactly as before -- consumption is a transfer-of-ownership
/// fact (ADR-0031), independent of whether the callee decrements.
///
/// Returns how many pending retains this call actually invalidated, which is
/// what `--why` reports as opaqueLimited (an owned-argument PROMOTION is not
/// an invalidation and is no longer counted as one).
int _invalidateAcrossCall({
  required List<DCValue> args,
  required List<bool> argOwnership,
  required Map<int, int> pendingRetain,
  required Set<int> callConsumed,
  required bool transparent,
}) {
  final ownedIds = <int>{
    for (var i = 0; i < args.length; i++)
      if (argOwnership[i]) args[i].id.index,
  };
  var invalidated = 0;
  pendingRetain.removeWhere((id, _) {
    if (ownedIds.contains(id)) {
      callConsumed.add(id); // survives THIS call, now under the strict rule above
      return false;
    }
    if (transparent) return false; // proven non-decrementing callee
    invalidated++;
    return true; // ordinary conservative invalidation, unchanged from before
  });
  return invalidated;
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
    case FAdd(:final lhs, :final rhs):
    case FSub(:final lhs, :final rhs):
    case FMul(:final lhs, :final rhs):
    case FDiv(:final lhs, :final rhs):
    case FCmp(:final lhs, :final rhs):
      ref(lhs);
      ref(rhs);
    case MakeStruct(:final fields):
      fields.forEach(ref);
    case IConvert(:final source):
      ref(source);
    case FConvert(:final source):
      ref(source);
    case FNeg(:final operand):
      ref(operand);
    case ConstFloat():
      break; // no operands, only a dest (cf. ConstInt)
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
