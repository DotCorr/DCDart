// NEGATIVE fixture: a CAPTURING local function torn off as a VALUE must be
// REJECTED. ADR-0060 made non-capturing functions first-class (`FuncRef` /
// `IndirectCall`, GAP-0052 closed); this asserts that did NOT quietly extend
// to captured environments, which need an allocation and a capture
// convention (escalation 0008 §2) that do not exist.
import '../../../runtime/dc-core-bare/prelude.dart';

@bare
u64 applyIt(u64 Function(u64) f, u64 x) => f(x);

@bare
u64 captureAsValue(u64 x) {
  final k = x + u64(2);
  u64 addK(u64 v) => v + k; // <- captures k
  return applyIt(addK, x); // <- and is passed as a value
}
