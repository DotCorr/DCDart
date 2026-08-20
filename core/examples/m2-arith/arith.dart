// M2 multiply/divide/remainder target: docs/decisions/0035-complete-integer-
// operators.md for `*` at all four widths, docs/decisions/0036-division-and-
// remainder.md for `~/` and `%`. Like m2-bitwise and unlike m2-port, every
// operator here is an ordinary unprivileged instruction, so this target is
// verified by real execution against exact expected values -- the strongest
// form this project's harnesses use.
//
// Two things are being proved, and they are deliberately kept separate:
//
//   1. The isolated operators (`mulU64` ... `remU8`) prove the width-parsing
//      branch and instruction selection in core/dcc-lower/lib/lower.dart --
//      one `IMul`/`IDiv`/`IRem` per width, checked against C's own `*`/`/`/`%`
//      on the same unsigned width.
//   2. The composed algorithms (`gcd`, `digitSum`, `isPrime`, `powMod`,
//      `lcm`, `sumProperDivisors`) prove the operators actually work
//      TOGETHER inside real control flow -- a `%` feeding a loop condition,
//      a `~/` feeding the next iteration's operand, an `i * i <= n` bound.
//      An operator can be individually correct and still be miscompiled the
//      moment its result is a loop-carried value; the isolated checks alone
//      would not catch that.
//
// Trapping behaviour (`*` on overflow, `~/`/`%` on a zero divisor) is NOT
// exercised from this file -- a trap kills the process, so it cannot share a
// binary with the value checks. tests/conformance/m2-arith/run.sh builds
// trap_divzero.c against this same object file as a separate step.
import '../../runtime/dc-core-bare/prelude.dart';

// ---------------------------------------------------------------------------
// Isolated operators, one function per width.
//
// `*` is checked at all four widths because it is newly available at all
// four (ADR-0035); `~/` and `%` get u64 plus two narrower widths, which is
// what proves the width-prefix parse rather than re-testing an
// instruction-selection path that does not vary by width.
// ---------------------------------------------------------------------------

@bare
u64 mulU64(u64 a, u64 b) => a * b;
@bare
u32 mulU32(u32 a, u32 b) => a * b;
@bare
u16 mulU16(u16 a, u16 b) => a * b;
@bare
u8 mulU8(u8 a, u8 b) => a * b;

@bare
u64 divU64(u64 a, u64 b) => a ~/ b;
@bare
u64 remU64(u64 a, u64 b) => a % b;
@bare
u32 divU32(u32 a, u32 b) => a ~/ b;
@bare
u32 remU32(u32 a, u32 b) => a % b;
@bare
u8 divU8(u8 a, u8 b) => a ~/ b;
@bare
u8 remU8(u8 a, u8 b) => a % b;

// ---------------------------------------------------------------------------
// Composed algorithms.
// ---------------------------------------------------------------------------

/// Euclid's algorithm. `%` is the loop's entire engine: its result is both
/// the termination test and the next iteration's operand, so a `%` that
/// computed the right value but clobbered the wrong register would show up
/// here as a wrong answer or a hang, not as a wrong isolated result.
///
/// Parameters are copied into locals rather than reassigned in place --
/// nothing in the language surface promises parameter slots are mutable, and
/// this target is not the place to find out.
@bare
u64 gcd(u64 x, u64 y) {
  var a = x;
  var b = y;
  while (u64(0) < b) {
    var t = a % b;
    a = b;
    b = t;
  }
  return a;
}

/// The same algorithm at u32, which is what proves `%` composes inside
/// control flow at a narrower width and not only at the machine word size.
@bare
u32 gcdU32(u32 x, u32 y) {
  var a = x;
  var b = y;
  while (u32(0) < b) {
    var t = a % b;
    a = b;
    b = t;
  }
  return a;
}

/// Sum of decimal digits: the canonical `~/ 10` + `% 10` pair. Both
/// operators are applied to the SAME loop-carried value in the same
/// iteration, so an implementation that destroyed its dividend would fail
/// here even though `divU64`/`remU64` pass.
@bare
u64 digitSum(u64 n) {
  var rest = n;
  var sum = u64(0);
  while (u64(0) < rest) {
    sum = sum + rest % u64(10);
    rest = rest ~/ u64(10);
  }
  return sum;
}

/// Trial division up to sqrt(n), written as `i * i <= n` -- a multiply
/// feeding a comparison, which is the shape ADR-0035 added `*` and `<=`
/// for. Returns 1 for prime, 0 for composite. `i * i` cannot overflow for
/// any `n` this harness passes: the loop exits as soon as `i * i` exceeds
/// `n`, so `i` never gets far past sqrt(n).
@bare
u64 isPrime(u64 n) {
  if (n < u64(2)) {
    return u64(0);
  }
  var i = u64(2);
  while (i * i <= n) {
    if (n % i == u64(0)) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// Modular exponentiation by squaring: `%` for the odd-bit test AND for the
/// reduction, `~/` to halve the exponent, `*` for both the accumulate and
/// the square. This is the densest composition in the file -- every one of
/// the three operators appears twice, all inside one loop.
///
/// Callers must keep `m` below 2^32 so that `acc * base` and `base * base`
/// (each strictly less than m*m) cannot overflow u64 and trap.
@bare
u64 powMod(u64 base, u64 exp, u64 m) {
  var b = base % m;
  var e = exp;
  var acc = u64(1) % m;
  while (u64(0) < e) {
    if (e % u64(2) == u64(1)) {
      acc = acc * b % m;
    }
    b = b * b % m;
    e = e ~/ u64(2);
  }
  return acc;
}

/// Least common multiple, spelled `a ~/ gcd(a, b) * b` rather than
/// `a * b ~/ gcd(a, b)`: dividing FIRST keeps the intermediate below the
/// true lcm, so it cannot trap on an overflow that the final answer would
/// not. Also the one place a `~/` result is fed straight into a `*` across
/// a sibling `@bare` call boundary (ADR-0018).
@bare
u64 lcm(u64 a, u64 b) {
  if (a == u64(0)) {
    return u64(0);
  }
  if (b == u64(0)) {
    return u64(0);
  }
  return a ~/ gcd(a, b) * b;
}

/// Sum of the proper divisors of `n` (every divisor below `n` itself), by
/// trial division with `%`. Gives the harness perfect numbers to check
/// against -- sumProperDivisors(6) == 6, (28) == 28, (8128) == 8128 -- which
/// are values no plausible off-by-one or wrong-operand bug reproduces by
/// accident.
@bare
u64 sumProperDivisors(u64 n) {
  var sum = u64(0);
  var i = u64(1);
  while (i < n) {
    if (n % i == u64(0)) {
      sum = sum + i;
    }
    i = i + u64(1);
  }
  return sum;
}
