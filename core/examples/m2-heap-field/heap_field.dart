// M2 slice: a HeapObject holding a reference to another HeapObject
// (docs/decisions/0020-heap-typed-fields.md, docs/known-gaps.md GAP-0017).
//
// IMPORTANT, read before copying this pattern: this conformance target
// deliberately demonstrates a REAL, EXPECTED LEAK, not a leak-free cycle.
// `BoxHolder`'s Release never cascades into releasing its own `inner`
// field (GAP-0003: no ClassInfo/destructor dispatch yet) -- every call to
// makeHolderAndReadInner below permanently loses exactly one arena slot
// (the inner Box's). The harness (main.c) asserts this EXACT, bounded leak
// rate rather than "leak-free", and stops well short of the 64-slot arena
// on purpose. See the ADR for why this is correct-per-current-scope, not a
// bug in the field-storage mechanism itself.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

class BoxHolder extends HeapObject {
  final Box inner;
  const BoxHolder(this.inner);
}

@bare
u64 makeHolderAndReadInner(u64 v) {
  final b = Box(v);
  final holder = BoxHolder(b);
  return holder.inner.value;
}
