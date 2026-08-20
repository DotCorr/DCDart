// A real, hands-on demo program -- not a narrow conformance target for one
// ADR, but an actual small algorithm exercising several DCDart features
// together: a heap object with real ARC (Alloc/Retain/Release happen
// automatically, nothing in this source manages them), a while loop,
// arithmetic, and the bitwise operators (ADR-0030) used for a real
// purpose (even/odd checks, halving via shift instead of division, which
// DCDart doesn't have yet).
import '../../runtime/dc-core-bare/prelude.dart';

class StepCounter extends HeapObject {
  u64 total;
  StepCounter(this.total);
}

/// How many Collatz steps (n -> n/2 if even, n -> 3n+1 if odd) it takes
/// `start` to reach 1. No `/` or `*` operator exists yet (neither has
/// been wired to a source-level operator this session) -- `n >> 1` is
/// exactly `n / 2` for an unsigned value, and `3 * n` is spelled
/// `n + n + n`, both using only already-verified operators.
@bare
u64 collatzSteps(u64 start) {
  var n = start;
  var steps = u64(0);
  while (u64(1) < n) {
    if ((n & u64(1)) < u64(1)) {
      n = n >> u64(1); // even
    } else {
      n = n + n + n + u64(1); // odd: 3n + 1
    }
    steps = steps + u64(1);
  }
  return steps;
}

/// Sums collatzSteps(1..upTo) into a real heap-allocated counter -- the
/// same StepCounter object is read and written on every iteration of the
/// loop, its single Alloc/Release happening once for the whole call, not
/// once per iteration.
@bare
u64 sumCollatzSteps(u64 upTo) {
  var counter = StepCounter(u64(0));
  var i = u64(1);
  while (i < upTo) {
    counter.total = counter.total + collatzSteps(i);
    i = i + u64(1);
  }
  return counter.total;
}
