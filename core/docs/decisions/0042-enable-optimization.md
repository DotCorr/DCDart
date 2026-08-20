# ADR-0042: `dcc` compiles at `-O2`

**Status:** decided — implemented and verified (25/25 conformance, 8/8 targets freestanding)

## Context

`backend/lib/compile.dart` passed no `-O` flag of any kind, so every DCDart program ever built shipped
`-O0` code: locals spilled to the stack, constants materialized in two instructions, no register
allocation worth the name. Visible in shipped kernel code — `oscortex_core`'s `uartPutc` stored a byte
to a stack slot and reloaded it on the next instruction.

This was filed as GAP-0032, and its importance is not speed. M3's gate is geometric-mean ARC overhead
≤10% vs C, and `ROADMAP.md` prescribes the response when it fails: *"fix the optimizer, or accept and
document a higher number, or revisit the model."* Measuring at `-O0` attributes the whole penalty to
ARC and fails the gate — so **the project would consider revisiting its memory model to fix a missing
compiler flag.**

## Why this could not land earlier

It was blocked on ADR-0041, and finding out why is the reason this ADR exists at all rather than being
a one-line commit. At `-O2`, a non-volatile MMIO read-back is deleted outright:

```
examples/m1-pointer/mmio.dart — M1's own exit criterion

  -O0                                -O2, before ADR-0041
    movl %esi, (%rdi)   store          movl %esi, %eax   <- returns what it wrote
    movl (%rdi), %eax   load           movl %esi, (%rdi)
    retq                               retq              <- THE LOAD IS GONE
```

and `tests/conformance/m1-pointer/run.sh` **still passed**, because the returned value stayed correct.
Enabling `-O` first would have silently deleted MMIO accesses across `oscortex_core` — UART, PIC, PIT,
IDT — while every test in both repos went green.

## Decision

`-O2`, as a parameter on `compileToObject` defaulting to `'2'`.

`-O3` was rejected: it trades size for aggressive unrolling and vectorization, which is the wrong
default for kernel code, and nothing has measured a case where it wins here. `-Os` is the other
defensible choice for `@bare` and is a per-target question nobody has needed yet — the parameter
exists so answering it later is a call-site change, not a redesign.

## Verification

Everything below was run, not assumed.

**Correctness.** 25/25 conformance, 8/8 backend emission tests. ARC elision counts unchanged at the
DC-IR level (`m2-alias`'s `makeAliasAndReadValue` still `retain=0 release=1`, `m2-owned`'s
`makeAndDropViaCall` still `retain=0 release=0`), which matters because those are the numbers M3
measures.

**Rule 1 holds.** All 8 targets freestanding-clean at `-O2`. This was the specific risk worth checking:
at `-O2` LLVM is entitled to turn loops into `memcpy`/`memset` **calls**, which would be undefined
symbols and a rule-1 failure. `-ffreestanding -fno-builtin` prevent it, and that is now verified rather
than trusted.

**MMIO survives.** `tests/conformance/volatile/` compiles the emitted IR at -O0/-O1/-O2/-O3/-Os and
counts real memory operations through the pointer; all five keep the store and the load.

**Port I/O survives.** Checked separately, because `PortOut`/`PortIn` are a different code path from
`Load`/`Store` and ADR-0041 did not touch them. A UART-style busy-wait — `Port.inb(0x3FD)` polled in a
loop — keeps its `inb` **inside** the loop body at `-O2`, executed per iteration, because ADR-0029's
inline asm is marked `sideeffect`. Had it been hoisted, the kernel's polling loops would spin on a
stale read forever.

**The red-zone harness is live for the first time.** `tests/conformance/no-red-zone/`'s codegen half
was a forward guard only, because `-O0` does not use the red zone at all. At `-O2` it is a real check,
and it passes — ADR-0039's fix is doing actual work now rather than waiting.

## Consequences

- Code is roughly half the size. Measured, `bare-x86_64`, same IR both ways:

  | target | -O0 | -O2 | reduction |
  |---|---|---|---|
  | `m0-seam` | 10 | 5 | 50% |
  | `m2-loop` | 89 | 38 | 57% |
  | `m2-recursion` | 90 | 58 | 35% |
  | `demo-collatz` | 185 | 75 | 59% |
  | `demo-stats` | 250 | 117 | 53% |
  | `demo-account` | 216 | 103 | 52% |

- **M3 is unblocked and its measurement is now meaningful.** It should still be taken with GAP-0034 in
  mind: every `Pointer<T>` access is volatile, including bulk array walks that do not need to be, which
  suppresses vectorization on exactly the traversal shape a benchmark suite exercises. If M3 comes in
  over budget, check that before concluding anything about ARC.
- `oscortex_core` gets materially better code with no source change.
- Nothing in the language changed. This is a driver flag, and it is reversible by one parameter.
