// core/dc-elide/test/elision_test.dart
//
// CLAUDE.md's testing rule: "Anything touching ARC codegen also needs an
// elision test: assert the expected number of dc_retain/dc_release calls
// in the emitted IR." Tests `elideRedundantRetainReleasePairs`
// (docs/decisions/0025-redundant-pair-removal.md) in isolation against
// hand-built `DCFunction`s -- this targets the pass's own logic directly,
// not dcc-lower's specific lowering choices for any one source shape
// (which could change independently of whether the pass itself is
// correct). The real end-to-end proof that this actually fires on real
// source (`core/examples/m2-alias/alias.dart`) is
// `core/tests/conformance/m2-alias/run.sh` (still leak-free, unaffected
// counts already re-verified) plus a direct `dc-objdump --arc` comparison
// recorded in the ADR -- this file is the mechanism-level safety net.
//
// Run: cd core/dc-elide && dart pub get && dart test

import 'package:dc_ir/dc_ir.dart';
import 'package:dc_elide/elide.dart';
import 'package:test/test.dart';

void main() {
  test('removes a Retain/Release pair with nothing refcount-relevant between them', () {
    // Mirrors core/examples/m2-alias/alias.dart's makeAliasAndReadValue
    // shape: alias a heap local, read a scalar field through it, then
    // release BOTH the original and the alias (since the returned value
    // is the scalar, not either heap reference). The retain (for the
    // alias) and the FIRST of the two releases have nothing but
    // refcount-irrelevant PtrOffset/Load between them -- provably safe to
    // cancel.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final fieldPtr = DCValue(ValueId(1), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(2), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_redundant_pair',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [heapPtr],
          body: [
            Retain(object: heapPtr), // aliasing retain
            PtrOffset(dest: fieldPtr, base: heapPtr, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr),
            Release(object: heapPtr), // "original"'s release
            Release(object: heapPtr), // "alias"'s release
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 0, reason: 'the redundant Retain must be removed');
    expect(
      body.whereType<Release>().length,
      1,
      reason: 'exactly one Release must remain -- the object still needs releasing once',
    );
    // Order and the non-ARC instructions must be preserved exactly.
    expect(body, [
      isA<PtrOffset>(),
      isA<Load>(),
      isA<Release>(),
      isA<Return>(),
    ]);
  });

  test('does NOT remove a Retain/Release pair spanning a Call with a BORROWED argument', () {
    // The Call in between is opaque when the argument is borrowed (not
    // @owned) -- the callee could retain, release, or store the same
    // object anywhere, and nothing here does interprocedural analysis to
    // rule that out. This pair must NOT be touched.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callResult = DCValue(ValueId(1), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_call_spanning_pair',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            Retain(object: heapPtr),
            Call(dest: callResult, targetName: 'someBorrowingConsumer', args: [heapPtr], argOwnership: [false]),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1, reason: 'a retain spanning a borrowing Call must survive');
    expect(body.whereType<Release>().length, 1, reason: 'its matching release must survive too');
  });

  test('removes a Retain/Release pair spanning a Call when the argument is fully owned-consumed '
      '(move semantics, docs/decisions/0031-move-semantics.md)', () {
    // Mirrors core/examples/m2-owned/owned.dart's makeAndDropViaCall,
    // now with the real fix: dropBoxAndReadValue's parameter is @owned
    // (argOwnership: [true]), so the caller's Retain/Release pair around
    // the call is genuinely redundant -- the callee's own release already
    // accounts for the reference the caller retained. Unlike the borrowed
    // case above, this is provably safe (see the ADR).
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callResult = DCValue(ValueId(1), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_owned_call_consumed',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            Retain(object: heapPtr),
            Call(dest: callResult, targetName: 'dropBoxAndReadValue', args: [heapPtr], argOwnership: [true]),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 0,
        reason: 'the retain around an owned-consumed argument with no later use is redundant');
    expect(body.whereType<Release>().length, 0,
        reason: "its matching release is redundant too -- the callee's own release already accounts for it");
    expect(body, [isA<Call>(), isA<Return>()]);
  });

  test('does NOT remove a pair spanning an owned-consuming Call when the value is used again '
      'afterward -- the critical safety case', () {
    // Even though the argument is passed to an @owned parameter, if the
    // SAME value is read again after the call (e.g. `return b.value;`
    // after `consumeB(b)`), the pair is load-bearing: under naive
    // semantics two references are alive across the call (the retained
    // copy handed to the callee, and the local's own original reference),
    // so the local's own reference survives the callee's release and
    // stays valid to read afterward. Cancelling the pair would leave only
    // ONE reference, which the callee's own release would drop to zero --
    // making the later read a genuine use-after-free. This is exactly
    // what `referencedValueIds`'s stricter call-consumed rule exists to
    // catch.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callResult = DCValue(ValueId(1), DCInt.u64);
    final fieldPtr = DCValue(ValueId(2), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(3), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_owned_call_then_read_again',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            Retain(object: heapPtr),
            Call(dest: callResult, targetName: 'ownedConsumer', args: [heapPtr], argOwnership: [true]),
            PtrOffset(dest: fieldPtr, base: heapPtr, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr),
            Release(object: heapPtr),
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1,
        reason: 'heapPtr is referenced again after the call, so the pair must survive');
    expect(body.whereType<Release>().length, 1);
  });

  test('does NOT remove a Retain/Release pair spanning a WeakLoad on a different value', () {
    // A WeakLoad's own codegen conditionally retains its target -- and a
    // weak pointer's address can alias a pending retain's object even
    // though it's a different DCValue/ValueId (ADR-0023). This pass
    // cannot prove non-aliasing at the DC-IR level, so it must treat
    // EVERY WeakLoad as opaque, not just ones on the exact same value.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final weakPtr = DCValue(ValueId(1), const DCWeakPointer(DCVoid()));
    final loaded = DCValue(ValueId(2), const DCHeapPointer(DCVoid()));

    final function = DCFunction(
      linkName: 'test_weakload_spanning_pair',
      paramTypes: const [DCWeakPointer(DCVoid())],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [weakPtr],
          body: [
            Retain(object: heapPtr),
            WeakLoad(dest: loaded, weak: weakPtr),
            Release(object: heapPtr),
            const Return(),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1, reason: 'a retain spanning a WeakLoad must survive');
    expect(body.whereType<Release>().length, 1);
  });

  test('leaves an unmatched Retain alone (value returned/crosses the block)', () {
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final function = DCFunction(
      linkName: 'test_unmatched_retain',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: const DCHeapPointer(DCVoid()),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [heapPtr],
          body: [
            Retain(object: heapPtr),
            Return(value: heapPtr),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1, reason: 'no matching Release exists -- must not be removed');
  });

  // -----------------------------------------------------------------------
  // ADR-0060 -- INDIRECT CALLS. The three tests below are the direct-call
  // tests above, re-run through a callee that is a VALUE rather than a name.
  //
  // They are duplicated deliberately rather than parameterized: the whole
  // claim of ADR-0060 is that these two call forms are treated IDENTICALLY by
  // this pass, and a shared helper that ran both would make a future
  // divergence invisible by construction. Written out, a divergence fails
  // exactly one of them.
  // -----------------------------------------------------------------------

  test('removes a Retain/Release pair spanning an INDIRECT call whose pointer type says @owned '
      '(ADR-0060 -- the property docs/escalations/0008 §3 predicted would be lost)', () {
    // The callee is unknown at this call site. What is known is the POINTER'S
    // TYPE, and it records that parameter 0 is consumed -- so the pair is
    // exactly as redundant as it is for the equivalent direct Call, and this
    // pass has exactly as much reason to remove it.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callee = DCValue(
      ValueId(1),
      const DCFuncPtr(
        [DCFuncParam(DCHeapPointer(DCVoid()), owned: true)],
        DCInt.u64,
      ),
    );
    final callResult = DCValue(ValueId(2), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_indirect_owned_consumed',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            FuncRef(dest: callee, targetName: 'dropBoxAndReadValue'),
            Retain(object: heapPtr),
            IndirectCall(dest: callResult, callee: callee, args: [heapPtr]),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 0,
        reason: 'ownership reached this pass through DCFuncPtr; the pair is redundant');
    expect(body.whereType<Release>().length, 0);
    expect(body, [isA<FuncRef>(), isA<IndirectCall>(), isA<Return>()]);
  });

  test('does NOT remove a pair spanning an INDIRECT call whose pointer type says BORROWED', () {
    // Same instruction, opposite type. If `owned` were ignored -- or if
    // IndirectCall fell through to the switch's `default:` and were treated as
    // an ordinary skippable instruction -- this pair would be wrongly removed
    // and the object freed while the caller still holds it.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callee = DCValue(
      ValueId(1),
      const DCFuncPtr(
        [DCFuncParam(DCHeapPointer(DCVoid()), owned: false)],
        DCInt.u64,
      ),
    );
    final callResult = DCValue(ValueId(2), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_indirect_borrowed',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            FuncRef(dest: callee, targetName: 'someBorrowingConsumer'),
            Retain(object: heapPtr),
            IndirectCall(dest: callResult, callee: callee, args: [heapPtr]),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1,
        reason: 'a retain spanning a BORROWING indirect call must survive, exactly as for a direct one');
    expect(body.whereType<Release>().length, 1);
  });

  test('does NOT remove a pair spanning an owned-consuming INDIRECT call when the value is used '
      'again afterward -- the critical safety case, through a pointer', () {
    // The stricter call-consumed rule must apply to IndirectCall too. If
    // `referencedValueIds` did not report IndirectCall's operands, the later
    // read would not invalidate the candidate and this pair would be
    // cancelled, turning the Load into a use-after-free.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callee = DCValue(
      ValueId(1),
      const DCFuncPtr(
        [DCFuncParam(DCHeapPointer(DCVoid()), owned: true)],
        DCInt.u64,
      ),
    );
    final callResult = DCValue(ValueId(2), DCInt.u64);
    final fieldPtr = DCValue(ValueId(3), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(4), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_indirect_owned_then_read_again',
      paramTypes: const [],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: const [],
          body: [
            FuncRef(dest: callee, targetName: 'ownedConsumer'),
            Retain(object: heapPtr),
            IndirectCall(dest: callResult, callee: callee, args: [heapPtr]),
            PtrOffset(dest: fieldPtr, base: heapPtr, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr),
            Release(object: heapPtr),
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1,
        reason: 'heapPtr is referenced again after the indirect call, so the pair must survive');
    expect(body.whereType<Release>().length, 1);
  });

  test('IndirectCall.argOwnership is READ from the callee type, so it cannot disagree with it', () {
    // Not a behavioural test of the pass -- a structural one about why the
    // pass can trust the fact. `Call` stores argOwnership as a field that
    // dcc-lower fills in; `IndirectCall` has no such field, so there is no
    // second copy to drift.
    final callee = DCValue(
      ValueId(0),
      const DCFuncPtr(
        [
          DCFuncParam(DCHeapPointer(DCVoid()), owned: true),
          DCFuncParam(DCInt.u64, owned: false),
        ],
        DCVoid(),
      ),
    );
    final heapPtr = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final scalar = DCValue(ValueId(2), DCInt.u64);

    final call = IndirectCall(callee: callee, args: [heapPtr, scalar]);
    expect(call.argOwnership, [true, false]);
    expect(call.signature.returnType, const DCVoid());
    expect(call.result, isNull, reason: 'a void indirect call defines no value');
  });

  test('two DCFuncPtr types differing ONLY in ownership are NOT equal', () {
    // The type-identity property the whole design rests on. If these compared
    // equal, dcc-lower would let an owned-consuming pointer be passed where a
    // borrowing one is expected, which is a double release.
    const owned = DCFuncPtr([DCFuncParam(DCHeapPointer(DCVoid()), owned: true)], DCInt.u64);
    const borrowed = DCFuncPtr([DCFuncParam(DCHeapPointer(DCVoid()), owned: false)], DCInt.u64);
    expect(owned == borrowed, isFalse);
    expect(owned == const DCFuncPtr([DCFuncParam(DCHeapPointer(DCVoid()), owned: true)], DCInt.u64), isTrue);
  });

  // -------------------------------------------------------------------
  // ADR-0063 / GAP-0054: a SURVIVING Release of an ALIASING value.
  //
  // These four are the mechanism-level statement of the fix. The
  // end-to-end proof that it was a real miscompilation and not a
  // theoretical one is tests/conformance/elide-alias/, which runs a
  // program that returned 198 instead of 110 through `dcc build` at -O2.
  // -------------------------------------------------------------------

  test('does NOT remove a pair spanning a surviving Release of a DIFFERENT value (GAP-0054)', () {
    // THE BUG. `%1` and `%2` are distinct DCValues that may denote the same
    // object -- `%2 = Load %1.field` is exactly how ADR-0017's alias retain
    // produces one. Pass 3 used to reason "no Release of %2 appears between
    // the Retain and the Release of %2", which is true and irrelevant: the
    // Release of %1 in between can drive the SHARED object's refcount to
    // zero, and cancelling the pair is what removes the +1 that stopped it.
    final other = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final aliased = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final fieldPtr = DCValue(ValueId(2), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(3), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_alias_release',
      paramTypes: const [DCHeapPointer(DCVoid()), DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [other, aliased],
          body: [
            Retain(object: aliased),
            Release(object: other), // may be the SAME object as `aliased`
            PtrOffset(dest: fieldPtr, base: aliased, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr), // the use-after-free
            Release(object: aliased),
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(function).blocks.single.body;
    expect(body.whereType<Retain>().length, 1,
        reason: 'the Retain protects the object across a Release that may free it');
    expect(body.whereType<Release>().length, 2, reason: 'both Releases must survive');
    expect(body.length, function.blocks.single.body.length,
        reason: 'nothing at all may be removed here');
  });

  test(
      'run-atomic matching (ADR-0068): a pair whose release sits in the same '
      'CONSECUTIVE run as an earlier foreign release still cancels', () {
    // THIS TEST INVERTED ON PURPOSE, and the history matters. Under
    // ADR-0063 it asserted refusal, with the rationale that the pass's
    // invariant is "about refcounts, not uses" -- because whether a use
    // followed the foreign release was a fact about dcc-lower's emission
    // order, asserted in no file the pass could see. ADR-0068 makes the
    // no-instruction-between fact LOCAL: these two releases are literally
    // adjacent in the block body, the pass itself checks that adjacency,
    // and adjacent releases commute (pure decrements; every count is at
    // its order-independent final value when the run ends; destructor
    // cascades are compiler-synthesized field releases only, ADR-0022, so
    // nothing user-visible runs at either order). Commute `Release other`
    // past `Release aliased` and this is the plain ADR-0025 shape. The
    // GAP-0054 danger -- a USE between the foreign release and the pair's
    // release -- breaks the run and still refuses: that is the next test.
    final other = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final aliased = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));

    final function = DCFunction(
      linkName: 'test_alias_release_adjacent_run',
      paramTypes: const [DCHeapPointer(DCVoid()), DCHeapPointer(DCVoid())],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [other, aliased],
          body: [
            Retain(object: aliased),
            Release(object: other),
            Release(object: aliased),
            Return(value: null),
          ],
        ),
      ],
    );

    final stats = ElisionStats();
    final body =
        elideRedundantRetainReleasePairs(function, stats).blocks.single.body;
    expect(body.whereType<Retain>().length, 0,
        reason: 'the pair cancels; only the foreign release executes');
    expect(body.whereType<Release>().length, 1);
    expect(stats.elided, 1);
  });

  test(
      'run-atomic matching does NOT fire across a USE between the foreign '
      'release and the pair\'s release -- the GAP-0054 shape stays refused',
      () {
    // `Load` through the retained value between the two releases: if the
    // foreign release freed the object (they may alias, ADR-0017), this
    // read is the use-after-free GAP-0054 was. The Load breaks the
    // consecutive-release run, so the foreign release is processed alone,
    // survives, and invalidates the pending retain -- the pair must
    // survive whole.
    final other = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final aliased = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final fieldPtr = DCValue(ValueId(2), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(3), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_alias_release_use_between',
      paramTypes: const [DCHeapPointer(DCVoid()), DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [other, aliased],
          body: [
            Retain(object: aliased),
            Release(object: other),
            PtrOffset(dest: fieldPtr, base: aliased, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr),
            Release(object: aliased),
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(function).blocks.single.body;
    expect(body.whereType<Retain>().length, 1,
        reason: 'a use inside the would-be interval must keep the pair');
    expect(body.whereType<Release>().length, 2);
  });

  test('a DELETED Release does not invalidate other pending retains', () {
    // The other half of the rule, and the reason pass 3 still does
    // anything at all. An inner pair that cancels never executes, so it
    // decrements nothing and cannot end any object's life -- an outer
    // pair enclosing it stays elidable. Getting this wrong in the
    // conservative direction would turn pass 3 into a near no-op, which
    // would "pass" every correctness test while costing real performance.
    final outer = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final inner = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));

    final function = DCFunction(
      linkName: 'test_nested_pairs',
      paramTypes: const [DCHeapPointer(DCVoid()), DCHeapPointer(DCVoid())],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [outer, inner],
          body: [
            Retain(object: outer),
            Retain(object: inner),
            Release(object: inner), // cancels -> deleted -> never executes
            Release(object: outer), // so this pair is still safe to cancel
            Return(value: null),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(function).blocks.single.body;
    expect(body.whereType<Retain>().length, 0, reason: 'BOTH pairs must still be elided');
    expect(body.whereType<Release>().length, 0);
    expect(body, [isA<Return>()]);
  });

  test('a pair with no Release of anything in between is still elided (no regression)', () {
    // The case that carries the pass's entire value, restated after the
    // fix: Alloc, PtrOffset, Load, Store and arithmetic between a Retain
    // and its Release still cancel, because none of them can decrement a
    // refcount. If this ever fails, pass 3 has become a no-op.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final fresh = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final fieldPtr = DCValue(ValueId(2), const DCPointer(DCInt.u64));
    final fieldVal = DCValue(ValueId(3), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_still_elides',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [heapPtr],
          body: [
            Retain(object: heapPtr),
            Alloc(dest: fresh, payloadSizeBytes: 8),
            PtrOffset(dest: fieldPtr, base: heapPtr, offsetBytes: 0),
            Load(dest: fieldVal, pointer: fieldPtr),
            Release(object: heapPtr),
            Return(value: fieldVal),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(function).blocks.single.body;
    expect(body.whereType<Retain>().length, 0, reason: 'pass 3 must still fire here');
    expect(body.whereType<Release>().length, 0);
  });

  // -------------------------------------------------------------------------
  // ADR-0066 rule N: ARC ops on a statically-null value are runtime no-ops.
  // -------------------------------------------------------------------------

  test('rule N: removes Retain/Release of a value defined by NullRef in this function', () {
    // dcc-lower stores `null` into every reference field a constructor
    // initializes to null, and each such store emits `Retain <NullRef>`.
    // ADR-0049 makes dc_retain(null)/dc_release(null) DEFINED no-ops, so the
    // instructions are removable outright -- no pairing needed (this retain
    // is unmatched, exactly like a real constructor's null field store).
    final nullVal = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final obj = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final fieldPtr = DCValue(ValueId(2), const DCPointer(DCHeapPointer(DCVoid())));

    final function = DCFunction(
      linkName: 'test_null_arc_ops',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [obj],
          body: [
            NullRef(dest: nullVal),
            Retain(object: nullVal), // no-op: retains null on every execution
            PtrOffset(dest: fieldPtr, base: obj, offsetBytes: 0),
            Store(pointer: fieldPtr, value: nullVal),
            Release(object: nullVal), // no-op too
            Return(value: null),
          ],
        ),
      ],
    );

    final stats = ElisionStats();
    final body = elideRedundantRetainReleasePairs(function, stats).blocks.single.body;
    expect(body.whereType<Retain>().length, 0, reason: 'retain of a static null is a no-op');
    expect(body.whereType<Release>().length, 0, reason: 'release of a static null is a no-op');
    expect(body.whereType<Store>().length, 1, reason: 'the store itself must survive');
    expect(stats.nullElided, 2);
  });

  test('rule N: does NOT remove a Retain of a block parameter one predecessor binds to null', () {
    // The negative that keeps rule N honest: a block PARAM is dynamic. One
    // predecessor passes null, another passes a real object -- the retain in
    // the join block is a real retain on the second path and must survive.
    final nullVal = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final obj = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(2), const DCBool());
    final joined = DCValue(ValueId(3), const DCHeapPointer(DCVoid()));

    final function = DCFunction(
      linkName: 'test_null_param_negative',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [obj, cond],
          body: [
            NullRef(dest: nullVal),
            CondBranch(
              cond: cond,
              trueTarget: BlockId(1),
              trueArgs: [nullVal],
              falseTarget: BlockId(1),
              falseArgs: [obj],
            ),
          ],
        ),
        DCBasicBlock(
          id: BlockId(1),
          params: [joined],
          body: [
            Retain(object: joined), // DYNAMIC: null on one path only
            Call(dest: null, targetName: 'sink', args: [joined], argOwnership: const [false]),
            Return(value: null),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final retains = [
      for (final b in elided.blocks) ...b.body.whereType<Retain>(),
    ];
    expect(retains.length, 1, reason: 'a block-param retain is dynamic and must survive');
  });

  // -------------------------------------------------------------------------
  // ADR-0066 rule T: refcount-transparent callees.
  // -------------------------------------------------------------------------

  test('rule T: a pair spanning a Call to a refcount-transparent callee IS elided', () {
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callResult = DCValue(ValueId(1), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_transparent_call',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [heapPtr],
          body: [
            Retain(object: heapPtr),
            Call(
              dest: callResult,
              targetName: 'provenBorrowsOnly',
              args: [heapPtr],
              argOwnership: const [false],
            ),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(
      function,
      null,
      const {'provenBorrowsOnly'},
    ).blocks.single.body;
    expect(body.whereType<Retain>().length, 0,
        reason: 'a proven non-decrementing callee cannot end the object\'s life');
    expect(body.whereType<Release>().length, 0);
  });

  test('rule T: the SAME shape with the callee NOT in the transparent set survives', () {
    // The negative control for the test above -- identical IR, empty set.
    final heapPtr = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final callResult = DCValue(ValueId(1), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_opaque_call_control',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(
          id: BlockId(0),
          params: [heapPtr],
          body: [
            Retain(object: heapPtr),
            Call(
              dest: callResult,
              targetName: 'provenBorrowsOnly',
              args: [heapPtr],
              argOwnership: const [false],
            ),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final body = elideRedundantRetainReleasePairs(function).blocks.single.body;
    expect(body.whereType<Retain>().length, 1);
    expect(body.whereType<Release>().length, 1);
  });

  group('computeRefcountTransparentCallees', () {
    DCFunction leafWithBody(String name, List<DCInstruction> body,
        {List<DCValue> params = const []}) {
      return DCFunction(
        linkName: name,
        paramTypes: [for (final p in params) p.type],
        returnType: const DCVoid(),
        mode: DCMode.bare,
        blocks: [DCBasicBlock(id: BlockId(0), params: params, body: body)],
      );
    }

    test('a self-recursive function whose releases are all covered qualifies (walk shape)', () {
      // The M3-gate case: Retain in one block, the covering Release on every
      // path in later blocks, a recursive borrowed call in between.
      final n = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
      final childPtr = DCValue(ValueId(1), const DCPointer(DCHeapPointer(DCVoid())));
      final child = DCValue(ValueId(2), const DCHeapPointer(DCVoid()));
      final nil = DCValue(ValueId(3), const DCHeapPointer(DCVoid()));
      final isNil = DCValue(ValueId(4), const DCBool());

      final walk = DCFunction(
        linkName: 'walkish',
        paramTypes: const [DCHeapPointer(DCVoid())],
        returnType: const DCVoid(),
        mode: DCMode.bare,
        blocks: [
          DCBasicBlock(id: BlockId(0), params: [n], body: [
            PtrOffset(dest: childPtr, base: n, offsetBytes: 0),
            Load(dest: child, pointer: childPtr),
            Retain(object: child),
            NullRef(dest: nil),
            ICmp(dest: isNil, lhs: child, rhs: nil, predicate: ICmpPredicate.eq),
            CondBranch(
              cond: isNil,
              trueTarget: BlockId(1),
              trueArgs: const [],
              falseTarget: BlockId(2),
              falseArgs: const [],
            ),
          ]),
          DCBasicBlock(id: BlockId(1), params: const [], body: [
            Release(object: child),
            Return(value: null),
          ]),
          DCBasicBlock(id: BlockId(2), params: const [], body: [
            Call(dest: null, targetName: 'walkish', args: [child], argOwnership: const [false]),
            Release(object: child),
            Return(value: null),
          ]),
        ],
      );

      expect(computeRefcountTransparentCallees([walk]), {'walkish'});
    });

    test('an UNCOVERED release disqualifies (the field-overwrite / GAP-0054 shape)', () {
      // `Store p <- new; Release old` -- `old` was never retained HERE, so
      // the function genuinely decrements an object it did not first bump.
      // hashmap's tinsert/unlinkFrom are this shape and must stay opaque.
      final p = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
      final newVal = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
      final fieldPtr = DCValue(ValueId(2), const DCPointer(DCHeapPointer(DCVoid())));
      final oldVal = DCValue(ValueId(3), const DCHeapPointer(DCVoid()));

      final overwrite = leafWithBody('overwrite', [
        PtrOffset(dest: fieldPtr, base: p, offsetBytes: 0),
        Load(dest: oldVal, pointer: fieldPtr),
        Retain(object: newVal),
        Store(pointer: fieldPtr, value: newVal),
        Release(object: oldVal), // uncovered: no prior Retain of oldVal
        Return(value: null),
      ], params: [p, newVal]);

      expect(computeRefcountTransparentCallees([overwrite]), isEmpty);
    });

    test('a release covered on only ONE path disqualifies', () {
      // Retain in a conditional arm, Release in the merge block: on the
      // other path the release is a net decrement. min-over-paths must
      // catch it.
      final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
      final cond = DCValue(ValueId(1), const DCBool());

      final oneArm = DCFunction(
        linkName: 'oneArm',
        paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
        returnType: const DCVoid(),
        mode: DCMode.bare,
        blocks: [
          DCBasicBlock(id: BlockId(0), params: [v, cond], body: [
            CondBranch(
              cond: cond,
              trueTarget: BlockId(1),
              trueArgs: const [],
              falseTarget: BlockId(2),
              falseArgs: const [],
            ),
          ]),
          DCBasicBlock(id: BlockId(1), params: const [], body: [
            Retain(object: v),
            Branch(target: BlockId(2), args: const []),
          ]),
          DCBasicBlock(id: BlockId(2), params: const [], body: [
            Release(object: v), // covered on the b1 path ONLY
            Return(value: null),
          ]),
        ],
      );

      expect(computeRefcountTransparentCallees([oneArm]), isEmpty);
    });

    test('weak ops, indirect calls, and extern callees disqualify; badness propagates to callers', () {
      final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
      final w = DCValue(ValueId(1), const DCWeakPointer(DCVoid()));

      final weakUser = leafWithBody('weakUser', [
        MakeWeak(dest: w, object: v),
        Return(value: null),
      ], params: [v]);
      final externCaller = leafWithBody('externCaller', [
        Call(dest: null, targetName: 'not_in_module', args: const [], argOwnership: const []),
        Return(value: null),
      ]);
      final callsWeakUser = leafWithBody('callsWeakUser', [
        Call(dest: null, targetName: 'weakUser', args: [v], argOwnership: const [false]),
        Return(value: null),
      ], params: [v]);
      final clean = leafWithBody('clean', [
        Return(value: null),
      ]);

      expect(
        computeRefcountTransparentCallees([weakUser, externCaller, callsWeakUser, clean]),
        {'clean'},
      );
    });
  });

  // -------------------------------------------------------------------------
  // ADR-0066 rule F: multi-exit cross-block frontier pairs.
  // -------------------------------------------------------------------------

  test('rule F: a retain paired against a Release on EACH of two return paths is elided '
      '(the tlookup descent shape)', () {
    // b0: retain, null test. b1: transparent recursive call, release,
    // return. b2: release, return. One retain, a frontier of two releases.
    final n = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final childPtr = DCValue(ValueId(1), const DCPointer(DCHeapPointer(DCVoid())));
    final child = DCValue(ValueId(2), const DCHeapPointer(DCVoid()));
    final nil = DCValue(ValueId(3), const DCHeapPointer(DCVoid()));
    final isNil = DCValue(ValueId(4), const DCBool());
    final res = DCValue(ValueId(5), DCInt.u64);
    final zero = DCValue(ValueId(6), DCInt.u64);

    final function = DCFunction(
      linkName: 'test_frontier',
      paramTypes: const [DCHeapPointer(DCVoid())],
      returnType: DCInt.u64,
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [n], body: [
          PtrOffset(dest: childPtr, base: n, offsetBytes: 0),
          Load(dest: child, pointer: childPtr),
          Retain(object: child),
          NullRef(dest: nil),
          ICmp(dest: isNil, lhs: child, rhs: nil, predicate: ICmpPredicate.eq),
          CondBranch(
            cond: isNil,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          ConstInt(dest: zero, bits: 0),
          Release(object: child),
          Return(value: zero),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Call(
            dest: res,
            targetName: 'test_frontier',
            args: [child],
            argOwnership: const [false],
          ),
          Release(object: child),
          Return(value: res),
        ]),
      ],
    );

    final stats = ElisionStats();
    final elided = elideRedundantRetainReleasePairs(
      function,
      stats,
      const {'test_frontier'},
    );
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 0,
        reason: 'the retain has a release on every path: the frontier cancels it');
    expect(all.whereType<Release>().length, 0,
        reason: 'both frontier releases go with it -- one per path');
    expect(stats.crossBlockElided, 1);
  });

  test('rule F: refuses when one path reaches Return with NO release (would leak)', () {
    final child = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(1), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_missing_release',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [child, cond], body: [
          Retain(object: child),
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Release(object: child),
          Return(value: null),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Return(value: null), // no release on this path
        ]),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 1,
        reason: 'deleting the retain would strand the release-less path unbalanced');
    expect(all.whereType<Release>().length, 1);
  });

  test('rule F: refuses when the retain does NOT dominate the frontier release', () {
    // Retain in one arm, release in the merge block reachable from BOTH
    // arms: the other arm would lose a release it needs.
    final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(1), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_dominance',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [v, cond], body: [
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Retain(object: v),
          Branch(target: BlockId(2), args: const []),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Release(object: v),
          Return(value: null),
        ]),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 1);
    expect(all.whereType<Release>().length, 1,
        reason: 'the release executes on the arm that never retained; it must survive');
  });

  test(
      'rule F-loops (ADR-0068): an ARC-free interior loop between the retain '
      'and its frontier release elides (the loaderNextBatch shape)', () {
    // THIS TEST INVERTED ON PURPOSE. Under ADR-0066 it asserted that ANY
    // back edge refused the whole function, and this exact shape -- retain
    // in the entry block, an ARC-free loop in the middle, release in the
    // single exit -- was the recorded cost (GAP-0067 item 2, NEON's
    // loaderNextBatch). ADR-0068 accepts it: the retain's block and the
    // frontier block are on no cycle (each executes at most once per call),
    // and the walk fully scanned the loop body, proving that what executes
    // N times contains no release, no opaque op, and no Retain v -- so the
    // deleted interval still performs no decrement, per ADR-0063's
    // invariant.
    final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(1), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_interior_loop',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [v, cond], body: [
          Retain(object: v),
          Branch(target: BlockId(1), args: const []),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1), // ARC-free loop: safe to walk through
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Release(object: v),
          Return(value: null),
        ]),
      ],
    );

    final stats = ElisionStats();
    final elided = elideRedundantRetainReleasePairs(function, stats);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 0);
    expect(all.whereType<Release>().length, 0);
    expect(stats.crossBlockElided, 1);
  });

  test(
      'rule F-loops: refuses a retain INSIDE a loop body pairing with a '
      'release outside it (cross-iteration escape)', () {
    // The retain's block is on a cycle: N executions of the retain against
    // one execution of the release. Cancelling would under-release by N-1.
    final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(1), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_retain_in_loop',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [v, cond], body: [
          Branch(target: BlockId(1), args: const []),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Retain(object: v), // executes once per iteration
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Release(object: v), // executes once per call
          Return(value: null),
        ]),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 1,
        reason: 'a retain on a cycle must never cross-block pair');
    expect(all.whereType<Release>().length, 1);
  });

  test(
      'rule F-loops: refuses a frontier release INSIDE a loop body '
      '(one retain against N executions of the release)', () {
    final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(1), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_release_in_loop',
      paramTypes: const [DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [v, cond], body: [
          Retain(object: v), // executes once per call
          Branch(target: BlockId(1), args: const []),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Release(object: v), // executes once per ITERATION
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Return(value: null),
        ]),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 1,
        reason: 'a release on a cycle must never join a frontier');
    expect(all.whereType<Release>().length, 1);
  });

  test(
      'rule F-loops: refuses when the interior loop contains a surviving '
      'release of ANOTHER value (loop-carried alias)', () {
    // The loop body releases w each iteration. w could alias v\'s object
    // (ADR-0063/GAP-0054: two DCValues, same object), so the interval is
    // not decrement-free and the pair must survive. The walk scans the loop
    // body and fails on the opaque release -- the refusal needs no separate
    // loop-specific rule, which is the point of walking rather than
    // skipping interior loops.
    final v = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final w = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(2), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_loop_alias',
      paramTypes: const [
        DCHeapPointer(DCVoid()),
        DCHeapPointer(DCVoid()),
        DCBool(),
      ],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [v, w, cond], body: [
          Retain(object: v),
          Branch(target: BlockId(1), args: const []),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Release(object: w), // surviving release of a maybe-alias
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Release(object: v),
          Return(value: null),
        ]),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final all = [for (final b in elided.blocks) ...b.body];
    expect(all.whereType<Retain>().length, 1,
        reason: 'an aliasing release inside the interval must block the pair');
    expect(all.whereType<Release>().length, 2);
  });

  test('rule F: two pairs sharing an exit block both elide -- a claimed release does not '
      'block the later walk (the json/tree walk shape)', () {
    // b0: retain v18; branch either way to b1 or b2, both to b3.
    // b3: Release v18; Release v27; Return. The v18 pair claims the first
    // release; the v27 pair (retained in b1... here b0 for simplicity of
    // dominance) must then walk PAST the claimed release, which never
    // executes.
    final a = DCValue(ValueId(0), const DCHeapPointer(DCVoid()));
    final b = DCValue(ValueId(1), const DCHeapPointer(DCVoid()));
    final cond = DCValue(ValueId(2), const DCBool());

    final function = DCFunction(
      linkName: 'test_frontier_shared_exit',
      paramTypes: const [DCHeapPointer(DCVoid()), DCHeapPointer(DCVoid()), DCBool()],
      returnType: const DCVoid(),
      mode: DCMode.bare,
      blocks: [
        DCBasicBlock(id: BlockId(0), params: [a, b, cond], body: [
          Retain(object: a),
          Retain(object: b),
          CondBranch(
            cond: cond,
            trueTarget: BlockId(1),
            trueArgs: const [],
            falseTarget: BlockId(2),
            falseArgs: const [],
          ),
        ]),
        DCBasicBlock(id: BlockId(1), params: const [], body: [
          Branch(target: BlockId(3), args: const []),
        ]),
        DCBasicBlock(id: BlockId(2), params: const [], body: [
          Branch(target: BlockId(3), args: const []),
        ]),
        DCBasicBlock(id: BlockId(3), params: const [], body: [
          Release(object: a),
          Release(object: b), // reachable only past the (claimed) release of a
          Return(value: null),
        ]),
      ],
    );

    final stats = ElisionStats();
    final elided = elideRedundantRetainReleasePairs(function, stats);
    final all = [for (final b2 in elided.blocks) ...b2.body];
    expect(all.whereType<Retain>().length, 0, reason: 'both pairs must cancel');
    expect(all.whereType<Release>().length, 0);
    expect(stats.crossBlockElided, 2);
  });
}
