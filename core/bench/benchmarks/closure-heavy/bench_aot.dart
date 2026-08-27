// core/bench/benchmarks/closure-heavy/bench_aot.dart
//
// The stock-Dart-AOT third data point (`dart compile exe`). This is ORDINARY
// Dart, not DCDart -- it does not import the prelude and it is not compiled
// by dcc. INFORMATIONAL ONLY; it never enters a gate number (see
// fib/bench_aot.dart for the full rationale, which applies unchanged).
//
// THIS IS THE ONE SIDE WRITTEN WITH REAL CAPTURING CLOSURES, because that is
// the natural Dart idiom for this workload and stock Dart has them. The same
// state DCDart spells as an explicit heap `Env` (and C as a stack struct) is
// simply CAPTURED here: `makeStage` returns a lambda closing over the two
// scalars and the shared `Gain` object, and the one-item window keeps the
// previous item's closure alive instead of an environment object. What the
// runtime allocates per item is therefore closure contexts managed by the
// tracing GC -- against DCDart's ARC-managed environments and C's stack
// frames, which is exactly the three-way comparison this column exists to
// inform. The algorithm, the selection bits, the composition order and the
// checksum are identical to bench.dart and kernel.c by construction.

const int P = 1000000007;
const int Q = 1000003;

class Gain {
  final int value;
  Gain(this.value);
}

/// Returns the selected stage as a REAL closure over [a], [b] and [g] --
/// capture-by-value for the scalars, capture-of-heap-object for the gain.
int Function(int) makeStage(int sel, int a, int b, Gain? g) {
  if (sel == 0) return (v) => (v + a + b) % P;
  if (sel == 1) return (v) => ((v % Q) * (a % Q) + b) % P;
  if (sel == 2) return (v) => ((v ^ a) + (v >> 7) + b) % P;
  return (v) {
    if (g != null) return (v + g.value + a) % P;
    return (v + b) % P;
  };
}

int benchKernel(int rounds) {
  var acc = 0;
  var x = 123456791;
  for (var r = 0; r < rounds; r++) {
    final g = Gain((r * 2654435761) % Q);
    // The one-item window: a closure over the previous item's third
    // environment that builds the data-selected stage at application time,
    // mirroring bench.dart's saved `prev` Env applied through pickStage.
    int Function(int, int)? prev;
    for (var i = 0; i < 1024; i++) {
      final s1 = (x ^ i) % 4;
      final s2 = (x >> 3) % 4;
      final s3 = (x >> 6) % 4;
      final a3 = (x + r) % Q; // e3's captures, from the PRE-pipeline x,
      final b3 = i;           // exactly when bench.dart builds Env e3
      final f1 = makeStage(s1, x % Q, i % Q, null);
      final f2 = makeStage(s2, (x + i) % Q, r % Q, g);
      final f3 = makeStage(s3, a3, b3, g);
      x = f3(f2(f1(x)));
      final p = prev;
      if (p != null) {
        x = p((x >> 9) % 4, x);
      }
      prev = (sel, v) => makeStage(sel, a3, b3, g)(v);
      acc = (acc + x) % P;
    }
  }
  return acc;
}

void main(List<String> args) {
  final arg = args.isNotEmpty ? int.parse(args[0]) : 2500;
  final iters = args.length > 1 ? int.parse(args[1]) : 1;

  final warm = benchKernel(arg); // discarded
  final checksum = warm;

  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    final r = benchKernel(arg);
    sw.stop();
    if (r != checksum) {
      throw StateError('kernel is not deterministic');
    }
    print('SAMPLE_NS ${sw.elapsedMicroseconds * 1000}');
  }
  print('CHECKSUM $checksum');
  print('CLOCK Stopwatch');
}
