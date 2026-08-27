/* Conformance harness for float arithmetic (ADR-0065).
 *
 * BIT-EXACT comparison throughout: every check memcmp's the raw IEEE bit
 * pattern against C computing the identical operation on the identical
 * operands in the same order. Both sides emit the same hardware
 * instruction, so the bits must match exactly; a tolerance would quietly
 * accept a wrong rounding mode or an f32 computation taking an f64 detour.
 *
 * NaN checks use the comparison FUNCTIONS' results, never C-side `==` on a
 * NaN (which is false by the same IEEE rule being tested).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "floatarith.h"

static int fail_count = 0;
#define CHECK(cond, name) do { \
    if (!(cond)) { printf("FAIL %s\n", name); fail_count++; } \
  } while (0)

static int bits64(double a, double b) { return memcmp(&a, &b, 8) == 0; }
static int bits32(float a, float b)  { return memcmp(&a, &b, 4) == 0; }

int main(void) {
  /* Isolated operators, f64. 0.1/0.2/0.3 are deliberately inexact in
   * binary — the check is that DCDart rounds exactly as C does, not that
   * the decimal answer is pretty. */
  CHECK(bits64(addF64(0.1, 0.2), 0.1 + 0.2), "addF64");
  CHECK(bits64(subF64(1.0, 0.3), 1.0 - 0.3), "subF64");
  CHECK(bits64(mulF64(0.1, 0.3), 0.1 * 0.3), "mulF64");
  CHECK(bits64(divF64(1.0, 3.0), 1.0 / 3.0), "divF64");

  /* Isolated operators, f32. */
  CHECK(bits32(addF32(0.1f, 0.2f), 0.1f + 0.2f), "addF32");
  CHECK(bits32(subF32(1.0f, 0.3f), 1.0f - 0.3f), "subF32");
  CHECK(bits32(mulF32(0.1f, 0.3f), 0.1f * 0.3f), "mulF32");
  CHECK(bits32(divF32(1.0f, 3.0f), 1.0f / 3.0f), "divF32");

  /* Division by zero: defined IEEE results, no trap (unlike `~/`). */
  CHECK(bits64(divF64(1.0, 0.0), INFINITY), "divF64 1/0 = +inf");
  CHECK(bits64(divF64(-1.0, 0.0), -INFINITY), "divF64 -1/0 = -inf");
  CHECK(isnan(divF64(0.0, 0.0)), "divF64 0/0 = NaN");

  /* NaN propagates through arithmetic. */
  CHECK(isnan(addF64(NAN, 1.0)), "addF64 NaN propagation");
  CHECK(isnan(mulF64(1.0, NAN)), "mulF64 NaN propagation");

  /* Unary minus is fneg: sign of zero flips, bit-observably. */
  CHECK(bits64(negF64(2.5), -2.5), "negF64");
  CHECK(bits64(negF64(0.0), -0.0), "negF64 -0.0");
  CHECK(bits32(negF32(0.0f), -0.0f), "negF32 -0.0");

  /* Ordered comparisons on ordered values... */
  CHECK(ltF64(1.0, 2.0) == 1 && ltF64(2.0, 1.0) == 0 && ltF64(1.0, 1.0) == 0, "ltF64");
  CHECK(leF64(1.0, 1.0) == 1 && leF64(2.0, 1.0) == 0, "leF64");
  CHECK(gtF64(2.0, 1.0) == 1 && gtF64(1.0, 2.0) == 0, "gtF64");
  CHECK(geF64(1.0, 1.0) == 1 && geF64(1.0, 2.0) == 0, "geF64");
  CHECK(eqF64(1.5, 1.5) == 1 && eqF64(1.5, 2.5) == 0, "eqF64");
  CHECK(neF64(1.5, 2.5) == 1 && neF64(1.5, 1.5) == 0, "neF64");
  CHECK(ltF32(1.0f, 2.0f) == 1 && ltF32(2.0f, 1.0f) == 0, "ltF32");

  /* ...and against NaN: every ordered predicate false, != true. */
  CHECK(ltF64(NAN, 1.0) == 0 && ltF64(1.0, NAN) == 0, "ltF64 NaN");
  CHECK(leF64(NAN, NAN) == 0, "leF64 NaN");
  CHECK(gtF64(NAN, 1.0) == 0, "gtF64 NaN");
  CHECK(geF64(NAN, NAN) == 0, "geF64 NaN");
  CHECK(eqF64(NAN, NAN) == 0, "eqF64 NaN != NaN (oeq)");
  CHECK(neF64(NAN, NAN) == 1, "neF64 NaN is une");
  CHECK(ltF64(-0.0, 0.0) == 0 && eqF64(-0.0, 0.0) == 1, "-0.0 == +0.0");

  /* Literals, bit-exact: f32(0.1) must be C's 0.1f — one rounding to
   * binary32 — and the int-literal form must be exactly 2.0. */
  CHECK(bits64(literalF64(), 3.141592653589793), "literalF64");
  CHECK(bits32(literalF32(), 0.1f), "literalF32 single rounding");
  CHECK(bits64(literalFromInt(), 2.0), "literalFromInt");

  /* Conversions. */
  CHECK(bits64(widen(0.1f), (double)0.1f), "widen fpext exact");
  CHECK(bits32(narrow(0.1), (float)0.1), "narrow fptrunc");
  CHECK(bits32(u32ToF32(16777217u), (float)16777217u), "u32ToF32 rounds above 2^24");
  CHECK(bits64(u64ToF64(1234567890123ull), (double)1234567890123ull), "u64ToF64");

  /* Saturating truncation: fraction toward zero, clamp at the ends,
   * NaN -> 0. A plain fptoui would be poison on the last three. */
  CHECK(truncF64(3.9) == 3 && truncF64(0.5) == 0, "truncF64 toward zero");
  CHECK(truncF64(-2.5) == 0, "truncF64 negative saturates to 0");
  CHECK(truncF64(1e30) == UINT64_MAX, "truncF64 overflow saturates to max");
  CHECK(truncF64(NAN) == 0, "truncF64 NaN -> 0");
  CHECK(truncF32(3.9f) == 3, "truncF32 toward zero");
  CHECK(truncF32(1e10f) == UINT32_MAX, "truncF32 overflow saturates to max");
  CHECK(truncF32(-1.0f) == 0, "truncF32 negative saturates to 0");

  /* Composed kernels, same steps in the same order on the C side. */
  {
    double x = 0.7, acc = 1.0 / 24.0;
    acc = acc * x + 1.0 / 6.0;
    acc = acc * x + 0.5;
    acc = acc * x + 1.0;
    acc = acc * x + 1.0;
    CHECK(bits64(horner4(0.7), acc), "horner4");
  }
  {
    double sum = 0.0, term = 1.0;
    for (uint64_t i = 0; i < 40; i++) { sum += term; term *= 0.5; }
    CHECK(bits64(geomSum(40, 0.5), sum), "geomSum");
  }

  if (fail_count != 0) return 1;
  printf("FLOATARITH: all correct — f32/f64 arithmetic, comparisons and conversions bit-exact against C, NaN/inf/-0.0 semantics IEEE, truncation saturates\n");
  return 0;
}
