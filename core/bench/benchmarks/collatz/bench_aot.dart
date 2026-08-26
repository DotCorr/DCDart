// core/bench/benchmarks/collatz/bench_aot.dart — stock Dart AOT, informational
// only (see fib/bench_aot.dart's header for why it never enters a gate number).
//
// NOTE Dart's `int` is a 64-bit signed integer here, DCDart's `u64` is
// unsigned. Every value in this benchmark stays far below 2^63, so the two
// agree on every result -- which the harness verifies by comparing checksums
// rather than by anyone asserting it.

int collatzSteps(int start) {
  var n = start;
  var steps = 0;
  while (1 < n) {
    if ((n & 1) < 1) {
      n = n >> 1;
    } else {
      n = n + n + n + 1;
    }
    steps = steps + 1;
  }
  return steps;
}

int benchKernel(int arg) {
  var total = 0;
  for (var i = 1; i < arg + 1; i++) {
    total = total + collatzSteps(i);
  }
  return total;
}

void main(List<String> args) {
  final arg = args.isNotEmpty ? int.parse(args[0]) : 400000;
  final iters = args.length > 1 ? int.parse(args[1]) : 1;

  final warm = benchKernel(arg); // discarded
  final checksum = warm;

  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    final r = benchKernel(arg);
    sw.stop();
    if (r != checksum) throw StateError('kernel is not deterministic');
    print('SAMPLE_NS ${sw.elapsedMicroseconds * 1000}');
  }
  print('CHECKSUM $checksum');
  print('CLOCK Stopwatch');
}
