#include <stdio.h>
#include <stdint.h>
#include "generics.h"
static int f=0;
static void ck(const char*n,uint64_t g,uint64_t w){if(g!=w){printf("  FAIL %s: got %llu want %llu\n",n,(unsigned long long)g,(unsigned long long)w);f=1;}}
int main(void){
  ck("u64Pick(7,9)", u64Pick(7,9), 7);
  ck("u32Pick(3,4)", u32Pick(3,4), 3);
  ck("u8Pick(1,2)",  u8Pick(1,2), 1);
  ck("chained(5,6)", chained(5,6), 6);   /* pick(second(a,b), a) = second = b */
  printf(f ? "GENERICS: %d FAILURES\n" : "GENERICS: all correct (incl. generic calling generic)\n", f);
  return f != 0;
}
