// M2 slice: weak references (DCDART_SPEC.md §3.3 layer 1,
// docs/decisions/0023-weak-references.md). Made tractable by ADR-0022's
// destructor cascade -- a "target death" event a weak reference can
// actually observe now exists.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

@bare
u64 dropBox(@owned Box b) {
  return b.value;
}

/// Constructs a Box, makes a weak reference to it, then returns the weak
/// reference. `b` is not the returned value, so the naive release policy
/// (ADR-0016) releases it right here, before this function even returns
/// -- by the time the caller has `w`, the Box is already dead. This is
/// the ONLY way to force early death with the primitives built so far
/// (no move semantics, no explicit "drop" statement) -- see the ADR.
@bare
Weak<Box> makeDanglingWeak(u64 v) {
  final b = Box(v);
  final w = Weak<Box>.fromStrong(b);
  return w;
}

/// Reads a weak reference's target -- null (a null Box) if the target has
/// died. Consumes `w` itself (@owned): a weak reference's own lifecycle
/// is independent of what it points to, and this is the only place the
/// dangling weak ref from makeDanglingWeak ever gets dropped.
@bare
Box readWeak(@owned Weak<Box> w) {
  return w.value;
}

/// Constructs, makes a weak ref, and reads it back WHILE the target is
/// still alive -- all in one function, so nothing dies early. Proves the
/// "still alive" path of the exact same mechanism makeDanglingWeak/
/// readWeak prove nils out.
@bare
Box weakLoadWhileAlive(u64 v) {
  final b = Box(v);
  final w = Weak<Box>.fromStrong(b);
  return w.value;
}
