// M2 slice: scalar local variable reassignment (docs/decisions/0027-
// scalar-reassignment.md). Half of what a real `while`/`for` loop needs
// as a prerequisite (the other half, new DC-IR control flow, is separate
// and not attempted here) -- docs/known-gaps.md GAP-0017 item 6.
//
// Heap-/weak-typed reassignment is deliberately NOT supported here (see
// the ADR) -- only scalar (`u8`/`u32`/`u64`) locals.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
u64 mutateStraightLine(u64 v) {
  var x = v;
  x = x + u64(1);
  x = x + u64(1);
  return x;
}

/// Reassignment scoped to a branch that terminates -- proves this
/// composes correctly with the existing if-branch machinery (ADR-0014),
/// which already requires every written branch to end in a `return`
/// (GAP-0007), meaning there is no "conditionally reassign, then fall
/// through with an ambiguous merged value" shape reachable here.
@bare
u64 mutateInBranch(u64 v) {
  var x = v;
  if (v < u64(10)) {
    x = x + u64(100);
    return x;
  }
  return x;
}
