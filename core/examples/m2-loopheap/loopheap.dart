// M2 target for HEAP-TYPED LOCALS DECLARED IN A LOOP BODY -- the
// per-iteration ARC release policy.
//
// Until this target existed, `dcc-lower` REFUSED every function below with
//
//   "a heap- or weak-typed local was declared inside a while-loop body --
//    not supported yet (naive ARC has no release policy for a loop back
//    edge yet)"
//
// and the refusal was correct for the policy it guarded. ADR-0016/0017's
// naive scheme releases tracked locals only before a `return`. A loop's back
// edge is not a `return`, so `final node = Node(i);` inside a body allocated
// a FRESH object every iteration and released at most one of them. That is
// one leaked object per iteration -- against the fixed 64-slot arena of the
// day (ADR-0015, since superseded by ADR-0058's segregated size-class heap)
// that was a SIGTRAP at iteration 65, not a slow leak. Refusing beat
// shipping that.
//
// What the refusal protected is now provided: a body-scoped heap local is
// released on every path that leaves the body -- fall-through, `continue`,
// `break`, and `return`. The functions here exist one per path, because
// "released somewhere" is not the property that matters. Releasing on the
// wrong path is a use-after-free and releasing on no path is the trap above,
// and only a per-path target can tell those apart.
//
// The runtime proof is in main.c: 1000 iterations per call, with
// `dc_heap_live` -- the allocator's live-object count (ADR-0058) -- checked
// back at its baseline after every call. That check, not the old arena's
// trap-on-exhaustion, is what makes a per-iteration leak visible now; it is
// the stronger form, because it also catches a leak small enough to have
// fitted.
import '../../runtime/dc-core-bare/prelude.dart';

class Node extends HeapObject {
  final u64 value;
  const Node(this.value);
}

/// FALL-THROUGH. The exact shape the refusal named: a heap-typed local
/// declared in a `while` body, one fresh object per iteration, released at
/// the end of each one before the back edge overwrites the variable.
///
/// Returns 0 + 1 + ... + (n-1).
@bare
u64 liveChain(u64 n) {
  var i = u64(0);
  var total = u64(0);
  while (i < n) {
    final node = Node(i);
    total = total + node.value;
    i = i + u64(1);
  }
  return total;
}

/// The same, as a `for` loop. Not redundant with `liveChain`: ADR-0050 gives
/// the update clause its OWN block, so the release sits between the body and
/// the update rather than on the back edge itself. The update clause is
/// scalar and cannot name a body-scoped local (Dart scoping), so that order
/// is the correct one -- asserted here rather than assumed.
///
/// Returns 0 + 1 + ... + (n-1).
@bare
u64 forChain(u64 n) {
  var total = u64(0);
  for (var i = u64(0); i < n; i = i + u64(1)) {
    final node = Node(i);
    total = total + node.value;
  }
  return total;
}

/// CONTINUE, the path with the worst failure mode. `continue` branches
/// straight out of the body, so a release appended to the end of the body
/// would be SKIPPED on exactly the iterations that took it -- a leak on half
/// the iterations, which still traps, just later. ADR-0050 also requires
/// `continue` to run the update clause before re-testing; if this hangs
/// rather than fails, that is what broke.
///
/// Allocates on EVERY iteration and skips only the accumulate, so odd
/// iterations are the ones whose object is released on the `continue` edge.
/// Returns the sum of the even values below n.
@bare
u64 withContinue(u64 n) {
  var total = u64(0);
  for (var i = u64(0); i < n; i = i + u64(1)) {
    final node = Node(i);
    if ((node.value & u64(1)) > u64(0)) {
      continue;
    }
    total = total + node.value;
  }
  return total;
}

/// BREAK. Leaves the body for good, so the object of the iteration that
/// broke is the one nothing else would ever release.
///
/// Returns the sum of values strictly below `stop`, or below n if `stop` is
/// never reached.
@bare
u64 withBreak(u64 n, u64 stop) {
  var i = u64(0);
  var total = u64(0);
  while (i < n) {
    final node = Node(i);
    if (node.value == stop) {
      break;
    }
    total = total + node.value;
    i = i + u64(1);
  }
  return total;
}

/// RETURN out of the body. Claimed to be already handled by `_lowerReturn`'s
/// whole-stack release rather than needing new code -- which is exactly the
/// kind of claim that is worth a target rather than a sentence.
///
/// Returns 1000 + the sum below `stop` when `stop` is reached, else the sum
/// below n.
@bare
u64 withReturn(u64 n, u64 stop) {
  var i = u64(0);
  var total = u64(0);
  while (i < n) {
    final node = Node(i);
    if (node.value == stop) {
      return total + u64(1000);
    }
    total = total + node.value;
    i = i + u64(1);
  }
  return total;
}

/// NESTED. The inner body's local must be released per INNER iteration while
/// the outer body's stays live across the whole inner loop -- an unwind that
/// released to the wrong depth would either free `outer` n times or leak the
/// inner objects. Peak live objects is 2, whatever n is.
///
/// Returns n * (sum of 0..n-1) * 2.
@bare
u64 nested(u64 n) {
  var total = u64(0);
  for (var i = u64(0); i < n; i = i + u64(1)) {
    final outer = Node(i);
    for (var j = u64(0); j < n; j = j + u64(1)) {
      final inner = Node(j);
      total = total + outer.value + inner.value;
    }
  }
  return total;
}

/// The object is not merely allocated and dropped: it is handed to a
/// loop-carried variable that OUTLIVES the iteration. `keep = node` retains
/// (ADR-0048) and releases the previous head; the per-iteration release then
/// drops the local's own reference. One release too many here frees a live
/// object and `lastKept` reads freed memory; one too few leaks and traps.
///
/// Returns the last value kept, i.e. n-1, or 777 for n == 0.
@bare
u64 lastKept(u64 n) {
  Node? keep = null;
  var i = u64(0);
  while (i < n) {
    final node = Node(i);
    keep = node;
    i = i + u64(1);
  }
  if (keep == null) {
    return u64(777);
  }
  return keep.value;
}
