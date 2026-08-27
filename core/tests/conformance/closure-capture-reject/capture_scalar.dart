// NEGATIVE fixture: a local function CAPTURING a scalar must be REJECTED
// (ADR-0057 / escalation 0008 §2 — the capture convention is undecided).
// If this file ever compiles, capture has landed: see run.sh for what must
// happen next (it is not "delete this test").
import '../../../runtime/dc-core-bare/prelude.dart';

@bare
u64 captureScalar(u64 x) {
  final k = x + u64(1);
  u64 addK(u64 v) => v + k; // <- captures k from the enclosing scope
  return addK(x);
}
