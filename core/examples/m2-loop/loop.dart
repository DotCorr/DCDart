// M2 real-loop-control-flow target (docs/decisions/0028-while-loop.md).
// Pure scalar `while` loops -- no heap allocation, so no ARC interaction
// with the back edge (deliberately out of scope, see the ADR).
import '../../runtime/dc-core-bare/prelude.dart';

/// Sums 0 + 1 + ... + (n-1) via a straight-line `while` loop body -- the
/// baseline case: two loop-carried scalars (`i`, `total`), no nested
/// control flow inside the body.
@bare
u64 sumTo(u64 n) {
  var i = u64(0);
  var total = u64(0);
  while (i < n) {
    total = total + i;
    i = i + u64(1);
  }
  return total;
}

/// Same running sum, but returns the index `i` at which the running total
/// FIRST exceeds `threshold` (or `n` if it never does) -- exercises a
/// nested `if` (no `else`, guard-clause pattern) with an early `return`
/// INSIDE a loop body, composed with the loop's own back edge.
@bare
u64 firstAtLeast(u64 n, u64 threshold) {
  var i = u64(0);
  var total = u64(0);
  while (i < n) {
    total = total + i;
    if (threshold < total) {
      return i;
    }
    i = i + u64(1);
  }
  return i;
}
