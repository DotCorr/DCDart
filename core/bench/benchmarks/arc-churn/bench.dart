// core/bench/benchmarks/arc-churn/bench.dart
//
// One heap object allocated and dropped per iteration. See manifest.sh for
// what this benchmark does and does not license anyone to conclude.
//
// The `x = (x + i) % 1000003` recurrence is not decoration. It creates a
// serial data dependency through the loop, which stops LLVM from vectorising
// or closed-forming EITHER side; a benchmark where -O2 deletes the C loop and
// not the DCDart one measures the optimiser's pattern matcher, not the
// language. It also keeps every intermediate far below 2^64, which matters
// because DCDart's arithmetic traps and there are no wrapping `&+`/`&*`
// operators in the prelude yet to opt out with.
import '../../../runtime/dc-core-bare/prelude.dart';

class Cell extends HeapObject {
  u64 v;
  Cell(this.v);
}

@bare
u64 benchKernel(u64 n) {
  var acc = u64(0);
  var x = u64(1);
  var i = u64(0);
  while (i < n) {
    var c = Cell(x + i);
    x = c.v % u64(1000003);
    acc = acc + x;
    i = i + u64(1);
  }
  return acc;
}
