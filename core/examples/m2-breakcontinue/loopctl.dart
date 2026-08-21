// M2 target for `break` and `continue` (docs/decisions/0047-break-and-continue.md).
//
// Kernel spells BOTH as `BreakStatement`; they differ only in which
// `LabeledStatement` is targeted. A label wrapping the WHILE is `break` (jump
// past the loop); a label wrapping the loop's BODY is `continue` (jump to the
// header). Nothing else distinguishes them.
//
// The case that matters is `firstMatch`: the body ASSIGNS a loop variable and
// then breaks. Before this, the loop's exit block had no parameters -- correct
// only because the exit had exactly one predecessor -- so the value read after
// the loop would have been the one from before the body ran.
import '../../runtime/dc-core-bare/prelude.dart';

/// Assign-then-break. Reading `found` after the loop must see what the body
/// stored, not its pre-loop value.
@bare
u64 firstMatch(u64 n, u64 target) {
  var i = u64(0);
  var found = u64(999);
  while (i < n) {
    if (i == target) {
      found = i;
      break;
    }
    i = i + u64(1);
  }
  return found;
}

/// `continue` skipping odd values. Exercises the loop-carried analysis
/// through the body's LabeledStatement -- missing that case produced a loop
/// whose header never updated `i`, i.e. a silent hang.
@bare
u64 sumEvens(u64 n) {
  var i = u64(0);
  var sum = u64(0);
  while (i < n) {
    i = i + u64(1);
    if ((i & u64(1)) > u64(0)) {
      continue;
    }
    sum = sum + i;
  }
  return sum;
}

/// `break` out of an INNER loop only -- the outer must keep running.
@bare
u64 breakInner(u64 rows, u64 cols) {
  var r = u64(0);
  var hits = u64(0);
  while (r < rows) {
    var c = u64(0);
    while (c < cols) {
      if (c == u64(2)) {
        break;
      }
      hits = hits + u64(1);
      c = c + u64(1);
    }
    r = r + u64(1);
  }
  return hits;
}

/// `break` and `continue` in the same loop.
@bare
u64 bothInOne(u64 n) {
  var i = u64(0);
  var sum = u64(0);
  while (i < n) {
    i = i + u64(1);
    if (i == u64(7)) {
      break;
    }
    if ((i & u64(1)) > u64(0)) {
      continue;
    }
    sum = sum + i;
  }
  return sum;
}
