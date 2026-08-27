// Float arithmetic target (ADR-0065): f32/f64 `+ - * /`, ordered
// comparisons, `==`/`!=`, unary minus, literals, and every conversion the
// prelude exposes — the operator-level half of floating point, the same
// split m2-arith made for integers (isolated operators first, composed
// algorithms second).
//
// Two properties are being proved that integer targets never had to:
//
//   BIT-EXACTNESS. Every isolated operator is checked from C by comparing
//   the raw IEEE bit pattern (memcmp, not `==`) against C computing the
//   identical operation. Both sides lower to the same hardware instruction
//   on the same operands in the same order, so the bits must match exactly
//   — an "approximately equal" check would quietly accept a wrong rounding
//   mode, a double-rounded f32 literal, or an accidental f64 detour in an
//   f32 computation, which are precisely the bugs worth catching.
//
//   NaN AND EDGE SEMANTICS. NaN makes every ordered comparison false and
//   `!=` true; NaN propagates through arithmetic; `-(0.0)` is `-0.0`, not
//   `+0.0`; float division by zero produces ±inf/NaN rather than trapping
//   (deliberately unlike `~/`, ADR-0036); and `.toU64trunc()` saturates —
//   out-of-range clamps, NaN maps to zero — rather than being LLVM poison.
//   None of that is visible from a test that only feeds in round numbers.
//
// Trapping is deliberately NOT exercised here because there is none to
// exercise: no float operation in this file can trap, and that absence is
// the semantic (spec §4.1's float subsection), not a missing test.
import '../../runtime/dc-core-bare/prelude.dart';

// ---------------------------------------------------------------------------
// Isolated operators, one function per op per width — proves the
// "<width>|<op>" dispatch in core/dcc-lower and the FAdd/FSub/FMul/FDiv
// emission in core/backend at both widths.
// ---------------------------------------------------------------------------

@bare
f64 addF64(f64 a, f64 b) => a + b;
@bare
f64 subF64(f64 a, f64 b) => a - b;
@bare
f64 mulF64(f64 a, f64 b) => a * b;
@bare
f64 divF64(f64 a, f64 b) => a / b;

@bare
f32 addF32(f32 a, f32 b) => a + b;
@bare
f32 subF32(f32 a, f32 b) => a - b;
@bare
f32 mulF32(f32 a, f32 b) => a * b;
@bare
f32 divF32(f32 a, f32 b) => a / b;

/// Unary minus is `fneg`, not `0.0 - x` — the C side checks `negF64(0.0)`
/// comes back as `-0.0` by bit pattern, which a subtraction would get wrong.
@bare
f64 negF64(f64 a) => -a;
@bare
f32 negF32(f32 a) => -a;

// ---------------------------------------------------------------------------
// Comparisons. DCBool cannot cross the C ABI (c_header.dart), so each
// returns u64 0/1 through an if — the same shape every integer comparison
// target already uses. The C side drives these with NaN as well as ordered
// values: every `<`/`<=`/`>`/`>=`/`==` involving NaN must be false, and
// `!=` must be true.
// ---------------------------------------------------------------------------

@bare
u64 ltF64(f64 a, f64 b) {
  if (a < b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 leF64(f64 a, f64 b) {
  if (a <= b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 gtF64(f64 a, f64 b) {
  if (a > b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 geF64(f64 a, f64 b) {
  if (a >= b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 eqF64(f64 a, f64 b) {
  if (a == b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 neF64(f64 a, f64 b) {
  if (a != b) {
    return u64(1);
  }
  return u64(0);
}

/// One comparison at f32 width proves the width dispatch; re-testing all
/// six would re-test an emission path that does not vary by width.
@bare
u64 ltF32(f32 a, f32 b) {
  if (a < b) {
    return u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Literals. Returned as values so the C side can check the emitted bit
// pattern directly — `f32(0.1)` must be the double 0.1 rounded ONCE to
// binary32 (what C's `0.1f` is), not rounded through some decimal detour.
// ---------------------------------------------------------------------------

@bare
f64 literalF64() => f64(3.141592653589793);
@bare
f32 literalF32() => f32(0.1);

/// An integer literal in a float constructor — the CFE converts `f64(2)` to
/// a DoubleLiteral before lowering sees it (ADR-0065's verified claim).
@bare
f64 literalFromInt() => f64(2);

// ---------------------------------------------------------------------------
// Conversions — all six prelude members, each a single FConvert.
// ---------------------------------------------------------------------------

@bare
f64 widen(f32 x) => x.toF64(); // fpext, exact
@bare
f32 narrow(f64 x) => x.toF32(); // fptrunc, round to nearest even
@bare
f32 u32ToF32(u32 x) => x.toF32(); // uitofp
@bare
f64 u64ToF64(u64 x) => x.toF64(); // uitofp
@bare
u32 truncF32(f32 x) => x.toU32trunc(); // llvm.fptoui.sat: clamp, NaN -> 0
@bare
u64 truncF64(f64 x) => x.toU64trunc();

// ---------------------------------------------------------------------------
// Composed kernels — operators working TOGETHER inside real control flow,
// m2-arith's discipline: an op can be individually correct and still be
// miscompiled the moment its result is loop-carried.
// ---------------------------------------------------------------------------

/// Horner evaluation of 1 + x + x^2/2 + x^3/6 + x^4/24 — a float
/// accumulator reassigned across straight-line statements, `*` feeding `+`
/// repeatedly, checked bit-exactly against C running the same steps in the
/// same order.
@bare
f64 horner4(f64 x) {
  var acc = f64(1.0) / f64(24.0);
  acc = acc * x + f64(1.0) / f64(6.0);
  acc = acc * x + f64(0.5);
  acc = acc * x + f64(1.0);
  acc = acc * x + f64(1.0);
  return acc;
}

/// Geometric-series sum with a loop-carried f64 accumulator AND a
/// loop-carried f64 term — the two-phi shape a dot product has, without
/// the memory traffic (m4-float-dot adds that).
@bare
f64 geomSum(u64 n, f64 ratio) {
  var sum = f64(0.0);
  var term = f64(1.0);
  var i = u64(0);
  while (i < n) {
    sum = sum + term;
    term = term * ratio;
    i = i + u64(1);
  }
  return sum;
}
