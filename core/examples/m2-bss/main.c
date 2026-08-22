#include <stdio.h>
#include <stdint.h>
#include "bss.h"
static int f=0;
static void ck(const char*n,uint64_t g,uint64_t w){if(g!=w){printf("  FAIL %s: got %llu want %llu\n",n,(unsigned long long)g,(unsigned long long)w);f=1;}}
int main(void){
  /* zero-initialized: the first bump must yield 1 */
  ck("bumpTicks #1", bumpTicks(), 1);
  ck("bumpTicks #2", bumpTicks(), 2);
  ck("bumpTicks #3", bumpTicks(), 3);
  /* state PERSISTS across calls -- that is the whole point */
  for (int i=0;i<97;i++) bumpTicks();
  ck("bumpTicks after 100", bumpTicks(), 101);
  ck("bitmap[0]", writeAndReadBitmap(0, 0xDEADBEEF), 0xDEADBEEF);
  ck("bitmap[511]", writeAndReadBitmap(511, 12345), 12345);
  ck("bitmap[0] still", writeAndReadBitmap(0, 0xDEADBEEF), 0xDEADBEEF);
  printf(f ? "BSS: %d FAILURES\n" : "BSS: all correct -- zero-initialized, mutable, persists across calls\n", f);
  return f != 0;
}
