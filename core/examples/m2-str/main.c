#include <stdio.h>
#include <stdint.h>
#include "str.h"
static int f=0;
static void ck(const char*n,uint64_t g,uint64_t w){if(g!=w){printf("  FAIL %s: got %llu want %llu\n",n,(unsigned long long)g,(unsigned long long)w);f=1;}}
int main(void){
  ck("helloLen", helloLen(), 5);
  ck("emptyLen", emptyLen(), 0);
  ck("utf8Len (BYTES not code units)", utf8Len(), 6);
  ck("sumBytes 'ABC'", sumBytes(), 65+66+67);
  ck("interning: identical literals share a global", sameAddress(), 1);
  printf(f ? "STR: %d FAILURES\n" : "STR: all correct\n", f);
  return f != 0;
}
