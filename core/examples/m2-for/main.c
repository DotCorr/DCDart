#include <stdio.h>
#include <stdint.h>
#include "forloop.h"
static int f=0;
static void ck(const char*n,uint64_t g,uint64_t w){if(g!=w){printf("  FAIL %s: got %llu want %llu\n",n,(unsigned long long)g,(unsigned long long)w);f=1;}}
int main(void){
  ck("sumTo(10)", sumTo(10), 45);
  ck("sumTo(0)", sumTo(0), 0);
  ck("nested(4)", nested(4), 16);
  ck("withBreak(10)", withBreak(10), 0+1+2+3+4);
  ck("withContinue(10)", withContinue(10), 0+2+4+6+8);
  printf(f ? "FOR: %d FAILURES\n" : "FOR: all correct (nested, break, continue)\n", f);
  return f != 0;
}
