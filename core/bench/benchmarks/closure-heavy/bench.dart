// core/bench/benchmarks/closure-heavy/bench.dart
//
// M3 benchmark 5 of 5: a closure-heavy functional workload. THE LAST ONE.
//
// WHAT "CLOSURE" MEANS IN DCDART TODAY, because the honest name for this
// benchmark's shape decides what it measures. A CAPTURING closure is still
// rejected at compile time (probed 2026-08-27; escalation 0008 §2 is open,
// the capture convention is a rule-4 memory-model decision nobody has made).
// What ADR-0060 landed is the other half: a function is a VALUE -- torn off,
// passed, returned, called through the value (`DCFuncPtr`, `IndirectCall`,
// GAP-0052 closed). So a DCDart "closure" today is what a closure compiles
// TO everywhere else: a code pointer paired with an explicit environment
// object. This benchmark allocates that environment on the heap per stage,
// exactly where a capturing closure's environment would live, and reaches
// every stage through a run-time-selected function pointer. When capture
// lands, this file should be rewritten in capture syntax and re-measured;
// until then this is the closure-heavy workload the language can express,
// not a stand-in for a different one.
//
// THE SHAPE: a pipeline of three composed stages over a rolling state, plus
// a one-item window of the previous stage environment.
//
//   * per ROUND: one `Gain` heap object -- the analog of a heap object
//     CAPTURED by many closures. Two of the three stage environments hold a
//     reference to it, so it is retained/released through every environment's
//     lifetime and dies only when the round's last environment does.
//   * per ITEM: three `Env` heap objects allocated (closure-allocation
//     churn), three stage functions SELECTED FROM DATA BITS (so no
//     devirtualization is possible on either side), the pipeline applied
//     through a higher-order `applyStage` (every stage call is a genuine
//     indirect call through a value), and the newest environment KEPT ALIVE
//     into the next item (`prev`) and applied there -- a closure outliving
//     the expression that made it, which is the lifetime shape that
//     distinguishes closures from plain calls.
//   * SERIAL DEPENDENCY: each item's output is the next item's input, so no
//     reordering or batching can overlap the pipeline with itself.
//
// WHAT IT PRICES. Per item: 3 small-object allocations and releases (the
// 64-byte size class, same as `Env`'s 40-byte payload + 16-byte header
// rounded up), retain/release traffic on the shared `Gain` as environments
// are built and dropped, one heap-reference reassignment (`prev = e3`,
// ADR-0048: retain + release per item), and ~4 indirect calls. The C side
// (kernel.c) does the same arithmetic through the same function pointers but
// keeps its environments ON THE STACK, because that is C's natural idiom for
// non-escaping closure contexts -- so the measured gap IS the cost of DCDart
// heap-allocating and refcounting environments, which is what a gate about
// ARC on a closure-heavy workload should price. See kernel.c's header for
// the fairness argument (ADR-0059).
//
// ARC NOTE. Heap-typed parameters are BORROWED (ADR-0019) and a `DCFuncPtr`
// created from these stage functions carries the all-borrowed convention in
// its type (ADR-0060, GAP-0057) -- which is also the only convention a Dart
// function TYPE can spell. The borrowed pairs that span each indirect call
// are load-bearing and SURVIVE elision (funcptr conformance shape 5), so
// this benchmark deliberately measures ARC traffic elision cannot remove.
//
// OVERFLOW. Arithmetic traps and there are no wrapping operators, so every
// intermediate is kept provably below 2^64: pipeline values are < 2^31
// (folded % 1000000007 at each stage), env fields are < 1000003 or < 2^31,
// and the one multiply is (v % 1000003) * small-constant, far under 2^52.
import '../../../runtime/dc-core-bare/prelude.dart';

/// The shared heap object two of the three stage environments reference --
/// the "captured heap object" of the workload. One per round; its refcount
/// moves on every environment build and drop that involves it.
class Gain extends HeapObject {
  final u64 value;
  Gain(this.value);
}

/// A stage's environment: what a capturing closure would have captured.
/// Two scalars (capture-by-value) and an optional reference to the round's
/// [Gain] (capture-of-heap-object). 40-byte payload + 16-byte header ->
/// the 64-byte size class (ADR-0058).
class Env extends HeapObject {
  final u64 a;
  final u64 b;
  final Gain? g;
  Env(this.a, this.b, this.g);
}

/// Stage: add the captured scalar. All stages fold with the same modulus so
/// every stage's output is < 2^31 whatever order they compose in.
@bare u64 stAdd(Env e, u64 v) {
  return (v + e.a + e.b) % u64(1000000007);
}

/// Stage: multiply-fold. `v % 1000003` is under 2^20 and `e.a` is under
/// 1000003, so the product is under 2^40 -- no trap reachable.
@bare u64 stMulFold(Env e, u64 v) {
  final m = v % u64(1000003);
  return (m * (e.a % u64(1000003)) + e.b) % u64(1000000007);
}

/// Stage: xor/shift mix of the value with both captured scalars.
@bare u64 stMix(Env e, u64 v) {
  return ((v ^ e.a) + (v >> u64(7)) + e.b) % u64(1000000007);
}

/// Stage: read through the captured HEAP object. The null arm exists because
/// the function type can be picked for an environment built without a Gain;
/// its result stays on the same modular lattice.
@bare u64 stGain(Env e, u64 v) {
  final g = e.g;
  if (g != null) {
    return (v + g.value + e.a) % u64(1000000007);
  }
  return (v + e.b) % u64(1000000007);
}

/// Run-time stage selection: a function pointer RETURNED from a function,
/// chosen by data bits. This is the shape no optimizer can devirtualize --
/// the funcptr conformance target's `dispatch` -- and both sides of the
/// benchmark select from the same bits.
@bare u64 Function(Env, u64) pickStage(u64 sel) {
  if (sel == u64(0)) {
    return stAdd;
  }
  if (sel == u64(1)) {
    return stMulFold;
  }
  if (sel == u64(2)) {
    return stMix;
  }
  return stGain;
}

/// The higher-order call: a function-pointer PARAMETER invoked through the
/// value. Every stage application in the kernel goes through here, so every
/// stage call is an indirect call, on both sides.
@bare u64 applyStage(u64 Function(Env, u64) f, Env e, u64 x) {
  return f(e, x);
}

/// Three stages composed by value: the pipeline. The function pointers and
/// environments arrive as values and are applied innermost-first.
@bare u64 pipeline3(
    u64 Function(Env, u64) f1, Env e1,
    u64 Function(Env, u64) f2, Env e2,
    u64 Function(Env, u64) f3, Env e3,
    u64 x) {
  return applyStage(f3, e3, applyStage(f2, e2, applyStage(f1, e1, x)));
}

/// [rounds] rounds of 1024 items. Per round one shared [Gain]; per item
/// three fresh environments, a data-selected three-stage pipeline, and the
/// previous item's third environment applied once more (the one-item
/// rolling window) before it is dropped by the `prev` reassignment.
@bare u64 benchKernel(u64 rounds) {
  var acc = u64(0);
  var x = u64(123456791);
  var r = u64(0);
  while (r < rounds) {
    final g = Gain((r * u64(2654435761)) % u64(1000003));
    Env? prev = null;
    var i = u64(0);
    while (i < u64(1024)) {
      final s1 = (x ^ i) % u64(4);
      final s2 = (x >> u64(3)) % u64(4);
      final s3 = (x >> u64(6)) % u64(4);
      final e1 = Env(x % u64(1000003), i % u64(1000003), null);
      final e2 = Env((x + i) % u64(1000003), r % u64(1000003), g);
      final e3 = Env((x + r) % u64(1000003), i, g);
      x = pipeline3(pickStage(s1), e1, pickStage(s2), e2, pickStage(s3), e3, x);
      final p = prev;
      if (p != null) {
        x = applyStage(pickStage((x >> u64(9)) % u64(4)), p, x);
      }
      prev = e3;
      acc = (acc + x) % u64(1000000007);
      i = i + u64(1);
    }
    r = r + u64(1);
  }
  return acc;
}
