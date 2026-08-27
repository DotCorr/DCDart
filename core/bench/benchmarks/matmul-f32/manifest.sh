# core/bench/benchmarks/matmul-f32/manifest.sh — sourced by run-bench.sh.

BENCH_ID=matmul-f32
BENCH_DESC="blocked 96x96x96 f32 matmul, LCG inputs, bit-exact fold of output"
BENCH_SUITE=diagnostic
BENCH_ARG=400

BENCH_NOTE="NOT one of M3's five (not in M3_REQUIRED) and enters no gate mean.
NEON N2 CANDIDATE 1 of 2 (neon/ROADMAP.md N2): an ML workload packaged to this
harness's spec and OFFERED to the gate suite. Whether it enters is DCDart's
call; until then it is a diagnostic. It is the first float-kernel measurement
this harness has produced.

WHAT THE RATIO PRICES. No ARC in the hot path (three buffers, allocated once
per process call), so DCDart/C here is float codegen + trapping u64 index
arithmetic + GAP-0034 -- and it is GAP-0034 that dominates: every
Pointer<T>.value access is a VOLATILE load/store (ADR-0041, MMIO safety),
which blocks vectorization, LICM and FMA formation in exactly the loop shape
this kernel is made of. The C baseline vectorizes the inner j-loop with fused
fmla; DCDart runs it as scalar volatile load / fmul / fadd / volatile store.
First measurement: 9.244x +-0.4% total, 8.308x residual vs trap-matched C -- NOT the near-1.0x a float kernel would
show without GAP-0034. That gap file predicted this ('hosted bulk traversal
pays all of it... if M3 comes in over budget, check this before concluding
anything about ARC') and now has the number.

TRAPPING CAVEAT (neon/ROADMAP.md N2, published with every number from this
pair): FP arithmetic does NOT trap -- only the integer index/LCG/checksum
arithmetic differs in kernel_trapck.c -- so expect Ctrap/C well under the
25-50% seen on fib-shaped integer code. That is a property of float-dominated
workloads, not evidence that trapping is cheap.

CHECKSUM IS BIT-EXACT BY CONSTRUCTION. Inputs are multiples of 1/64 below 2,
so products and 96-term sums stay exactly representable in f32: both sides
produce IDENTICAL output bits whatever fusion or vectorization either compiler
applies, and the checksum folds those bits (u32 view of the f32 buffer)
modularly into u64. This is also why the C baseline KEEPS clang's default FP
contraction (real fmla, idiomatic C) where attention-f32's must turn it off:
matmul's ratio honestly includes DCDart's missing FP contraction; read the
pair together.

NO bench_aot.dart, deliberately: stock Dart has no f32 type -- an AOT port
would either compute in f64 (checksum mismatch, column refused) or emulate
f32 by round-tripping every intermediate through a Float32List slot, which
benchmarks the emulation, not the language. A refused-or-misleading column is
worse than a stated absence."
