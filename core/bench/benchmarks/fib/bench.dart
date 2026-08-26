// core/bench/benchmarks/fib/bench.dart
//
// Naive recursive fibonacci. Deliberately the dumb algorithm: the point is
// call overhead, argument passing and checked arithmetic, not fibonacci.
//
// Zero heap objects, so zero Alloc/Retain/Release. That is what makes this
// the harness's SELF-TEST: with no ARC in it, the DCDart:C ratio has nothing
// ARC-shaped to explain, and the two refcount modes cannot differ.
import '../../../runtime/dc-core-bare/prelude.dart';

@bare
u64 fib(u64 n) {
  if (n < u64(2)) {
    return n;
  }
  return fib(n - u64(1)) + fib(n - u64(2));
}

/// Every benchmark exports exactly this symbol with exactly this signature.
/// `@bare` functions are plain C-ABI symbols, so `bench/harness/bench_main.c`
/// links against this one and the C kernel without knowing which it got.
@bare
u64 benchKernel(u64 arg) {
  return fib(arg);
}
