// core/bench/benchmarks/attention-f32/bench.dart
//
// NEON N2 candidate 2 of 2: single-head scaled-dot-product attention,
// seq=96, d=64, f32 throughout.
//
//     S = QK^T / sqrt(d);  P = row_softmax(S);  O = P V
//
// NOT one of M3's five (M3_REQUIRED) -- an ML workload packaged to the
// harness spec and offered to the gate suite per neon/ROADMAP.md N2;
// BENCH_SUITE stays `diagnostic` until DCDart makes that call.
//
// d IS FIXED AT 64 SO THE SCALE IS EXACT. 1/sqrt(64) = 0.125, a power of
// two, so no sqrt is needed anywhere and the scale multiply is exact --
// the one transcendental this kernel cannot avoid is exp, below.
//
// EXP IS AN EXPLICIT POLYNOMIAL, IMPLEMENTED TWICE, IDENTICALLY. DCDart
// deliberately ships no transcendentals (GAP-0063 item 1: on many inputs
// LLVM's intrinsics lower to libcalls -- undefined symbols in @bare, rule 1
// by accident); the sanctioned bare-target route is a polynomial kernel in
// DCDart itself, and that is what `expNeg` below is. The C baseline runs
// THE SAME approximation, statement for statement -- NOT libm's expf --
// because the whole point of the bit-folded checksum is that both sides do
// identical arithmetic in identical order, and libm's expf is a different
// algorithm with different rounding on almost every input. Accuracy of the
// approximation (~1e-7 relative on its reduced range) is beside the point
// here; N0's NumPy oracle owns accuracy, this harness owns "both sides
// computed the same thing".
//
// expNeg's domain is x <= 0, which softmax's max-subtraction guarantees:
// range-reduce z = -x by k = trunc(z*log2(e)) (u32 -- DCDart has no signed
// ints, so the reduction is arranged to stay unsigned end-to-end), evaluate
// a degree-6 Horner polynomial for e^r on r in [0, ln 2), and scale by
// 2^-k via k exact multiplications by 0.5 rather than an exponent-field
// bitcast -- no scratch memory, no bit tricks, and halving is exact down
// to the denormal floor where both sides round identically anyway. The
// f32->u32 conversion saturates in DCDart (toU32trunc, clamp+NaN->0) and
// is a plain cast in C; the operand is in [0, ~126) by construction, where
// the two agree. Float CONSTANTS are written as double literals narrowed
// to f32 on BOTH sides (`f32(lit)` here, `(float)lit` in C) so the two
// rounding steps are identical and no single- vs double-rounding question
// exists.
//
// THE C BASELINES COMPILE WITH #pragma STDC FP_CONTRACT OFF. dcc emits
// every float multiply-add as separate fmul+fadd (two roundings); clang's
// default contracts `a*b + c` to fmadd (one rounding), and the two sides
// then differ by ulps that the bit-exact checksum refuses -- observed on
// this benchmark's first run, and matmul-f32 only escapes it because its
// arithmetic is all-exact by construction. The pragma costs the C baseline
// its fmadd instructions; see the kernel.c header and the manifest note
// for what that does to the ratio's meaning.
//
// INPUTS ARE DETERMINISTIC (same LCG + exact power-of-two scaling as
// matmul-f32, seeded per round so no work can be cached across the repeat
// loop). Softmax row sums accumulate in f32 -- N0's kernels sum in f64 for
// oracle accuracy, but here both sides run the same f32 sum and the
// checksum only needs them equal, so the benchmark stays a pure f32
// pipeline. No ARC in the hot path: five buffers allocated once per call,
// freed at the end. Addresses cross the @bare boundary as u64 (GAP-0063
// item 3); the u64(4) stride is GAP-0051's wart.
import '../../../runtime/dc-core-bare/prelude.dart';

/// Same LCG fill as matmul-f32: values (x % 256 - 128) / 64, exact in f32.
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

/// exp(x) for x <= 0. See the file header for the reduction and why the
/// IDENTICAL code exists in kernel.c. Below x ~ -87 the true value
/// underflows f32; both sides return exactly 0 there.
@bare
f32 expNeg(f32 x) {
  final z = -x;
  if (z >= f32(87.0)) {
    return f32(0.0);
  }
  // k = trunc(z * log2(e)), so z = k*ln2 + r with r in [0, ln2) up to
  // rounding. k <= 125 here, comfortably inside u32.
  final k32 = (z * f32(1.4426950408889634)).toU32trunc();
  final r = z - k32.toF32() * f32(0.6931471805599453);
  // Degree-6 Horner for e^r, coefficients 1/6! .. 1/1!, double literals
  // narrowed to f32 identically on both sides.
  var p = f32(0.001388888888888889);
  p = p * r + f32(0.008333333333333333);
  p = p * r + f32(0.041666666666666664);
  p = p * r + f32(0.16666666666666666);
  p = p * r + f32(0.5);
  p = p * r + f32(1.0);
  p = p * r + f32(1.0);
  // 2^-k by k exact halvings; e^x = e^(-z) = 1/(2^k * e^r) = 2^-k / e^r.
  var pw = f32(1.0);
  final k = k32.toU64();
  var i = u64(0);
  while (i < k) {
    pw = pw * f32(0.5);
    i = i + u64(1);
  }
  return pw / p;
}

/// S[i,j] = 0.125 * sum_p Q[i,p] * K[j,p]. Q and K are seq x d row-major,
/// so QK^T is a dot of ROWS -- both operands stream sequentially.
@bare
void scoresQKt(u64 q, u64 kbuf, u64 s, u64 seq, u64 d) {
  var i = u64(0);
  while (i < seq) {
    var j = u64(0);
    while (j < seq) {
      var acc = f32(0.0);
      var p = u64(0);
      while (p < d) {
        final qv = Pointer<f32>.fromAddress(q + (i * d + p) * u64(4)).value;
        final kv = Pointer<f32>.fromAddress(kbuf + (j * d + p) * u64(4)).value;
        acc = acc + qv * kv;
        p = p + u64(1);
      }
      Pointer<f32>.fromAddress(s + (i * seq + j) * u64(4)).value =
          acc * f32(0.125);
      j = j + u64(1);
    }
    i = i + u64(1);
  }
}

/// In-place row softmax with max subtraction (every expNeg argument <= 0),
/// f32 row sum -- see the file header for why not f64.
@bare
void softmaxRows(u64 s, u64 rows, u64 cols) {
  var r = u64(0);
  while (r < rows) {
    final row = s + r * cols * u64(4);

    var mx = Pointer<f32>.fromAddress(row).value;
    var j = u64(1);
    while (j < cols) {
      final v = Pointer<f32>.fromAddress(row + j * u64(4)).value;
      if (mx < v) {
        mx = v;
      }
      j = j + u64(1);
    }

    var sum = f32(0.0);
    j = u64(0);
    while (j < cols) {
      final pj = Pointer<f32>.fromAddress(row + j * u64(4));
      final e = expNeg(pj.value - mx);
      pj.value = e;
      sum = sum + e;
      j = j + u64(1);
    }

    j = u64(0);
    while (j < cols) {
      final pj = Pointer<f32>.fromAddress(row + j * u64(4));
      pj.value = pj.value / sum;
      j = j + u64(1);
    }

    r = r + u64(1);
  }
}

/// O[i,j] = sum_p P[i,p] * V[p,j]. P is seq x seq, V is seq x d, both
/// row-major; i-p-j order with P[i,p] hoisted, same as matmul-f32's inner
/// nest, so V streams row-wise.
@bare
void attnV(u64 s, u64 v, u64 o, u64 seq, u64 d) {
  var i = u64(0);
  while (i < seq) {
    var j = u64(0);
    while (j < d) {
      Pointer<f32>.fromAddress(o + (i * d + j) * u64(4)).value = f32(0.0);
      j = j + u64(1);
    }
    var p = u64(0);
    while (p < seq) {
      final pv = Pointer<f32>.fromAddress(s + (i * seq + p) * u64(4)).value;
      j = u64(0);
      while (j < d) {
        final po = Pointer<f32>.fromAddress(o + (i * d + j) * u64(4));
        final vv = Pointer<f32>.fromAddress(v + (p * d + j) * u64(4)).value;
        po.value = po.value + pv * vv;
        j = j + u64(1);
      }
      p = p + u64(1);
    }
    i = i + u64(1);
  }
}

/// matmul-f32's bit fold: raw IEEE f32 bit patterns through Pointer<u32>
/// (GAP-0063 item 4's reinterpretation route), rolled modularly into u64.
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
  final seq = u64(96);
  final d = u64(64);
  final q = Heap.allocate(seq * d * u64(4));
  final kbuf = Heap.allocate(seq * d * u64(4));
  final v = Heap.allocate(seq * d * u64(4));
  final s = Heap.allocate(seq * seq * u64(4));
  final o = Heap.allocate(seq * d * u64(4));

  var acc = u64(0);
  var r = u64(0);
  while (r < rounds) {
    fillBuf(q.address, seq * d, r * u64(3) + u64(1));
    fillBuf(kbuf.address, seq * d, r * u64(3) + u64(2));
    fillBuf(v.address, seq * d, r * u64(3) + u64(3));
    scoresQKt(q.address, kbuf.address, s.address, seq, d);
    softmaxRows(s.address, seq, seq);
    attnV(s.address, v.address, o.address, seq, d);
    acc = foldBits(o.address, seq * d, acc);
    r = r + u64(1);
  }

  Heap.free(q);
  Heap.free(kbuf);
  Heap.free(v);
  Heap.free(s);
  Heap.free(o);
  return acc;
}
