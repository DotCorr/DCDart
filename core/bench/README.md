# `core/bench/` — the M3 measurement harness

M3's exit criterion is a number:

> **Exit:** geometric mean overhead vs. C is **≤ 10%**.
> — `ROADMAP.md`, M3 — THE GATE

This directory is the apparatus that produces that number. **Since 2026-08-27
all five required benchmarks exist and the M3 GATE section prints a real gate
number** — see §1 for the suite and `docs/known-gaps.md` GAP-0051b for the
first full-suite run's result.

---

## 1. State of the M3 suite: 5 of 5 — the gate is evaluable

`ROADMAP.md` M3 requires, "at minimum", five benchmarks. **All five now exist**
(the last, `closure-heavy`, landed 2026-08-27), so `run-bench.sh` prints a
real M3 GATE section for the first time. The headline below used to say
"0 of 5"; the rows record what unblocked each one.

State below tracks `docs/known-gaps.md` GAP-0035, which is the authoritative
list and which moved twice on the day this harness was built — treat this
table as a pointer to that one, not as a second source of truth.

| M3 benchmark | id | Exists? | Status |
|---|---|---|---|
| hashmap-heavy workload | `hashmap` | **YES** | **written** (ADR-0061). Two phases: `hashmap` is phase B (churn) and is the gate input; `hashmap-burst` is phase A and is a `diagnostic` that enters no mean. It was NOT as unblocked as this table said: a bucket ARRAY is inexpressible (GAP-0061, escalation 0010), so both sides index 1024 buckets with a depth-10 binary trie and `index-tax/` prices that workaround on the C side |
| tree/graph traversal | `tree-traversal` | **YES** | **written.** Builds, walks and drops a 16,383-node binary tree per round. **2026-08-27: C baseline rewritten from malloc-per-node to a static arena pool** — the malloc baseline was ~5× slower than natural C for this workload (burst-allocate, wholesale drop) and produced DCDart at **0.45× C** (2.2× *faster* than C), an allocator artifact, not an ARC result. Against the arena baseline the same DCDart binary measures **2.372× ±0.6% vs plain C, 2.34× vs trap-matched C** (gate quantity; atomic mode 3.06×/3.01×; traps cost ≈1.01× here — pointer-chasing hides the checks), so the ratio now prices ARC + the ADR-0058 heap, not macOS malloc's bookkeeping. `BENCH_ARG` raised 400→1200 to keep the 5×-faster C kernel well above the 25 ms floor. Details in the benchmark's `BENCH_NOTE` |
| JSON parser | `json` | **YES** | **written** (2026-08-27). The row above used to say "blocked: owning `String`/`StrBuf`"; ADR-0058's `Heap.allocate` let the program build its own buffer, as `tests/conformance/rawheap/` shows (GAP-0045's workaround). Strings are borrowed slices into the input on both sides — see its BENCH_NOTE |
| string-processing pass | `string-pass` | **YES** | **written** (2026-08-27), same unblock as `json`. The control with ZERO retains — its buffer is raw bytes and its fields integers, so it prices codegen rather than ARC (see GAP-0062) |
| closure-heavy functional workload | `closure-heavy` | **YES** | **written 2026-08-27 — the fifth and last.** ADR-0060 closed GAP-0052 (functions as values, real indirect calls, ownership in the pointer's type). CAPTURING closures are still rejected (escalation 0008 §2, re-probed 2026-08-27; pinned by `tests/conformance/closure-capture-reject/`), so the benchmark is written the way closures COMPILE — code pointer + explicit heap environment object — and its manifest says it must be rewritten in capture syntax when capture lands. C baseline keeps its contexts on the stack (natural C; ADR-0059), so the ratio prices environment allocation + ARC |

`run-bench.sh` knows these five ids. Until a benchmark directory exists with
one of them and `BENCH_SUITE=m3`, the harness prints

```
*** NO GATE NUMBER IS PRODUCED BY THIS RUN. ***
```

and no geometric mean it prints is labelled as the gate number. That is
deliberate: the failure mode this whole directory is designed against is a
plausible number escaping into a status report and becoming the project's
belief about where it stands.

### What DOES exist

| id | suite | what it is |
|---|---|---|
| `fib` | `selftest` | naive recursive fibonacci. Call-heavy, zero heap, zero ARC |
| `collatz` | `selftest` | sum of Collatz step counts. Loop-heavy, zero heap, zero ARC |
| `arc-churn` | `diagnostic` | one heap object allocated and released per iteration |
| `hashmap-burst` | `diagnostic` | phase A of the `hashmap` pair: the same work, batched instead of interleaved. Excluded from every mean by design -- see ADR-0061 |
| `matmul-f32` | `diagnostic` | **NEON N2 candidate, NOT in `M3_REQUIRED`** (neon/ROADMAP.md N2): blocked 96³ f32 matmul, LCG inputs, checksum = bit-exact modular fold of the output's f32 bit patterns. Zero ARC in the hot path. First float-kernel measurement: **9.244x ±0.4% vs plain C, 8.308x residual vs trap-matched C (traps 1.113x)** — nowhere near the ~1.0x a float kernel "should" show, and the residual is **GAP-0034**: every `Pointer<T>.value` is a volatile load/store, so the inner loop is scalar-unhoistable while C's vectorizes with fused fmla. Any float number from this harness is a measurement of GAP-0034 until the device/ordinary pointer split lands. FP does not trap, hence the small traps column (NEON's published caveat) |
| `attention-f32` | `diagnostic` | **NEON N2 candidate, NOT in `M3_REQUIRED`**: single-head scaled-dot-product attention (seq 96, d 64; scale exactly 0.125), softmax `exp` as an identical range-reduced polynomial on BOTH sides (GAP-0063 route — libm would break the bit-exact checksum), C baselines under `#pragma STDC FP_CONTRACT OFF` because dcc never fuses multiply-add and clang's default does (GAP-0068, found here as a 1-2 ulp checksum mismatch). **3.679x ±0.7% vs plain C, 3.482x residual vs trap-matched C (traps 1.056x)** — same GAP-0034 story, diluted by softmax's serial exp/divide work |

The two `selftest` benchmarks exist to prove the **harness** works, not to
prove anything about DCDart. `arc-churn` is a microbenchmark that exists to
put a number on one specific open question (§5 below). Neither category enters
a gate number, and `arc-churn` is excluded from every geometric mean.

---

## 2. What the harness does and does not prove

**Proves:**

- That a DCDart program and a C program computing the same result can be
  built, linked and timed under identical compiler flags on this host, and
  that the resulting ratio is stable and reproducible.
- That the DCDart object being timed is **byte-identical** to what
  `dcc build --mode bare --target host` produces. This is checked on every run
  by building both and running `cmp`. Without it, "we measured DCDart" would
  be an assertion.
- That a benchmark with zero ARC lands at parity with C once arithmetic
  semantics are held equal — `fib`'s residual is **1.000x**. That single
  number is what says the flags, the linkage and the timing instrument are
  right; if it were 1.3x, everything else here would be noise about a broken
  apparatus.
- The **price of atomic refcounts**, on the one workload in this tree that
  executes ARC at all. See §5.

**Does not prove:**

- ~~Anything about M3's gate.~~ **Superseded 2026-08-27: all five gate
  benchmarks exist and the harness prints a real M3 GATE section.** What a
  single run still does not prove is that the gate's number is the language's
  final word — GAP-0062 (elision removes almost nothing on idiomatic linked
  structures) is the measured dominant term, and the gate moves when that
  moves.
- Anything about ARC on realistic code *from the diagnostics alone*. Written
  when the only ARC in this tree was `arc-churn`'s one alloc/release pair in
  a loop; the m3 suite now carries the realistic ARC, and `arc-churn` remains
  what it always was — the unamortised worst case, excluded from every mean.
- How much elision COULD remove. `spec §3.2` calls elision "the whole
  ballgame"; the m3 suite now gives it real ARC to work on, and the measured
  answer so far is "very little on linked structures" (GAP-0062, and
  `elision-delta.sh` reproduces the per-benchmark delta). The harness prices
  what survives; it cannot say what a stronger pass would have removed.
- Anything about a machine other than the one in the report header. Every run
  prints its host, CPU, both compiler versions and both flag lists, because a
  timing number without them is not a measurement, it is an anecdote.

---

## 2a. What one real run produced

Reproduced verbatim from a clean run so this file is not making claims the
harness has not made. **None of these is a gate number.** Host: Apple M1 Pro
(6P+2E), macOS 26.2, Apple clang 17.0.0, Dart 3.12.2; 21 timed runs per
configuration; every `noise` under 1.6%; between-batch drift of the C baseline
0.135%.

```
benchmark      suite       DCDart/nonatomic   DCDart/atomic   stock Dart AOT
arc-churn      diagnostic  1.154x ±0.2%       3.233x ±0.4%    0.98x
collatz        selftest    1.274x ±0.2%       1.274x ±0.2%    1.48x
fib            selftest    1.266x ±0.2%       1.275x ±0.3%    (refused, noisy)

benchmark   traps cost (Ctrap/C)   residual (DCDart/Ctrap)   total (DCDart/C)
arc-churn   0.892x                 1.294x                    1.154x
collatz     1.503x                 0.848x                    1.274x
fib         1.265x                 1.000x                    1.266x
```

Three things worth taking away, and nothing else:

1. **The harness works.** `fib` residual **1.000x**, and `fib`'s entire 1.266x
   gap against plain C is trapping arithmetic (1.265x). Flags, linkage and
   instrument are right.
2. **Atomic refcounts cost 2.8x on `arc-churn`** (1.154x → 3.233x against the
   same C baseline; 161.7 ms vs 57.7 ms). On a loop whose only work is one
   alloc/release pair this is the maximum the cost can look like — the
   *unamortised* price of a single `ldaddal` per release. See §5 for why this
   is still a lower bound on a genuinely atomic ARC and an upper bound on
   nothing.
3. **The gate is not near.** Every benchmark here is a self-test or a
   microbenchmark; the five that decide M3 do not exist.

---

## 3. How to run it

```bash
source /path/to/dc_sys/env.sh        # or: source core/scripts/dcdart-env.sh
bash core/bench/run-bench.sh
```

Useful options:

```
--runs N            timed process runs per configuration (default 12; one
                    further run is always discarded as warmup)
--noise-max PCT     per-configuration noise limit (default 2.5)
--ratio-unc-max PCT per-ratio uncertainty limit (default 2.0)
--min-kernel-ms MS  refuse kernels shorter than this (default 25)
--refcount MODES    "nonatomic", "atomic", or both (default: both)
--no-dart-aot       skip the stock Dart AOT column
--out DIR           keep results (report.txt, rows.tsv, raw samples) here
```

`run-bench.sh` exits **2** on a setup error and **3** if the run did not
produce a number the harness stands behind. An incomplete M3 suite counts, so
**3 is the expected exit code today** and 0 is not reachable until the gate is
actually evaluable.

If a configuration is refused for noise, the usual fix is to close whatever
else is running and re-run. There is deliberately **no automatic retry**: a
harness that re-measures until the noise gate passes is selecting on its own
threshold, and the honest version of that is a person deciding to run it
again.

Adding a benchmark means adding a directory under `benchmarks/` with:

| file | required | contents |
|---|---|---|
| `manifest.sh` | yes | `BENCH_ID`, `BENCH_DESC`, `BENCH_SUITE`, `BENCH_ARG`, `BENCH_NOTE` |
| `bench.dart` | yes | DCDart, exporting `@bare u64 benchKernel(u64)` |
| `kernel.c` | yes | idiomatic C, exporting `uint64_t benchKernel(uint64_t)` |
| `kernel_trapck.c` | no (but without it the suite's gate geomean is REFUSED — ADR-0059) | the same C with DCDart's trapping arithmetic (§4) |
| `bench_aot.dart` | no | stock Dart, printing the same `SAMPLE_NS`/`CHECKSUM` protocol |

Size `BENCH_ARG` so one iteration takes 50–200 ms.

---

## 4. Timing methodology, and why each piece is there

**Multiple runs, median reported, never a single sample.** Each configuration
is executed `--runs` times as a *separate process*, and every run prints one
timed sample. The median of those is the reported time.

**Two warmups, both discarded.** One iteration inside every process (discarded
before any sample is printed by `harness/bench_main.c`), and the entire first
process run of every configuration (discarded by `run-bench.sh`). The first
catches branch predictor and cache state; the second catches cold dyld, cold
page cache and first-touch faults.

**In-process timing, not `time ./bin`.** `clock_gettime(CLOCK_MONOTONIC_RAW)`
brackets the kernel call itself, so process startup is outside every number.
This matters most for the stock Dart AOT column, whose startup is tens of
milliseconds.

**The noise gate — the harness refuses rather than reports.** Three
independent noise measurements are taken per configuration, and two of them
are gated:

| statistic | gated? | why |
|---|---|---|
| `noise` = (P75−P25)/median | **yes**, `--noise-max`, default 2.5% | describes the core of the distribution |
| `drift` = median of first half of runs vs second half, in run order | **yes**, same limit | catches thermal throttling *during* the measurement, which no whole-run statistic can see |
| `spread` = (P90−P10)/median | no, reported only | dominated by single stragglers |

> **This gate was designed once, wrong, and then fixed against data — recorded
> because the wrong version was the intuitive one.** The first version gated on
> `(P90-P10)/median` at 4%. On this machine a benchmark's samples are a tight
> core plus a heavy right tail (25 runs of `fib`: 45.96 … 47.37 ms, plus one
> straggler at 49.97 ms). The straggler is another process getting the core.
> It moves P90 by 5% and moves the median by nothing — measured medians
> reproduced across independent runs to **0.005%** while the P90-P10 gate was
> refusing them. A harness that refuses measurements that are in fact good
> gets its thresholds relaxed by the next person, which is a worse outcome
> than having no gate. The interquartile range describes the core and is
> what decides.

**Ratio uncertainty — the threshold that actually decides a 10% gate.** The
uncertainty of the *median* is estimated from the IQR (`σ̂ = IQR/1.349`,
`SE(median) = 1.2533·σ̂/√n`, so `SEM% = 0.9291·IQR%/√n`), and the uncertainty
of a ratio is those two added in quadrature — **plus the measured
between-batch drift of the C baseline as a systematic floor**. That floor is
not a model: `run-bench.sh` times one binary twice, in two independent
batches, and folds the difference in, so no statistical estimate is ever
allowed to claim more precision than the machine demonstrated when asked to
repeat itself.

A ratio whose uncertainty exceeds `--ratio-unc-max` (default **2.0%**) is
printed as `REFUSED`, not as a number.

> **Why 2.0%.** The gate is a 10% threshold. A measurement that is ±2%
> uncertain spends a fifth of the gate's entire budget on not knowing. At ±5%
> the answer to "is this under 10%?" for a measured 9% would be "possibly",
> which is not an answer a milestone can be closed on. 2.0% is the point where
> the measurement is a fifth of the decision's margin rather than half of it.
> It is a judgement call, it is stated here so it can be argued with, and it is
> a flag so it can be changed deliberately rather than by drift.

**A benchmark shorter than 25 ms is refused** whatever its spread looks like:
below that the timer and the surrounding noise floor are a large fraction of
the measurement.

**Checksums.** Every implementation of a benchmark prints the value it
computed. If any two disagree, the benchmark is refused — two programs that
compute different things have incomparable running times, and this is the
cheapest possible guard against a "fast" implementation that is fast because
it is wrong.

**Flags, and why they are equal by construction rather than by intention.**
`backend/lib/compile.dart` builds its clang arguments internally and does not
expose them, so `tool/dcbuild.dart` transcribes the list:

```
--target=<host triple> -O2 [-mno-red-zone] -ffreestanding -fno-builtin
-fno-stack-protector -fno-exceptions -fno-unwind-tables
-fno-asynchronous-unwind-tables
```

A transcription can drift. So the harness does not trust it: on every run it
builds the same source through `dcc build` *and* through `dcbuild.dart`, and
requires the two object files to be **byte-identical**. If `compile.dart`
changes and this file does not, the run fails loudly instead of quietly
comparing `-O2` DCDart against `-O0` C. The same list is then applied
verbatim to the C kernel, `-std=c11` aside.

`-ffreestanding -fno-builtin` on the C side is a real (small) handicap on
memory operations. It is applied anyway: the point is to compare the two code
generators under one configuration, not to give either its best day.

**Linkage.** The C kernel is compiled to its own object file and linked, never
`#include`d into the timing driver, and there is **no `-flto` on either side**.
A DCDart `@bare` function is a C-ABI symbol in a separate object and physically
cannot be inlined into `bench_main.c`; if the C kernel could be, C would be
racing a competitor that had deleted the race.

---

## 5. Refcount mode is a parameter of a run, and both are reported

`docs/decisions/0053-string-slices.md` and
`docs/escalations/0007-arc-refcount-atomicity.md` both attach the same
condition to M3:

> M3 must measure ARC overhead in BOTH refcount modes, atomic and non-atomic,
> and record both numbers. […] This is cheap now and impossible after M3
> freezes.

So `--refcount` takes `nonatomic`, `atomic`, or both, and both is the default.
`run-bench.sh` builds a separate object per mode, times them separately, and
prints them as adjacent columns. **Both modes are measurable today.** If a run
is restricted to one, the report says so under a `*** ONLY ONE MODE ***`
heading rather than printing a single number as if it were the answer.

### How atomic mode is implemented, given that `llvm_emit.dart` is off-limits

`dcc` has no refcount-mode flag and `backend/lib/llvm_emit.dart` belongs to
another work unit. `tool/dcbuild.dart` therefore reproduces `dcc`'s pipeline
(`lowerToDCModule` → `emitModule` → `clang -c`) and, in atomic mode, rewrites
the emitted LLVM IR text between the second and third step. Every

```llvm
%strongN    = load i32, ptr %hdrM
%newstrongN = add i32 %strongN, 1        ; or `sub`
store i32 %newstrongN, ptr %hdrM
```

becomes

```llvm
%strongN    = atomicrmw add ptr %hdrM, i32 1 seq_cst   ; returns the OLD value
%newstrongN = add i32 %strongN, 1
```

`atomicrmw` returns the pre-operation value, so `%strongN` keeps exactly its
old meaning and `%newstrongN` is recomputed from it — `Release`'s
compare-against-zero is unaffected.

**It lowers to real instructions on every target, including the freestanding
ones, and it does not break `CLAUDE.md` rule 1.** Verified rather than
assumed, since a target without hardware atomics could have emitted an
`__atomic_fetch_sub_4` libcall and put an undefined symbol in a `@bare`
object:

| target | lowering | `verify-freestanding.sh` |
|---|---|---|
| `macos-arm64` (host, LSE) | `ldaddal` | pass |
| `bare-aarch64` (no LSE assumed) | `ldaxr` / `stlxr` retry loop | pass |
| `bare-x86_64` | `lock`-prefixed RMW | pass |

So whoever eventually answers escalation 0007 with "atomic" does not also
inherit a rule-1 problem. The cost is instructions, not a runtime dependency.

**The rewrite is verified, not assumed.** `dcbuild.dart` counts
`Retain`/`Release`/`MakeWeak`/`DropWeak` in the DC-IR *before* emission and
requires the number of rewritten sites to equal it exactly. If
`llvm_emit.dart` ever stops emitting refcount updates in this shape, the build
**fails** with an explicit message rather than silently producing a
half-atomic object. And for a benchmark with zero ARC sites the harness
asserts the two modes produce byte-identical objects, which is a second,
independent check that the rewriter touches nothing else.

### What atomic mode is and is NOT

It **prices the atomic instruction**. That is the number
`escalation 0007 §5` condition 2 asks for and the number this harness
produces.

It does **not** make ARC concurrency-correct, and nobody should read the
atomic column as "DCDart with thread-safe ARC". Escalation 0007 §2a is
explicit that atomic counters are necessary but not sufficient:

- `_emitRelease` is a **decide-then-act** sequence — decrement, compare to
  zero, run the destructor, check the weak count, push the slot onto the free
  list. Making the decrement atomic answers "did I bring it to zero"; the four
  steps after it are still separate.
- ADR-0023's **zombie-slot protocol** is a two-counter invariant. Two counters
  made individually atomic do not make a two-counter invariant atomic.
- The allocator's free-list bookkeeping is untouched by this rewrite (it does
  not operate on an object header, and the rewriter is deliberately restricted
  to header updates).
- `WeakLoad` also increments `strong`, but `llvm_emit.dart` emits that
  increment on the far side of a branch, so it is not the contiguous triple
  the rewriter matches and it **stays non-atomic even in atomic mode**.
  `dcbuild.dart` counts and reports `WeakLoad` sites separately for this
  reason.

So the atomic column is a **lower bound** on the cost of a genuinely atomic
ARC, not an estimate of it. A real implementation pays this plus whatever
re-deriving `Release` and the weak protocol costs.

---

## 6. The one asymmetry the harness cannot remove, and what it does instead

DCDart's arithmetic **traps on overflow** (`CLAUDE.md`: "Arithmetic traps by
default"), and there are no wrapping `&+`/`&-`/`&*` operators in the prelude
yet to opt out with. C's does not trap. Every `+` in a DCDart benchmark is
`llvm.uadd.with.overflow` plus a branch to `llvm.trap()`.

This is not an ARC cost and it is not a harness artifact — it is a language
semantics difference that shows up in *every* comparison against C. It was
found by the self-test: `fib` has no heap and no ARC and came out at **1.24x**
C, which is not what a self-test is supposed to say.

It was chased down rather than reported. At `-O2` LLVM converts C's
`fib(n-1) + fib(n-2)` into one recursive call plus a loop; it does not do that
to DCDart's, because a trapping add is not an accumulator it will hoist.
Compiling the *same C source* with `__builtin_add_overflow`/`__builtin_trap`
reproduces DCDart's machine code shape exactly — two `bl`s, no loop.

So each benchmark may carry a second C baseline, `kernel_trapck.c`, built on
`harness/trapping.h`. Since ADR-0059 it is the **gate baseline**: the M3 gate
number is the geometric mean of DCDart / trap-matched C, and the
trapping-arithmetic cost (Ctrap/C) is published alongside it as its own
separate number — plain `kernel.c` stays in the report as the informational
baseline. The second baseline also lets the report **attribute** a gap
instead of leaving the reader to guess:

```
benchmark   traps cost (Ctrap/C)   residual (DCDart/Ctrap)   total (DCDart/C)
fib         1.240x                 1.003x                    1.244x
```

All of `fib`'s 24% is trapping arithmetic. None of it is code generation.

The trap-matched baseline has a known limit and the report says so when it
bites: it is hand-written C, not an instruction-level twin of the IR `dcc`
emits, so on `collatz` LLVM schedules DCDart's version *better* than the
hand-written one and the residual comes out **below** 1.0. The harness reports
that as `BASELINE-LIMITED`, not as a harness failure — both sides share one
driver, one flag list and one link step, the checksums match, and DCDart is
still slower than plain C, so there is no mechanism by which the harness could
be flattering DCDart.

**When the M3 suite becomes writable, this asymmetry does not go away — and
the decision it called for has been made.** ADR-0059: the gate number is
stated against trap-matched C, so it does **not** contain the cost of
trapping arithmetic; that cost is measured and published alongside it as a
separate deliverable. A benchmark without a usable `kernel_trapck.c` makes
its suite's gate geometric mean `REFUSED` — no baseline, no gate number.
Whether trapping arithmetic at 25–50% on integer-heavy code is a price the
language keeps paying is a `spec §4.1` (integer model) question, on the same
`CLAUDE.md` rule-4 freeze list as §3.

---

## 7. Files

```
bench/
  README.md                 this file
  run-bench.sh              the runner: build, verify, time, refuse, report
  harness/
    bench_main.c            the timing driver, linked identically into every binary
    trapping.h              C with DCDart's trapping arithmetic (diagnostic only)
  tool/
    dcbuild.dart            DCDart build with refcount mode as a parameter
    stats.awk               robust per-configuration statistics
    report.awk              formatting, refusal rules, geometric means
  benchmarks/<id>/
    manifest.sh  bench.dart  kernel.c  [kernel_trapck.c]  [bench_aot.dart]
```

Nothing here modifies anything outside `bench/`. There is no conformance
target: this is a measurement harness, not a correctness test, and a benchmark
that fails is a benchmark that was noisy, not a compiler that regressed.
