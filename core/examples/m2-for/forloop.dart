// M2 target for `for` loops (docs/decisions/0050-for-loops.md).
//
// Desugared to the `while` machinery rather than given their own lowering, so
// nesting (ADR-0044), break/continue (ADR-0047) and heap-typed locals
// (ADR-0048) all apply unchanged.
//
// `withContinue` is the case that matters. In Dart, `continue` inside a `for`
// must still RUN THE UPDATE before re-testing the condition. Appending the
// update to the body would skip it on every `continue` and loop forever, so
// the update gets its own block and `continue` targets that.
import '../../runtime/dc-core-bare/prelude.dart';
@bare
u64 sumTo(u64 n) { var s = u64(0); for (var i = u64(0); i < n; i = i + u64(1)) { s = s + i; } return s; }
@bare u64 nested(u64 n) { var c = u64(0); for (var i = u64(0); i < n; i = i + u64(1)) { for (var j = u64(0); j < n; j = j + u64(1)) { c = c + u64(1); } } return c; }
@bare u64 withBreak(u64 n) { var s = u64(0); for (var i = u64(0); i < n; i = i + u64(1)) { if (i == u64(5)) { break; } s = s + i; } return s; }
@bare u64 withContinue(u64 n) { var s = u64(0); for (var i = u64(0); i < n; i = i + u64(1)) { if ((i & u64(1)) > u64(0)) { continue; } s = s + i; } return s; }
