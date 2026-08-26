// core/bench/benchmarks/fib/bench_aot.dart
//
// The stock-Dart-AOT third data point (`dart compile exe`). This is ORDINARY
// Dart, not DCDart -- it does not import the prelude and it is not compiled
// by dcc.
//
// It is INFORMATIONAL ONLY and never enters a gate number. ROADMAP.md M3's
// gate is stated against C; stock Dart is a reference point for "what the
// language DCDart forked from costs today", nothing more. It also does its
// own timing (Stopwatch, not clock_gettime through bench_main.c), so it is
// not measured by the same instrument as the other two sides.

int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

void main(List<String> args) {
  final arg = args.isNotEmpty ? int.parse(args[0]) : 36;
  final iters = args.length > 1 ? int.parse(args[1]) : 1;

  final warm = fib(arg); // discarded
  var checksum = warm;

  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    final r = fib(arg);
    sw.stop();
    if (r != checksum) {
      throw StateError('kernel is not deterministic');
    }
    print('SAMPLE_NS ${sw.elapsedMicroseconds * 1000}');
  }
  print('CHECKSUM $checksum');
  print('CLOCK Stopwatch');
}
