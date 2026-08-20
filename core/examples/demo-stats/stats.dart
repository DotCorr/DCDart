// A third real, hand-written program (after demo-collatz and demo-account),
// deliberately exercising a combination neither of those touches: raw
// POINTER ARITHMETIC over a buffer the C caller owns.
//
// This is the shape that was impossible before ADR-0035/0036. Indexing an
// array means computing `base + i * elementSize`, which needs `*`; a mean
// needs `~/`. DCDart had neither operator until now, so a program could
// read a fixed address (examples/m1-pointer) but could not walk an array.
//
// The buffer is allocated and freed by C. DCDart never allocates here --
// which is exactly how a @bare function is supposed to interact with memory
// it does not own (spec §6): take the address, do the work, own nothing.
import '../../runtime/dc-core-bare/prelude.dart';

/// Element stride for a u32 array. Named rather than inlined because
/// getting it wrong is the classic pointer-arithmetic bug and a literal `4`
/// scattered through three functions is how it happens.
const int _u32Bytes = 4;

@bare
u32 elementAt(u64 base, u64 index) {
  final p = Pointer<u32>.fromAddress(base + index * u64(_u32Bytes));
  return p.value;
}

/// Sum of `count` u32 elements, accumulated at u64 width so a long array
/// cannot overflow the accumulator the way summing into a u32 would.
@bare
u64 sum(u64 base, u64 count) {
  var i = u64(0);
  var total = u64(0);
  while (i < count) {
    final p = Pointer<u32>.fromAddress(base + i * u64(_u32Bytes));
    total = total + p.value.toU64();
    i = i + u64(1);
  }
  return total;
}

/// Integer mean. Returns 0 for an empty array rather than dividing by zero
/// -- `~/` TRAPS on a zero divisor (ADR-0036), so an unguarded `sum ~/ count`
/// here would halt the process on empty input instead of returning anything.
@bare
u64 mean(u64 base, u64 count) {
  if (count == u64(0)) return u64(0);
  return sum(base, count) ~/ count;
}

@bare
u32 maxOf(u64 base, u64 count) {
  var i = u64(0);
  var best = u32(0);
  while (i < count) {
    final p = Pointer<u32>.fromAddress(base + i * u64(_u32Bytes));
    final v = p.value;
    if (v > best) {
      best = v;
    }
    i = i + u64(1);
  }
  return best;
}

/// Counts elements strictly greater than `threshold` -- composes the new
/// comparison operators with pointer arithmetic in one loop.
@bare
u64 countAbove(u64 base, u64 count, u32 threshold) {
  var i = u64(0);
  var n = u64(0);
  while (i < count) {
    final p = Pointer<u32>.fromAddress(base + i * u64(_u32Bytes));
    if (p.value > threshold) {
      n = n + u64(1);
    }
    i = i + u64(1);
  }
  return n;
}
