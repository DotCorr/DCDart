// core/bench/benchmarks/string-pass/bench.dart
//
// M3 benchmark 2 of 5: a string-processing pass.
//
// Reads a UTF-8 buffer, splits it on a delimiter, and BUILDS a transformed
// copy. The build half is the point -- until ADR-0058's `Heap.allocate`
// landed, DCDart could slice a literal (`Str`, ADR-0053) and could not
// produce one byte of new text at runtime, so this benchmark was
// inexpressible rather than merely slow.
//
// WHY IT DOES NOT USE A DELIMITED LITERAL AS INPUT. Generating the input in
// the kernel means both sides start from identical bytes with no I/O, no file
// system and nothing in `.rodata` that one language gets for free. The
// generator is a plain recurrence, identical in both implementations, and its
// cost is in both sides equally.
//
// WHAT IT MEASURES, honestly: a `StrBuf` append loop, which is `Heap.allocate`
// + copy + `Heap.free` on each growth, against C's `realloc`. That is a
// DIFFERENT allocator comparison from `tree-traversal`'s: growth reallocation
// is the case where C's `realloc` can often EXTEND IN PLACE and DCDart's
// segregated size classes never can -- a grow is always allocate-copy-free
// across two classes. So where `tree-traversal` flatters DCDart's allocator,
// this one should do the opposite, and the pair is more informative than
// either alone.
//
// There is no `String` type: the prelude has no growable text (GAP-0045), so
// the buffer is written here the way every DCDart program that needs one must
// write it today. That is itself part of what the gate is measuring.
import '../../../runtime/dc-core-bare/prelude.dart';

/// Growable byte buffer. Identical in shape to C's realloc-backed buffer so
/// the two sides differ in allocator, not in algorithm.
class Buf extends HeapObject {
  u64 addr;
  u64 length;
  u64 capacity;
  Buf(this.addr, this.length, this.capacity);
}

@bare Buf bufNew(u64 cap) {
  final p = Heap.allocate(cap);
  return Buf(p.address, u64(0), cap);
}

@bare void bufPush(Buf b, u8 byte) {
  if (b.length == b.capacity) {
    final newCap = b.capacity * u64(2);
    final fresh = Heap.allocate(newCap);
    var i = u64(0);
    while (i < b.length) {
      final dst = Pointer<u8>.fromAddress(fresh.address + i);
      dst.value = Pointer<u8>.fromAddress(b.addr + i).value;
      i = i + u64(1);
    }
    Heap.free(Pointer<u8>.fromAddress(b.addr));
    b.addr = fresh.address;
    b.capacity = newCap;
  }
  Pointer<u8>.fromAddress(b.addr + b.length).value = byte;
  b.length = b.length + u64(1);
}

@bare void bufFree(Buf b) {
  Heap.free(Pointer<u8>.fromAddress(b.addr));
}

/// Fills `dst` with `n` pseudo-random printable bytes plus commas, using a
/// recurrence with a serial dependency so neither side's loop can be
/// vectorised or closed-formed away.
@bare void genInput(u64 addr, u64 n) {
  var x = u64(12345);
  var i = u64(0);
  while (i < n) {
    x = (x * u64(1103515245) + u64(12345)) % u64(2147483648);
    final b = x % u64(64);
    // if/else rather than `?:` -- ConditionalExpression is not lowered
    // (GAP-0051 territory); the C side uses `?:` freely, and this is one more
    // place where the DCDart source is shaped by what the compiler accepts.
    var ch = u64(44);
    if (b != u64(0)) {
      ch = u64(97) + b % u64(26);
    }
    Pointer<u8>.fromAddress(addr + i).value = ch.toU8();
    i = i + u64(1);
  }
}

/// The pass: walk the input, upper-case alphabetic bytes, drop commas, and
/// append the result to a growable buffer. Returns a checksum of the output.
@bare u64 transform(u64 inAddr, u64 n, Buf out) {
  var sum = u64(0);
  var i = u64(0);
  while (i < n) {
    final c = Pointer<u8>.fromAddress(inAddr + i).value.toU64();
    if (c != u64(44)) {
      final up = c - u64(32);
      bufPush(out, up.toU8());
      sum = (sum * u64(31) + up) % u64(1000000007);
    }
    i = i + u64(1);
  }
  return sum;
}

@bare u64 benchKernel(u64 rounds) {
  final inputLen = u64(60000);
  final input = Heap.allocate(inputLen);
  genInput(input.address, inputLen);

  var acc = u64(0);
  var r = u64(0);
  while (r < rounds) {
    final out = bufNew(u64(64));
    acc = (acc + transform(input.address, inputLen, out)) % u64(1000000007);
    bufFree(out);
    r = r + u64(1);
  }
  Heap.free(input);
  return acc;
}
