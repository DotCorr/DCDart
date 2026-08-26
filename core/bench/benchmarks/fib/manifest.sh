# core/bench/benchmarks/fib/manifest.sh — sourced by run-bench.sh.

BENCH_ID=fib
BENCH_DESC="naive recursive fibonacci (call-heavy, zero heap, zero ARC)"

# selftest | m3 | diagnostic
#
#   selftest    proves the HARNESS works. Contains no ARC, so its DCDart:C
#               ratio must land near 1.0 and its two refcount modes must
#               produce byte-identical binaries. A selftest that does not do
#               both means the harness or the flags are wrong, and run-bench.sh
#               says so instead of reporting the ratio as a finding.
#   m3          one of ROADMAP.md M3's five required benchmarks. None exist.
#   diagnostic  a real measurement of something, but NOT one of the five, and
#               therefore not part of any gate number.
BENCH_SUITE=selftest

# Sized so one iteration is >= MIN_KERNEL_MS on a 2021-class laptop core.
BENCH_ARG=36

BENCH_NOTE="Every u64 + and - in DCDart is a checked add: llvm.uadd.with.overflow
plus a branch to llvm.trap (spec: arithmetic traps by default, no &+ exists yet).
On arm64 -O2 that folds to adds/subs plus a not-taken branch, so it is cheap --
but it is NOT free, and it is a DCDart-vs-C difference that has nothing to do
with ARC. This benchmark is the place where that cost shows up alone."
