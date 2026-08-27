// core/bench/benchmarks/matmul-f32/bench.dart
//
// NEON N2 candidate 1 of 2: blocked f32 matrix multiply, 96x96x96.
//
// NOT one of M3's five (M3_REQUIRED) -- this is an ML workload packaged to
// the harness spec and offered to the gate suite per neon/ROADMAP.md N2.
// Whether it enters the official suite is DCDart's call; BENCH_SUITE stays
// `diagnostic` until that call is made.
//
// WHAT IT MEASURES. The first float-kernel number this harness has produced:
// a `Pointer<f32>` buffer walk whose inner loop is one FMul feeding one FAdd,
// with u64 index arithmetic (which traps) interleaved. There is no ARC in the
// hot path -- three buffers are allocated once per process call and freed at
// the end -- so the ratio prices float codegen + trapping index arithmetic,
// not the allocator. NEON's N2 expectation is that this lands much closer to
// 1.0x than the ARC-heavy benchmarks; if it does not, that is a finding.
//
// THE ALGORITHM is the classic register/cache-blocked triple loop (block 32,
// which divides 96 evenly, so there are no edge blocks -- stated rather than
// hidden). Loop order inside a block is i-p-j with a[i,p] hoisted, the
// standard row-major form. The C baseline runs the IDENTICAL loop nest in the
// IDENTICAL order, which is what makes the f32 accumulation bit-exact across
// the two sides -- the checksum folds the OUTPUT BITS, so any reassociation
// on either side is a checksum mismatch, not a silent tolerance pass.
//
// INPUTS ARE DETERMINISTIC, NOT RANDOM. Both sides run the same integer LCG
// (string-pass's recurrence) and convert the low bits to f32 via the exact
// conversion chain u64 % 256 -> u32 -> f32 (uitofp, exact at this range),
// then center/scale by (v - 128.0) * 0.015625 -- both constants are powers
// of two, so every input value is exact in f32 and identical on both sides
// by construction, with no decimal-literal rounding question anywhere.
// Inputs are refilled per round with a round-dependent seed so no round's
// work can be cached, hoisted or CSE'd across the repeat loop on either side.
//
// Buffers cross the @bare boundary as u64 addresses, wrapped with
// `Pointer<f32>.fromAddress` at the use site (GAP-0063 item 3, the repo
// idiom; the `u64(4)` stride is GAP-0051's wart). Only this one object
// allocates (GAP-0064 is moot: each benchmark links alone).
import '../../../runtime/dc-core-bare/prelude.dart';

/// Fills `n` f32 elements from the integer LCG. Every value is
/// (x_i % 256 - 128) / 64, exactly representable, in [-2, 2).
@bare
void fillBuf(u64 addr, u64 n, u64 seed) {
  var x = seed;
  var i = u64(0);
  while (i < n) {
    x = (x * u64(1103515245) + u64(12345)) % u64(2147483648);
    final v = (x % u64(256)).toU32().toF32();
    Pointer<f32>.fromAddress(addr + i * u64(4)).value =
        (v - f32(128.0)) * f32(0.015625);
    i = i + u64(1);
  }
}

@bare
void zeroBuf(u64 addr, u64 n) {
  var i = u64(0);
  while (i < n) {
    Pointer<f32>.fromAddress(addr + i * u64(4)).value = f32(0.0);
    i = i + u64(1);
  }
}

/// C[i,j] += A[i,p] * B[p,j], blocked. All of m, k, n must be multiples of
/// the block size (the caller passes 96s; block is 32) -- no edge handling,
/// deliberately, so both sides run the identical iteration space.
@bare
void matmulBlocked(u64 a, u64 b, u64 c, u64 m, u64 k, u64 n) {
  final blk = u64(32);
  var ii = u64(0);
  while (ii < m) {
    final iEnd = ii + blk;
    var kk = u64(0);
    while (kk < k) {
      final pEnd = kk + blk;
      var jj = u64(0);
      while (jj < n) {
        final jEnd = jj + blk;
        var i = ii;
        while (i < iEnd) {
          var p = kk;
          while (p < pEnd) {
            final av = Pointer<f32>.fromAddress(a + (i * k + p) * u64(4)).value;
            var j = jj;
            while (j < jEnd) {
              final pc = Pointer<f32>.fromAddress(c + (i * n + j) * u64(4));
              final bv =
                  Pointer<f32>.fromAddress(b + (p * n + j) * u64(4)).value;
              pc.value = pc.value + av * bv;
              j = j + u64(1);
            }
            p = p + u64(1);
          }
          i = i + u64(1);
        }
        jj = jj + blk;
      }
      kk = kk + blk;
    }
    ii = ii + blk;
  }
}

/// Folds the raw IEEE-754 bit patterns of `n` f32 elements into a modular
/// u64 -- string-pass's rolling hash, over bits instead of bytes. Reading
/// the f32 buffer through `Pointer<u32>` at the same address is the
/// reinterpretation route GAP-0063 item 4 sanctions; the C side does the
/// same via a union. BIT-exact, so an accumulation that rounded differently
/// anywhere in the matrix is a checksum mismatch, not a near-miss.
@bare
u64 foldBits(u64 addr, u64 n, u64 acc) {
  var s = acc;
  var i = u64(0);
  while (i < n) {
    final bits = Pointer<u32>.fromAddress(addr + i * u64(4)).value.toU64();
    s = (s * u64(31) + bits) % u64(1000000007);
    i = i + u64(1);
  }
  return s;
}

@bare
u64 benchKernel(u64 rounds) {
  final m = u64(96);
  final k = u64(96);
  final n = u64(96);
  final a = Heap.allocate(m * k * u64(4));
  final b = Heap.allocate(k * n * u64(4));
  final c = Heap.allocate(m * n * u64(4));

  var acc = u64(0);
  var r = u64(0);
  while (r < rounds) {
    fillBuf(a.address, m * k, r * u64(2) + u64(1));
    fillBuf(b.address, k * n, r * u64(2) + u64(2));
    zeroBuf(c.address, m * n);
    matmulBlocked(a.address, b.address, c.address, m, k, n);
    acc = foldBits(c.address, m * n, acc);
    r = r + u64(1);
  }

  Heap.free(a);
  Heap.free(b);
  Heap.free(c);
  return acc;
}
