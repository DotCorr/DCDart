# core/bench/benchmarks/collatz/manifest.sh — sourced by run-bench.sh.

BENCH_ID=collatz
BENCH_DESC="sum of Collatz step counts 1..N (loop-heavy, zero heap, zero ARC)"
BENCH_SUITE=selftest
BENCH_ARG=400000

BENCH_NOTE="The second self-test, and it is a second one on purpose: fib stresses
the CALL path, this stresses the LOOP path (a data-dependent inner while with a
branch on parity). If one lands near 1.0 and the other does not, the difference is
informative; if the harness only had one of them it would not be.

Modelled on examples/demo-collatz/collatz.dart, minus its StepCounter heap object --
that object's single Alloc/Release per CALL is invisible against N inner iterations,
so keeping it would have put a rounding error's worth of ARC into a benchmark whose
job is to have none."
