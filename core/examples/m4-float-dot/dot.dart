// Float-buffer target (ADR-0065): fill Heap-allocated f32 buffers through
// `Pointer<f32>`, dot-product them, and free everything — the memory half
// of floating point, and deliberately the exact shape of the workload the
// feature exists for. NEON's ML kernels (matmul/softmax/layernorm) are all
// "walk `Pointer<f32>` buffers, multiply, accumulate"; a dot product is
// that pattern with nothing else in the way.
//
// What this proves that m4-float-arith cannot:
//
//   LOAD/STORE WIDTH. A `Pointer<f32>` store must write exactly 4 bytes
//   (`store float`) and a load must read exactly 4 (`load float`) — a
//   width bug here silently corrupts the NEXT element, which the harness
//   catches by probing every element of a filled buffer from C, not just
//   the reduced dot product. f64 gets the same treatment at stride 8.
//
//   FLOATS THROUGH THE HEAP. `Heap.allocate` hands back raw bytes with no
//   element type; the f32 view is imposed entirely by `Pointer<f32>`, the
//   same way m2-rawheap imposes u8. Leak-freedom is asserted per call
//   (dc_heap_live back to zero), m2-rawheap's discipline.
//
//   THE ACCUMULATION LOOP. `sum = sum + a[i] * b[i]` — an FMul feeding an
//   FAdd into a loop-carried f32 phi, with the loop's own u64 induction
//   arithmetic interleaved. Checked bit-exactly against C running the same
//   loop, which also pins down that accumulation happens in f32 (an f64
//   detour would round differently and fail the memcmp).
//
// Buffers are passed between the @bare functions as u64 ADDRESSES, not
// `Pointer<u8>` values: a Pointer<T> in a function signature is not
// lowerable (GAP-0063 item 3), and "an address in a u64, wrapped with
// `Pointer<T>.fromAddress` at the use site" is this repo's established
// pointer idiom anyway (Str.address, Rodata.addressOf). The `u64(4)`
// stride restates what `Pointer<f32>` already knows — GAP-0051's wart,
// carried here like every other buffer walker until `.elementAt` lands.
import '../../runtime/dc-core-bare/prelude.dart';

/// Fills `p[i] = (i % 7) * scale` for `i < n` — deterministic, cheap for
/// the C side to recompute, and non-constant so a stride bug shows up as a
/// wrong VALUE rather than a coincidental match.
@bare
void fillF32(u64 addr, u64 n, f32 scale) {
  var i = u64(0);
  while (i < n) {
    final p = Pointer<f32>.fromAddress(addr + i * u64(4));
    p.value = (i % u64(7)).toU32().toF32() * scale;
    i = i + u64(1);
  }
}

/// The kernel: sum of a[i] * b[i], accumulated in f32.
@bare
f32 dotF32(u64 a, u64 b, u64 n) {
  var sum = f32(0.0);
  var i = u64(0);
  while (i < n) {
    final pa = Pointer<f32>.fromAddress(a + i * u64(4));
    final pb = Pointer<f32>.fromAddress(b + i * u64(4));
    sum = sum + pa.value * pb.value;
    i = i + u64(1);
  }
  return sum;
}

/// Allocate, fill, dot, free. Returns the dot product; leak-freedom is
/// observed by the harness via dc_heap_live after every call, not asserted
/// here.
@bare
f32 dotDemo(u64 n) {
  final a = Heap.allocate(n * u64(4));
  final b = Heap.allocate(n * u64(4));
  fillF32(a.address, n, f32(0.5));
  fillF32(b.address, n, f32(0.25));
  final sum = dotF32(a.address, b.address, n);
  Heap.free(a);
  Heap.free(b);
  return sum;
}

/// One element of a filled buffer, read back through the same pointer type
/// that wrote it — the per-element half of the width proof, driven
/// index-by-index from C. Deliberately allocates fresh per probe so every
/// call also round-trips the heap.
@bare
f32 fillProbe(u64 n, u64 i) {
  final a = Heap.allocate(n * u64(4));
  fillF32(a.address, n, f32(0.5));
  final v = Pointer<f32>.fromAddress(a.address + i * u64(4)).value;
  Heap.free(a);
  return v;
}

/// The f64 counterpart at stride 8 — proves the load/store width really is
/// derived from the pointee type rather than hard-coded, without
/// duplicating the whole f32 surface.
@bare
f64 dotF64Demo(u64 n) {
  final a = Heap.allocate(n * u64(8));
  var i = u64(0);
  while (i < n) {
    final p = Pointer<f64>.fromAddress(a.address + i * u64(8));
    p.value = i.toF64() * f64(0.125);
    i = i + u64(1);
  }
  var sum = f64(0.0);
  i = u64(0);
  while (i < n) {
    final p = Pointer<f64>.fromAddress(a.address + i * u64(8));
    sum = sum + p.value * p.value;
    i = i + u64(1);
  }
  Heap.free(a);
  return sum;
}
