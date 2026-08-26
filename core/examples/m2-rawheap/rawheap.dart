// M2 target for RUNTIME-SIZED RAW ALLOCATION (ADR-0058).
//
// `Alloc` allocates an ARC object whose size is a COMPILE-TIME constant.
// This is the other half: `Heap.allocate(n)` where `n` is a runtime value,
// which is what any data structure owning growable storage needs.
//
// The `StrBuf` below is the point of the exercise. M3's gate requires a
// string-processing pass and a JSON parser, and both have to BUILD text
// rather than only read it. Until raw allocation existed, DCDart could slice
// a string literal (`Str`, ADR-0053) and could not produce one byte of new
// text at runtime. `sbPush` doubling its buffer -- allocate a bigger block at
// a runtime size, copy, free the old one -- is exactly the operation that was
// impossible, which is why this grows from a capacity of ONE and forces a
// reallocation at nearly every power of two rather than testing one
// comfortable size.
//
// `sbDestroy` has a BLOCK body, not an arrow body, and that is not style:
// `Heap.free` is void-returning and recognized in statement position only,
// the same as `Atomic.store` and `Port.outb`, so `=> Heap.free(...)` is
// refused as an expression. A real usability wart shared by all three.

import '../../runtime/dc-core-bare/prelude.dart';

/// A growable UTF-8 byte buffer -- the thing M3's string-processing pass and
/// JSON parser both need and DCDart could not express until now.
class StrBuf extends HeapObject {
  u64 addr;
  u64 length;
  u64 capacity;
  StrBuf(this.addr, this.length, this.capacity);
}

@bare StrBuf sbCreate(u64 cap) {
  final p = Heap.allocate(cap);
  return StrBuf(p.address, u64(0), cap);
}

/// Append one byte, doubling the buffer when it is full. This is the
/// operation that needs a REAL allocator: it allocates a new block, copies,
/// and frees the old one, at a size known only at runtime.
@bare void sbPush(StrBuf b, u8 byte) {
  if (b.length == b.capacity) {
    final newCap = b.capacity * u64(2);
    final fresh = Heap.allocate(newCap);
    var i = u64(0);
    while (i < b.length) {
      final src = Pointer<u8>.fromAddress(b.addr + i);
      final dst = Pointer<u8>.fromAddress(fresh.address + i);
      dst.value = src.value;
      i = i + u64(1);
    }
    Heap.free(Pointer<u8>.fromAddress(b.addr));
    b.addr = fresh.address;
    b.capacity = newCap;
  }
  final at = Pointer<u8>.fromAddress(b.addr + b.length);
  at.value = byte;
  b.length = b.length + u64(1);
}

@bare u64 sbLength(StrBuf b) => b.length;
@bare u8 sbAt(StrBuf b, u64 i) => Pointer<u8>.fromAddress(b.addr + i).value;
@bare void sbDestroy(StrBuf b) {
  Heap.free(Pointer<u8>.fromAddress(b.addr));
}

/// Build a buffer of `n` bytes from a capacity of 1, forcing ~log2(n) grows.
@bare u64 buildAndSum(u64 n) {
  final b = sbCreate(u64(1));
  var i = u64(0);
  while (i < n) {
    sbPush(b, (i % u64(251)).toU8());
    i = i + u64(1);
  }
  var sum = u64(0);
  i = u64(0);
  while (i < sbLength(b)) {
    sum = sum + sbAt(b, i).toU64();
    i = i + u64(1);
  }
  sbDestroy(b);
  return sum;
}
