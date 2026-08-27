/* Conformance harness for float buffers (ADR-0065).
 *
 * Every reduced value is checked BIT-EXACTLY (memcmp) against C running
 * the identical loop in the identical order at the identical width — an
 * f32 accumulation that took an f64 detour, or a store that wrote 8 bytes
 * where 4 were meant, fails the comparison rather than sneaking under a
 * tolerance.
 *
 * dc_heap_live is checked after EVERY call, m2-rawheap's discipline: a
 * leak balanced by a double-free nets to zero across a run and would pass
 * an end-only check.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "dot.h"

extern uint64_t dc_heap_live;

static int fail_count = 0;
#define CHECK(cond, name) do { \
    if (!(cond)) { printf("FAIL %s\n", name); fail_count++; } \
  } while (0)
#define CHECK_NO_LEAK(name) do { \
    if (dc_heap_live != 0) { \
      printf("FAIL %s LEAKED: %llu live\n", name, (unsigned long long)dc_heap_live); \
      fail_count++; \
    } \
  } while (0)

static int bits64(double a, double b) { return memcmp(&a, &b, 8) == 0; }
static int bits32(float a, float b)  { return memcmp(&a, &b, 4) == 0; }

/* The same fill dot.dart performs: p[i] = (i % 7) * scale, in f32. */
static float fill_at(uint64_t i, float scale) {
  return (float)(uint32_t)(i % 7) * scale;
}

static float dot_expected(uint64_t n) {
  float sum = 0.0f;
  for (uint64_t i = 0; i < n; i++) {
    sum = sum + fill_at(i, 0.5f) * fill_at(i, 0.25f);
  }
  return sum;
}

static double dot64_expected(uint64_t n) {
  double sum = 0.0;
  for (uint64_t i = 0; i < n; i++) {
    double v = (double)i * 0.125;
    sum = sum + v * v;
  }
  return sum;
}

int main(void) {
  /* Element-by-element stride check: every slot of a 32-element buffer,
   * read back through Pointer<f32> after fillF32 wrote it. Catches a
   * wrong-width store (which corrupts a NEIGHBOR, not itself) at the
   * element where it lands. */
  for (uint64_t i = 0; i < 32; i++) {
    float got = fillProbe(32, i);
    if (!bits32(got, fill_at(i, 0.5f))) {
      printf("FAIL fillProbe[%llu]: got %a want %a\n",
             (unsigned long long)i, got, fill_at(i, 0.5f));
      fail_count++;
    }
    CHECK_NO_LEAK("fillProbe");
  }

  /* The dot product at several sizes, including 0 (empty loop), 1, a
   * non-multiple-of-anything 7, and sizes large enough that f32
   * accumulation visibly diverges from f64 — which is exactly what makes
   * the bit-exact f32-vs-f32 comparison meaningful. */
  uint64_t sizes[] = {0, 1, 7, 64, 1000, 4096};
  for (int k = 0; k < 6; k++) {
    uint64_t n = sizes[k];
    float got = dotDemo(n), want = dot_expected(n);
    if (!bits32(got, want)) {
      printf("FAIL dotDemo(%llu): got %a want %a\n",
             (unsigned long long)n, got, want);
      fail_count++;
    }
    CHECK_NO_LEAK("dotDemo");
  }

  /* f64 at stride 8. */
  CHECK(bits64(dotF64Demo(1000), dot64_expected(1000)), "dotF64Demo");
  CHECK_NO_LEAK("dotF64Demo");

  if (fail_count != 0) return 1;
  printf("FLOATDOT: all correct — f32/f64 buffers filled and dot-reduced through Pointer<T> bit-exactly against C, every element at the right stride, dc_heap_live back to zero after every call\n");
  return 0;
}
