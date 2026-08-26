/* Conformance harness for runtime-sized raw allocation (ADR-0058).
 *
 * `dc_heap_live` is checked after EVERY call, not once at the end: a leak
 * that is exactly balanced by a double-free would net to zero across the
 * whole run and pass an end-only check. Checking per call also identifies
 * WHICH size regressed.
 *
 * Sizes are chosen around the size-class boundaries: 0 and 1 are below the
 * smallest class (32 bytes) and must clamp up rather than fail; 65536 and
 * 500000 force roughly nineteen reallocations from a starting capacity of 1.
 */
#include <stdint.h>
#include <stdio.h>
extern uint64_t buildAndSum(uint64_t n);
extern uint64_t dc_heap_live;
static uint64_t expected(uint64_t n){ uint64_t s=0; for(uint64_t i=0;i<n;i++) s += i%251; return s; }
int main(void){
  uint64_t sizes[] = {0, 1, 2, 3, 100, 1000, 65536, 500000};
  for (int k=0;k<8;k++){
    uint64_t n=sizes[k], got=buildAndSum(n), want=expected(n);
    if (got!=want){ printf("n=%llu: got %llu want %llu\n",(unsigned long long)n,(unsigned long long)got,(unsigned long long)want); return 1; }
    if (dc_heap_live!=0){ printf("n=%llu LEAKED: %llu live\n",(unsigned long long)n,(unsigned long long)dc_heap_live); return 2; }
  }
  printf("RAWHEAP: all correct — StrBuf grew to 500,000 bytes from capacity 1, no leaks\n");
  return 0;
}
