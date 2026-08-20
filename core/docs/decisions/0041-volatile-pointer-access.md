# ADR-0041: `Pointer<T>` load/store are volatile

**Status:** decided — implemented and verified (`tests/conformance/volatile/`)

## Context

`DCDART_SPEC.md` §6 and `CLAUDE.md` both say hardware register access goes through `@volatile` or
`Pointer<T>`, and `CLAUDE.md` adds the operative sentence:

> If you find yourself reasoning about whether the optimizer will keep a load, you have already made a
> mistake — annotate it.

Nothing implemented it. `Load` and `Store` emitted plain LLVM `load`/`store`, which the optimizer is
entitled to delete, duplicate, reorder or hoist.

That was harmless only because `dcc` passes no `-O` flag (GAP-0032). Preparing to enable optimization
turned it into a live defect, and measuring it first is the only reason it was not shipped:

```
examples/m1-pointer/mmio.dart — M1's exit criterion, its own emitted IR

  -O0                                   -O2
    movl %esi, (%rdi)    store            movl %esi, %eax   <- returns what it wrote
    movl (%rdi), %eax    load             movl %esi, (%rdi)
    retq                                  retq              <- THE LOAD IS GONE
```

For a hardware register the read-back *is* the operation: status bits change on read, write-only bits
read back differently, devices acknowledge. And **`tests/conformance/m1-pointer/run.sh` still passed**,
because the returned value is correct and only the access disappeared.

## Options

1. Make every `Load`/`Store` volatile.
2. Make only `Pointer<T>` accesses volatile; leave heap-object field access ordinary.
3. Add an opt-in `@volatile` annotation, defaulting to non-volatile.

## Decision

**Option 2.**

Option 1 was rejected on cost: most `Load`/`Store` sites are not MMIO at all. Heap-object field reads,
the destructor cascade (ADR-0022) and weak-reference slots are ordinary memory, and making them
volatile would block CSE and hoisting on the exact paths M3 measures, for no correctness benefit
whatsoever. Verified after the change: `examples/m2-heap/box.dart` emits **zero** volatile operations.

Option 3 was rejected because it makes the unsafe case the default, and today is the argument against
that. The failure is invisible — no crash, no wrong value, no diagnostic, and a green conformance
suite. A default that fails that way is not a default anyone can be expected to opt out of correctly,
and it would have required annotating every existing MMIO access in `oscortex_core` to restore
behaviour it already had.

So `isVolatile` lives on `Load`/`Store`, defaults to **false**, and is set true at exactly the two
sites that lower `Pointer<T>.value` — one read, one write. `Pointer<T>` is the MMIO mechanism; ordinary
memory is reached other ways.

Deliberately NOT a memory-ordering model. LLVM `volatile` prevents elision, duplication and
reordering *with respect to other volatile operations*; it is not an atomic, not a fence, and says
nothing about multi-core visibility. Spec §6's "explicit ordering" wants real barriers, which do not
exist yet — recorded as GAP-0033 rather than implied by this ADR.

## Verification

`tests/conformance/volatile/` compiles the emitted IR at **-O0, -O1, -O2, -O3 and -Os** and counts real
memory operations through the MMIO pointer at each level. Every level keeps 1 store and 1 load.

The harness asserts the **access**, not the value, which is the whole point — the value-checking
harness for this exact program passed throughout the period the bug was live. Negative control run by
hand: strip `volatile` from the IR, recompile at `-O2`, and the detector reports `loads=0` and fails.
A check that cannot fail is not a check.

## Consequences

- `-O` (GAP-0032) is unblocked, and with it M3's measurement. That ordering is now load-bearing: `-O`
  before this would have silently deleted MMIO accesses across `oscortex_core` — UART, PIC, PIT, IDT.
- The ARC path is untouched, so M3 measures ARC rather than a volatile penalty.
- `oscortex_core` needs no source changes. Its existing `Pointer<T>.value` accesses become correct
  under optimization automatically, which is the practical argument for option 2 over option 3.
- Bulk non-MMIO pointer walks (`examples/demo-stats/`) are now volatile too and lose vectorization,
  since they go through the same `Pointer<T>.value`. A separate non-volatile accessor is the fix if
  M3 shows it matters; it is not speculatively added here (GAP-0034).
- This is the third bare-metal-only defect found outside the conformance suite (GAP-0027), and the
  first found by this project rather than by its downstream consumer — but only because enabling `-O`
  forced a look. It would not have been found by running the suite.
