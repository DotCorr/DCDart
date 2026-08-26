// core/bench/benchmarks/arc-churn/bench_aot.dart — stock Dart AOT,
// informational only.
//
// Unlike the C baseline, this one DOES allocate an object per iteration --
// because that is what the natural Dart spelling does, and stock Dart's answer
// to that (a bump-allocating generational GC) is exactly the thing worth having
// a number for next to ARC's. It is still not part of any gate.

class Cell {
  final int v;
  Cell(this.v);
}

int benchKernel(int n) {
  var acc = 0;
  var x = 1;
  for (var i = 0; i < n; i++) {
    final c = Cell(x + i);
    x = c.v % 1000003;
    acc = acc + x;
  }
  return acc;
}

void main(List<String> args) {
  final arg = args.isNotEmpty ? int.parse(args[0]) : 12000000;
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
