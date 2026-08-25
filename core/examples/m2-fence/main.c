#include <stdio.h>
#include <stdint.h>
#include "fence.h"
static int f = 0;
static void ck(const char *n, uint64_t g, uint64_t w) {
  if (g != w) { printf("  FAIL %s: got %llu want %llu\n", n, (unsigned long long)g, (unsigned long long)w); f = 1; }
}
int main(void) {
  /* This half proves the fences do not BREAK anything -- that inserting a
   * barrier between two accesses leaves both accesses, and their values,
   * intact. It cannot prove the ordering property: a single thread observes
   * its own accesses in program order by definition, so a fence and no fence
   * are indistinguishable from here. The ordering assertions are in the
   * harness (emitted IR, and `mfence` presence per ordering), not here. */
  ck("consume before publish", consume(), 0);
  publish(0xCAFEuLL);
  ck("consume after publish", consume(), 0xCAFEuLL);
  publish(0x1122334455667788uLL);
  ck("consume 64-bit payload", consume(), 0x1122334455667788uLL);
  ck("handoff round-trips", handoff(7), 7);
  ck("consume sees handoff", consume(), 7);
  /* storeThenLoadOther sets the flag, mfences, then reads sharedData (7). */
  ck("storeThenLoadOther", storeThenLoadOther(1), 8);
  ck("compilerBarrierOnly", compilerBarrierOnly(99), 99);
  ck("consume sees barrier write", consume(), 99);
  printf(f ? "FENCE: %d FAILURES\n" : "FENCE: all correct -- every ordering round-trips its accesses intact\n", f);
  return f != 0;
}
