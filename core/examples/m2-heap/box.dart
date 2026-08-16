// M2 exit criterion (ROADMAP.md): "allocation-heavy programs run leak-free
// under dc-test --leakcheck." First real proof: allocate a heap object,
// read a field, let it go out of scope -- the arena must return to
// baseline (docs/decisions/0015-m2-minimal-arc-arena.md,
// 0016-heap-object-field-access.md).
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

@bare
u64 makeBoxAndReadValue(u64 v) {
  final b = Box(v);
  return b.value;
}
