// M2 slice: Retain insertion at the first real ownership-transfer point --
// aliasing a heap local (`final b2 = b;`) -- docs/decisions/0017-heap-alias-
// retain.md. Before this slice, dcc-lower tracked heap locals by DCValue
// identity; aliasing produces the exact same DCValue for `b` and `b2` (dc-ir
// has no copy instruction), so both `b` and `b2` going out of scope would
// each try to Release the SAME object with no matching Retain -- a real
// double-release (docs/known-gaps.md GAP-0017's own "aliasing... isn't safe
// until this lands").
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

/// Straight-line aliasing: both `b` and `b2` go out of scope at the same
/// `return`, neither is the returned value (the returned value is a plain
/// u64 field read) -- both must be released, netting to exactly one free.
@bare
u64 makeAliasAndReadValue(u64 v) {
  final b = Box(v);
  final b2 = b;
  return b2.value;
}

/// Aliasing inside one `if` branch only, to prove the naive release policy's
/// per-branch scoping (docs/decisions/0016) and the new alias Retain compose
/// correctly: the then-branch's `b2` alias must be retained/released without
/// disturbing the outer `b`, and the else-branch (which never sees `b2` at
/// all) must still release `b` exactly once.
@bare
u64 makeAliasBranch(u64 v) {
  final b = Box(v);
  if (v < u64(500)) {
    final b2 = b;
    return b2.value;
  } else {
    return b.value;
  }
}
