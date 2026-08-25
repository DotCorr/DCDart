#include <stdio.h>
#include <stdint.h>
#include "atomic.h"
static int f = 0;
static void ck(const char *n, uint64_t g, uint64_t w) {
  if (g != w) { printf("  FAIL %s: got %llu want %llu\n", n, (unsigned long long)g, (unsigned long long)w); f = 1; }
}
int main(void) {
  /* The behavioural half. It proves the atomics compute the RIGHT VALUE --
   * it does NOT and cannot prove atomicity, because a single-threaded run
   * cannot distinguish `lock xadd` from `add`. That discrimination lives in
   * the harness's disassembly step, not here. Said plainly so nobody reads a
   * green run as evidence of the property this unit is actually about. */
  ck("atomicBumpTicks #1", atomicBumpTicks(), 1);
  ck("atomicBumpTicks #2", atomicBumpTicks(), 2);
  ck("atomicLoadTicks", atomicLoadTicks(), 2);

  /* fetchAdd returns the value BEFORE the add. */
  ck("fetchAdd returns old", atomicFetchAddTicks(10), 2);
  ck("load after fetchAdd", atomicLoadTicks(), 12);
  ck("fetchSub returns old", atomicFetchSubTicks(4), 12);
  ck("load after fetchSub", atomicLoadTicks(), 8);

  atomicStoreTicks(0);
  ck("store then load", atomicLoadTicks(), 0);

  /* The plain and atomic counters address the SAME @bss word, so a mismatch
   * here means one of the two lowerings is addressing something else. */
  ck("plainBumpTicks after store 0", plainBumpTicks(), 1);
  ck("atomicLoad sees plain bump", atomicLoadTicks(), 1);

  /* Bitmap ops: fetchOr sets, fetchAnd clears, fetchXor flips; each returns
   * the word as it was before. */
  ck("setBit old", atomicSetBit(3, 0x8), 0);
  ck("setBit again old", atomicSetBit(3, 0x1), 0x8);
  ck("clearBit old", atomicClearBit(3, ~(uint64_t)0x8), 0x9);
  ck("flipBit old", atomicFlipBit(3, 0x1), 0x1);
  ck("flipBit result", atomicSetBit(3, 0), 0x0);
  ck("other word untouched", atomicSetBit(511, 0xFF), 0);

  /* Test-and-set spinlock: first acquire sees 0 (free), second sees 1 (held). */
  ck("tryAcquire first", tryAcquireLock(), 0);
  ck("tryAcquire second", tryAcquireLock(), 1);
  releaseLock();
  ck("tryAcquire after release", tryAcquireLock(), 0);

  /* u32 width. */
  ck("atomicBump32 #1", atomicBump32(), 1);
  ck("atomicBump32 #2", atomicBump32(), 2);

  printf(f ? "ATOMIC: %d FAILURES\n" : "ATOMIC: all correct -- values round-trip through every atomic op\n", f);
  return f != 0;
}
