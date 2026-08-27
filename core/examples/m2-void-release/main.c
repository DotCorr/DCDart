/* Conformance harness for the void-function scope-release leak (found by
 * NEON N1, 2026-08-27 — see voidrelease.dart's header).
 *
 * The whole test is dc_heap_live: churn() moves 3n boxes through three
 * void-function shapes whose releases ride the IMPLICIT return path, and
 * every one of them must be back off the heap when it returns. Before the
 * fix this printed live = 3n; the value checks are secondary (they only
 * prove the functions actually ran).
 */
#include <stdint.h>
#include <stdio.h>
#include "voidrelease.h"

extern uint64_t dc_heap_live;

int main(void) {
  uint64_t sizes[] = {1, 2, 100, 1000};
  for (int k = 0; k < 4; k++) {
    uint64_t n = sizes[k];
    uint64_t got = churn(n);
    if (got != n) {
      printf("churn(%llu) returned %llu\n",
             (unsigned long long)n, (unsigned long long)got);
      return 1;
    }
    if (dc_heap_live != 0) {
      printf("churn(%llu) LEAKED: dc_heap_live = %llu (the implicit-return "
             "release path — see voidrelease.dart)\n",
             (unsigned long long)n, (unsigned long long)dc_heap_live);
      return 2;
    }
  }
  printf("VOIDRELEASE: all correct — @owned params and heap locals in void "
         "functions are released on the implicit-return path, heap clean\n");
  return 0;
}
