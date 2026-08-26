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
}
