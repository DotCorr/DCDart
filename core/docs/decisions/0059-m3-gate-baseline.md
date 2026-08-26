# ADR-0059: M3's gate baseline is trap-matched C, and trapping cost is published separately

**Status:** decided by the project owner, 2026-08-26 — implemented in `bench/`

**This one was not delegated.** Every other decision taken during M3's run-up was made under the
owner's standing delegation and recorded with a reversal path. This one was escalated and answered
directly, because it does not change how something is built — it changes **what the project's own
success criterion means.** An agent choosing its own passing grade is not a decision, it is a
conflict of interest.

## Context — the gate measures two things and names one

`ROADMAP.md` M3: *"geometric mean overhead vs. C is ≤ 10%"*, and the milestone is titled **ARC**.

Measured, those are two different baselines, because **DCDart's arithmetic traps and C's does not.**
`CLAUDE.md`'s integer rule requires it: overflow, divide-by-zero and `%` by zero all trap, and
wrapping needs `&+`/`&-`/`&*` explicitly. Every `+` therefore emits
`llvm.uadd.with.overflow` plus a branch to `llvm.trap`.

This was found by the benchmark harness's own self-test rather than by reasoning. `fib` — no heap,
no ARC, nothing the gate is about — came out at **1.24× C**. The agent chased it instead of
reporting it, and isolated the cause: the overflow check blocks the accumulator-recursion→loop
transform LLVM gives the C version at `-O2`. Compiling the **same C source** with
`__builtin_add_overflow`/`__builtin_trap` reproduces DCDart's machine-code shape, and against that
baseline the residual is **1.000×**.

So a gate stated as "ARC overhead" would have silently contained a 25–50% arithmetic penalty on
integer-heavy code, and nobody would have known why the number was what it was.

## Decision

**The gate baseline is trap-matched C** — the same C source built with `__builtin_add_overflow` and
`__builtin_trap`. The ≤10% bar therefore isolates ARC, which is what the gate's wording says it
measures.

**Trapping-arithmetic cost is measured and published as its own separate number.** Not folded into
the ARC gate. Not discarded.

### Rejected, so the choice is legible later

| option | why not |
|---|---|
| plain C at −O2, ≤10% total | Almost certainly unreachable without making arithmetic non-trapping by default — which is a **language-semantics change**, not an optimizer one, and a far larger decision than the gate's phrasing |
| plain C, raise the threshold | The bar becomes a number chosen to fit the result, after seeing the result |
| an opt-out for trap checks | Two languages, two sets of benchmark numbers, and the interesting one is whichever is being quoted |

The reading chosen is the one where **each cost is named as what it is**, rather than one number
quietly containing two unrelated things.

### Why this is not simply a friendlier comparison

That is the obvious criticism and it deserves a direct answer rather than a reassurance.

**`fib`'s 1.000× residual is the answer, and it is load-bearing.** It began as a sanity check on the
instrument; under this decision it is the *justification* for the baseline. It demonstrates that the
two baselines differ **only** by the arithmetic semantics DCDart deliberately adopted — not by
compiler flags, not by linkage, not by the timing instrument, all of which are shared. The harness
reproduces it every run, and if it ever stops reading 1.000× the report prints `INVESTIGATE` and this
decision has lost its footing until someone explains why.

**And the separate number is a deliverable, not a footnote.** If the trapping cost stops being
published alongside the ARC ratio, this becomes indistinguishable from having picked an easier
baseline — which is the single thing that would make the decision wrong. `bench/tool/report.awk`
prints it per benchmark in the same table as the ratio, not in a note underneath.

## Consequences

- **The allocator caveat is published in the same place and the same voice.** ADR-0058's heap has no
  coalescing and no cross-class reuse; C's `malloc` has both. A decision whose whole justification is
  *separate costs get named separately* cannot then leave that one filed in an ADR where a reader of
  the benchmark result never sees it. It now prints next to the number.
- **Two baseline binaries per benchmark, permanently.** `kernel.c` and `kernel_trapck.c`. That was
  already true before the decision, which is why no harness had to be rebuilt either way.
- **`collatz` currently scores 0.848–0.865× against trap-matched C** — DCDart *beats* the
  hand-written trapping C, because `trapping.h` is hand-written C rather than an instruction-level
  twin of the IR `dcc` emits, and LLVM schedules DCDart's version better. The harness reports this as
  `BASELINE-LIMITED` rather than as a pass, and falls back to the plain-C number for that benchmark.
  A trap-matched baseline that DCDart beats is a limit of the diagnostic, and pretending otherwise
  would be the friendlier-baseline criticism coming true in miniature.
- **A question this defers rather than answers:** whether trapping arithmetic at 25–50% on
  integer-heavy code is a price the language wants to keep paying. That is a spec §4.1 question, it
  is on `CLAUDE.md`'s escalate-only list, and it is now *quantified* where before it was unmeasured.
  Quantifying it was the point; deciding it is not this ADR's business.
