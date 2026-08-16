// M2 slice: @owned parameters -- the consuming counterpart to ADR-0019's
// borrowed-by-default convention (docs/decisions/0021-owned-parameters.md,
// spec §3.2 item 2: "Function parameters default to borrowed... Only
// @owned params transfer."). This is what finally closes GAP-0017's last
// item: a full, genuinely UNBOUNDED alloc-then-free cycle for a heap
// pointer that crosses a function boundary -- every earlier M2 target
// (m2-heap-param's return test, m2-heap-field) had to stop at a bounded
// call count precisely because nothing could release a reference it
// didn't itself construct. @owned is that release mechanism.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

@bare
Box makeBox(u64 v) {
  final b = Box(v);
  return b;
}

/// Takes ownership of `b` -- releases it (via the same naive release
/// policy every tracked local gets, ADR-0016) after reading its value,
/// exactly like any other tracked heap local. The @owned annotation is
/// what makes this parameter get tracked in _heapLocals at all (default,
/// unannotated parameters are borrowed and never tracked, ADR-0019).
@bare
u64 dropBoxAndReadValue(@owned Box b) {
  return b.value;
}

/// Calls dropBoxAndReadValue while ALSO keeping its own local `b` alive
/// past the call -- proves the caller-side Retain (ADR-0021) is correct:
/// without it, this function's own release of its local `b` and the
/// callee's release of its owned parameter would double-release the same
/// object.
@bare
u64 makeAndDropViaCall(u64 v) {
  final b = makeBox(v);
  return dropBoxAndReadValue(b);
}
