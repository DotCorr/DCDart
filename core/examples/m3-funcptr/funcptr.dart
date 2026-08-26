// M3 target for FUNCTION POINTERS and INDIRECT CALLS
// (docs/decisions/0060-function-pointers-and-indirect-calls.md).
//
// ADR-0057 landed non-capturing closures by hoisting each local function to a
// top-level symbol and calling it DIRECTLY. That is not what a functional
// workload is made of: `map`, `filter` and `fold` all take a function as an
// ARGUMENT, which means a call through a value, which DC-IR could not express
// at all -- no function-pointer type, no indirect call (GAP-0052).
//
// THE POINT OF THIS FILE IS THE ARC COUNTS, not the arithmetic.
//
// docs/escalations/0008 §3 predicted that an indirect call must be an ELISION
// BARRIER: `Call.argOwnership` is computed from the callee's declaration, and
// through a value there is no declaration, so ownership is "not conservatively
// derivable -- it is not derivable at all". Assuming "borrowed" keeps every
// retain/release pair across every closure invocation, and the M3 benchmark
// that most exercises closures is then the one measuring unelided ARC.
//
// ADR-0060 answers that by putting ownership in the POINTER'S TYPE. The
// pointer is created from a named function, where the `@owned` annotations are
// in plain sight, so `DCFuncPtr` records the convention exactly and every
// later use carries it. `viaTopLevel` / `viaClosure` / `viaFuncPtr` below are
// the SAME PROGRAM written three ways -- consuming callee at top level, inside
// the body, and reached through a function pointer -- and `run.sh` asserts all
// three emit `alloc=1 retain=0 release=0`. The third one is the claim.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

// ---------------------------------------------------------------------------
// Shape 1 -- a HIGHER-ORDER function: a function-pointer PARAMETER, called
// through the value. The thing ADR-0057 explicitly could not do.
// ---------------------------------------------------------------------------
@bare
u64 dbl(u64 v) => v + v;

@bare
u64 inc(u64 v) => v + u64(1);

@bare
u64 applyTwice(u64 Function(u64) f, u64 x) => f(f(x));

@bare
u64 dblTwice(u64 x) => applyTwice(dbl, x);

@bare
u64 incTwice(u64 x) => applyTwice(inc, x);

// ---------------------------------------------------------------------------
// Shape 2 -- a LOCAL function torn off into a value and called through it.
// Both halves are new: ADR-0057 rejected a local function's name in value
// position outright ("there is nothing for that value to be").
// ---------------------------------------------------------------------------
@bare
u64 localTearOff(u64 x) {
  u64 triple(u64 v) => v + v + v;
  final f = triple;
  return f(x);
}

// ---------------------------------------------------------------------------
// Shape 3 -- a function pointer as a RETURN value, selected at run time. This
// is the shape that cannot be devirtualized away by the optimizer within one
// function, so the emitted object really does contain an indirect branch.
// ---------------------------------------------------------------------------
@bare
u64 Function(u64) chooser(u64 which) {
  if (which == u64(0)) {
    return dbl;
  }
  return inc;
}

@bare
u64 dispatch(u64 which, u64 x) {
  final f = chooser(which);
  return f(x);
}

// ---------------------------------------------------------------------------
// Shape 4 -- THE ELISION TRIPLE. Same program, three spellings of how the
// `@owned`-consuming callee is reached.
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

// The one that matters. `f` is a function POINTER; the callee is not a symbol
// at this call site. It must still emit `alloc=1 retain=0 release=0`.
@bare
u64 viaFuncPtr(u64 v) {
  u64 dropLocal(@owned Box b) => b.value;
  final f = dropLocal;
  final b = Box(v);
  return f(b);
}

// And the same through a tear-off of a TOP-LEVEL consuming function, so the
// property is not an artifact of hoisting.
@bare
u64 viaTopFuncPtr(u64 v) {
  final f = dropTop;
  final b = Box(v);
  return f(b);
}

// ---------------------------------------------------------------------------
// Shape 5 -- the BORROWED direction through a pointer. The retain/release pair
// spanning this call is load-bearing (the callee does not consume), so it must
// SURVIVE -- an elision pass that dropped it here would be a use-after-free.
// The counts asserted in run.sh check both directions, not just the good news.
// ---------------------------------------------------------------------------
@bare
u64 readBox(Box b) => b.value;

@bare
u64 borrowViaFuncPtr(u64 v) {
  final f = readBox;
  final b = Box(v);
  final alias = b;
  return f(alias);
}

// ---------------------------------------------------------------------------
// Shape 6 -- a VOID callback invoked for effect through a pointer, in
// statement position. The ordinary shape of a callback, and the one ADR-0057
// left unimplemented even for direct local calls.
// ---------------------------------------------------------------------------
// The explicit `return;` is NOT style. A `void` `@bare` function whose body
// falls off the end never releases its `@owned` heap parameters at all --
// found while writing this file, PRE-EXISTING and unrelated to function
// pointers (a direct `consume(b);` leaks identically), filed as GAP-0060.
// Written the working way here so this target measures indirect calls rather
// than that bug.
@bare
void consume(@owned Box b) {
  return;
}

@bare
u64 voidCallback(u64 v) {
  final f = consume;
  final b = Box(v);
  f(b);
  return v;
}
