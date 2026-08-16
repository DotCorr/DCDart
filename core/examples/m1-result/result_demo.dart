// M1 exit criterion (ROADMAP.md), third clause: "returns Result<u64, Err>
// through ? propagation." `.propagate()` approximates `?`, see
// docs/escalations/0001-question-mark-syntax.md and
// docs/decisions/0014-result-value-representation.md.
//
// STATUS: this builds and passes verify-freestanding.sh (see
// core/tests/conformance/m1-result/run.sh), but correctness of the
// returned Result VALUE across the C ABI boundary is NOT yet verified --
// see docs/known-gaps.md GAP-0007 item 4 (a real, confirmed struct-return
// ABI bug on this Windows dev host). Do not treat this example as fully
// proven until that's fixed and re-verified, ideally under the real
// x86_64-unknown-none-elf/SysV target rather than the Windows-native
// retarget proxy used for every other example in this repo.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
Result checkPositive(u64 value) {
  if (value < u64(1)) {
    return Result.err(u64(999));
  }
  return Result.ok(value);
}

@bare
Result doubleIfPositive(u64 value) {
  if (value < u64(1)) {
    return Result.err(u64(999));
  }
  final unwrapped = Result.ok(value).propagate();
  return Result.ok(unwrapped);
}

@bare
Result alwaysPropagatesErr(u64 errCode) {
  final unwrapped = Result.err(errCode).propagate();
  return Result.ok(unwrapped);
}
