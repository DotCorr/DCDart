// M2 target for NON-CAPTURING CLOSURES (docs/decisions/0057-non-capturing-
// closures.md).
//
// The deliberately narrow subset: a function expression or local function
// declaration that reads NO variable from an enclosing scope. Such a thing
// needs no environment, so it is not a closure at run time at all -- it is a
// static function that happened to be written inside another one, and it
// lowers to exactly that. No allocation, no function-pointer value, no call
// through a value.
//
// What is deliberately ABSENT and why it matters is recorded in
// docs/escalations/0008: a closure that CAPTURES needs an environment (and
// therefore an allocator this project does not have -- escalation 0002), and
// a closure passed as a VALUE needs a DC-IR indirect call that does not exist
// (GAP-0052). Neither is a lowering decision.
//
// `viaTopLevel`/`viaClosure` are the pair that carries the elision claim: two
// functions that differ ONLY in whether the consuming callee is written at
// top level or inside the body. Their ARC instruction counts must be
// IDENTICAL, because a non-capturing closure call is a direct call to a
// statically known callee, so `Call.argOwnership` is exact and dc-elide sees
// no difference. That is the property escalation 0008 says is LOST as soon as
// closures become values, and it is asserted here while it still holds.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

// ---------------------------------------------------------------------------
// Shape 1 -- a named local function (Kernel: FunctionDeclaration, called via
// LocalFunctionInvocation). Two call sites, one hoisted symbol.
// ---------------------------------------------------------------------------
@bare
u64 twiceSum(u64 a, u64 b) {
  u64 dbl(u64 v) => v + v;
  return dbl(a) + dbl(b);
}

// ---------------------------------------------------------------------------
// Shape 2 -- an anonymous function expression bound to a final local (Kernel:
// FunctionExpression, called via FunctionInvocation on a VariableGet).
// ---------------------------------------------------------------------------
@bare
u64 addThree(u64 x) {
  final f = (u64 v) => v + u64(3);
  return f(x);
}

// ---------------------------------------------------------------------------
// Shape 3 -- a block-bodied function expression with real control flow inside,
// proving the hoisted body goes through the ordinary statement lowerer rather
// than some reduced expression-only path.
// ---------------------------------------------------------------------------
@bare
u64 clampTo(u64 x, u64 hi) {
  final f = (u64 v, u64 h) {
    if (v > h) {
      return h;
    }
    return v;
  };
  return f(x, hi);
}

// ---------------------------------------------------------------------------
// Shape 4 -- SELF-RECURSION. The local function references its own name, which
// is a reference to an enclosing-scope variable and would be rejected as a
// capture by a naive free-variable check. It is not a capture: the name
// resolves to a static symbol.
// ---------------------------------------------------------------------------
@bare
u64 factorial(u64 n) {
  u64 go(u64 k) {
    if (k < u64(2)) {
      return u64(1);
    }
    return k * go(k - u64(1));
  }
  return go(n);
}

// ---------------------------------------------------------------------------
// Shape 5 -- one local function calling an EARLIER SIBLING. Same reasoning as
// shape 4, across two declarations rather than one.
// ---------------------------------------------------------------------------
@bare
u64 pipeline(u64 x) {
  u64 inc(u64 v) => v + u64(1);
  u64 incTwice(u64 v) => inc(inc(v));
  return incTwice(x);
}

// ---------------------------------------------------------------------------
// Shape 6 -- the ARC/elision pair. `viaTopLevel` and `viaClosure` are the same
// program written two ways; `dropTop` and `viaClosure`'s `dropLocal` are the
// same consuming callee written two ways.
// ---------------------------------------------------------------------------
@bare
u64 dropTop(@owned Box b) => b.value;

@bare
u64 viaTopLevel(u64 v) {
  final b = Box(v);
  return dropTop(b);
}

@bare
u64 viaClosure(u64 v) {
  u64 dropLocal(@owned Box b) => b.value;
  final b = Box(v);
  return dropLocal(b);
}

// ---------------------------------------------------------------------------
// Shape 7 -- the OTHER ARC direction: a local function that CONSTRUCTS a heap
// object and returns it. Ownership transfers out of it unreleased by
// ADR-0019's convention, exactly as from a top-level function. If the call
// were not recognized as a fresh-ownership source, the binding below would
// retain a reference nobody else holds and leak one arena slot per call --
// which the 500-iteration loop in main.c would catch immediately.
// ---------------------------------------------------------------------------
@bare
Box makeBoxTop(u64 x) => Box(x);

@bare
u64 makeViaTopLevel(u64 v) {
  final b = makeBoxTop(v);
  return dropTop(b);
}

@bare
u64 makeViaClosure(u64 v) {
  Box mk(u64 x) => Box(x);
  final b = mk(v);
  return dropTop(b);
}
