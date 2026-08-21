// M2 target for NESTED loops (docs/decisions/0044-nested-loops.md).
//
// ADR-0028 built `while` and explicitly refused to nest, on the grounds that
// the loop-carried-variable analysis would be "silently scoped to the wrong
// loop". The refusal turned out to be over-cautious -- the scoping safeguard
// already existed one level up -- but the cases below are exactly the ones
// that would break if it had not.
//
// Found by oscortex_core hitting it TWICE in one milestone, in two unrelated
// subsystems, by an agent that was not looking for it. Nested loops are how
// you walk a PCI bus, a page table or a framebuffer -- and how you write the
// JSON parser and tree traversal M3's benchmark suite asks for.
import '../../runtime/dc-core-bare/prelude.dart';

/// THE CASE THE OLD COMMENT WORRIED ABOUT: the inner loop assigns a variable
/// declared OUTSIDE the outer loop, so it is genuinely carried by both.
@bare
u64 innerWritesOuter(u64 rows, u64 cols) {
  var total = u64(0);
  var r = u64(0);
  while (r < rows) {
    var c = u64(0);
    while (c < cols) {
      total = total + r;   // assigns an OUTER-scope variable from the inner loop
      c = c + u64(1);
    }
    r = r + u64(1);
  }
  return total;
}

/// Triple nesting.
@bare
u64 triple(u64 n) {
  var count = u64(0);
  var i = u64(0);
  while (i < n) {
    var j = u64(0);
    while (j < n) {
      var k = u64(0);
      while (k < n) {
        count = count + u64(1);
        k = k + u64(1);
      }
      j = j + u64(1);
    }
    i = i + u64(1);
  }
  return count;
}

/// Nested loop with an if/else inside, and an early return out of both.
@bare
u64 findPair(u64 n, u64 target) {
  var i = u64(0);
  while (i < n) {
    var j = u64(0);
    while (j < n) {
      if (i * j == target) {
        return i * u64(100) + j;
      } else {
        j = j + u64(1);
      }
    }
    i = i + u64(1);
  }
  return u64(9999);
}
