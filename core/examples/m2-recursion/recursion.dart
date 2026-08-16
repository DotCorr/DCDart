// M2 slice: recursion (docs/decisions/0026-recursion.md). Explicitly
// flagged as untested in ADR-0018 ("Recursion is untested... though
// nothing in the design should prevent it"). Also the closest thing to
// "loops with heap locals" (docs/known-gaps.md GAP-0017 item 6) that
// currently-lowerable DCDart can express at all -- there is no
// WhileStatement/ForStatement support yet (item 6, corrected), but a
// self-recursive @bare function IS already fully supported by the
// existing Call mechanism (ADR-0018) with zero new lowering logic needed.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  final u64 value;
  const Box(this.value);
}

/// Sums 1+2+...+n. Each recursive call constructs its OWN Box (proving
/// the naive release policy, ADR-0016, correctly scopes a heap local to
/// its own stack frame across recursion -- exactly the way it already
/// scopes one to its own straight-line/branching function, just now
/// exercised across a self-call instead of a call to a different
/// function) and calls itself with `n - u64(1)` (needs the `-` operator
/// added alongside this target, ADR-0026 -- ISub already had real backend
/// codegen since M0, only the source-level operator was missing).
@bare
u64 sumBoxValues(u64 n) {
  if (n < u64(1)) {
    return u64(0);
  }
  final b = Box(n);
  final v = b.value;
  return v + sumBoxValues(n - u64(1));
}
