// M2 slice: real function-to-function calls (docs/decisions/0018-function-
// calls.md, docs/known-gaps.md GAP-0018). Before this, every conformance
// target (M0 through M2's alias slice) was a single leaf function -- there
// was no DC-IR instruction, and no dcc-lower recognition, for calling one
// @bare function from another at all.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
u64 doubleValue(u64 x) {
  return x + x;
}

/// Calls doubleValue from a plain local (`_lowerStatement`'s
/// VariableDeclaration path, not just `_lowerReturn`'s).
@bare
u64 addAndDouble(u64 a, u64 b) {
  final sum = a + b;
  return doubleValue(sum);
}

@bare
Result checkPositive(u64 x) {
  if (x < u64(1)) {
    return Result.err(u64(999));
  }
  return Result.ok(x);
}

/// Composes a function call with `.propagate()` (ADR-0014) -- proves the
/// two features work together with no new mechanism needed: `_lowerExpression`
/// already handles a StaticInvocation call as any other expression, so
/// `.propagate()`'s receiver being a call site instead of a local variable
/// needed zero additional code.
@bare
Result validateAndDouble(u64 x) {
  final checked = checkPositive(x).propagate();
  return Result.ok(doubleValue(checked));
}
