// core/bench/benchmarks/collatz/bench.dart
//
// Sum of Collatz step counts for 1..N. A data-dependent inner loop with a
// parity branch -- unvectorizable and unfoldable on both sides, which is the
// property that makes it a fair loop benchmark rather than a compiler
// constant-folding contest.
//
// Zero heap objects, so zero ARC: this is a SELF-TEST, see manifest.sh.
import '../../../runtime/dc-core-bare/prelude.dart';

@bare
u64 collatzSteps(u64 start) {
  var n = start;
  var steps = u64(0);
  while (u64(1) < n) {
    if ((n & u64(1)) < u64(1)) {
      n = n >> u64(1); // even: n / 2
    } else {
      n = n + n + n + u64(1); // odd: 3n + 1
    }
    steps = steps + u64(1);
  }
  return steps;
}

@bare
u64 benchKernel(u64 arg) {
  var total = u64(0);
  var i = u64(1);
  while (i < arg + u64(1)) {
    total = total + collatzSteps(i);
    i = i + u64(1);
  }
  return total;
}
