#include <stdio.h>
#include "nested.h"
static int f = 0;
static void ck(const char*n,uint64_t g,uint64_t w){if(g!=w){printf("  FAIL %s: got %llu want %llu\n",n,(unsigned long long)g,(unsigned long long)w);f=1;}}
int main(void){
  /* innerWritesOuter(rows,cols) = cols * sum(0..rows-1) */
  ck("innerWritesOuter(4,3)", innerWritesOuter(4,3), 3*(0+1+2+3));
  ck("innerWritesOuter(1,5)", innerWritesOuter(1,5), 0);
  ck("innerWritesOuter(5,1)", innerWritesOuter(5,1), 0+1+2+3+4);
  ck("innerWritesOuter(0,9)", innerWritesOuter(0,9), 0);
  ck("triple(3)", triple(3), 27);
  ck("triple(4)", triple(4), 64);
  ck("triple(0)", triple(0), 0);
  ck("findPair(10,12)", findPair(10,12), 2*100+6);   /* first i*j==12: i=2,j=6 */
  ck("findPair(10,0)",  findPair(10,0), 0*100+0);
  ck("findPair(5,99)",  findPair(5,99), 9999);
  printf(f ? "NESTED: %d FAILURES\n" : "NESTED: all correct\n", f);
  return f != 0;
}
