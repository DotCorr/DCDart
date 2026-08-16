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

  test('does NOT remove a Retain/Release pair spanning a Call', () {
    // Mirrors core/examples/m2-owned/owned.dart's makeAndDropViaCall: the
    // caller retains before passing to an @owned parameter, then releases
    // its own local at return. The Call in between is opaque -- the
    // callee's own Release (in a different function entirely) is
    // load-bearing, so this pair must NOT be touched.
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
            Call(dest: callResult, targetName: 'someOwnedConsumer', args: [heapPtr]),
            Release(object: heapPtr),
            Return(value: callResult),
          ],
        ),
      ],
    );

    final elided = elideRedundantRetainReleasePairs(function);
    final body = elided.blocks.single.body;

    expect(body.whereType<Retain>().length, 1, reason: 'a retain spanning a Call must survive');
    expect(body.whereType<Release>().length, 1, reason: 'its matching release must survive too');
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
}
