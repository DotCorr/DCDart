// NEGATIVE fixture: a local function CAPTURING a heap object must be
// REJECTED (ADR-0057 / escalation 0008 §2 — capturing a heap reference is
// precisely the ARC-convention question rule 4 says a human decides).
import '../../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

@bare
u64 captureHeap(u64 x) {
  final b = Box(x);
  u64 readB(u64 v) => v + b.value; // <- captures b from the enclosing scope
  return readB(x);
}
