# core/bench/benchmarks/attention-f32/manifest.sh — sourced by run-bench.sh.

BENCH_ID=attention-f32
BENCH_DESC="single-head scaled-dot-product attention, seq=96 d=64, f32, polynomial exp"
BENCH_SUITE=diagnostic
BENCH_ARG=200

BENCH_NOTE="NOT one of M3's five (not in M3_REQUIRED) and enters no gate mean.
NEON N2 CANDIDATE 2 of 2 (neon/ROADMAP.md N2): S = QK^T/sqrt(d), row softmax,
xV -- offered to the gate suite; DCDart's call whether it enters. d is fixed
at 64 so the scale is exactly 0.125 and no sqrt exists anywhere.

EXP IS THE SAME POLYNOMIAL ON BOTH SIDES, NOT LIBM. DCDart ships no
transcendentals (GAP-0063 item 1); the bare-target route is a polynomial
kernel in the language, so bench.dart implements a range-reduced degree-6
expNeg and kernel.c/kernel_trapck.c run the IDENTICAL approximation statement
for statement. An @extern libm expf would be a different algorithm with
different rounding on almost every input and the bit-exact checksum would
refuse the pair. Accuracy is N0's NumPy-oracle business; this harness's
business is that both sides compute the same thing.

THE C BASELINES COMPILE UNDER #pragma STDC FP_CONTRACT OFF. dcc emits every
float multiply-add unfused (fmul+fadd, two roundings); clang's default fuses
to fmadd (one rounding), and the sides then differ by ulps the checksum
refuses -- observed on this benchmark's first run. CONSEQUENCE: this C
baseline foregoes real fmadd, so attention-f32 UNDER-prices DCDart's missing
FP contraction; matmul-f32, exact by construction, keeps an idiomatically
contracted C baseline and includes that cost. Read the pair together.

WHAT THE RATIO PRICES. No ARC in the hot path (five buffers, allocated once
per process call): the gap is dominated by GAP-0034 -- every Pointer<T>.value
access is a volatile load/store, blocking vectorization and hoisting in the
QK^T and xV loops. Softer than matmul-f32's gap because softmax's serial
exp/divide work (which volatile hurts less) is a bigger fraction of the
kernel. First measurement: 3.679x +-0.7% total, 3.482x residual vs trap-matched C.

TRAPPING CAVEAT (neon/ROADMAP.md N2, published with every number from this
pair): FP does NOT trap; only integer index/LCG/checksum arithmetic differs
in kernel_trapck.c, so Ctrap/C lands well under integer-heavy benchmarks'
25-50%. Workload property, not evidence trapping is cheap.

CHECKSUM folds the output's raw f32 bit patterns (u32 view of the buffer)
modularly into u64 -- bit-exact equality required, tolerance refused.

NO bench_aot.dart, deliberately: stock Dart has no f32 type -- an AOT port
would compute in f64 (checksum mismatch, column refused) or benchmark a
Float32List round-trip emulation instead of the language. A stated absence
beats a misleading column."
