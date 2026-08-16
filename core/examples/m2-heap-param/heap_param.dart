// M2 slice: heap-typed function parameters and return types
// (docs/decisions/0019-heap-typed-signatures.md, docs/known-gaps.md
// GAP-0017). Unblocked by Call existing at all (ADR-0018) -- before that,
// there was nowhere to even use a heap-typed parameter.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

/// A BORROWED heap-typed parameter -- per ADR-0018/0019's ownership
/// convention, `readBoxValue` does not Retain on entry and does not
/// Release `b` before returning (parameters are never added to
/// `_heapLocals`, since they're bound directly in `lower()`, not via
/// `_lowerStatement`'s VariableDeclaration path that alias tracking uses).
@bare
u64 readBoxValue(Box b) {
  return b.value;
}

/// Constructs `b` locally and calls the borrowed-parameter function above.
/// `b`'s own lifecycle is untouched by the borrowed call -- it's released
/// normally (ADR-0016) when this function returns, same as if it had never
/// been passed anywhere. This is what makes the leak-check loop in main.c
/// safe to run unboundedly: nothing here holds a reference past this
/// function's own scope.
@bare
u64 makeAndReadViaCall(u64 v) {
  final b = Box(v);
  return readBoxValue(b);
}

/// A heap-typed RETURN type: ownership of the fresh object transfers
/// straight out to the caller, unreleased (same reasoning ADR-0016 already
/// established for a plain `return b;` -- the returned local is excepted
/// from the release loop). What's genuinely new here: DCDart source can
/// now WRITE a function signature that returns `Box`, not just a local
/// variable typed that way.
@bare
Box makeBox(u64 v) {
  final b = Box(v);
  return b;
}
