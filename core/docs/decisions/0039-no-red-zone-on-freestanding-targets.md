# ADR-0039: Freestanding targets forbid the x86-64 red zone

**Status:** decided — implemented and verified

## Context

Reported by the `oscortex_core` side, from a real disassembly of its own kernel object:

```
00000000000006d0 <uartPutc>:
     6d3: 88 44 24 fe    movb %al, -0x2(%rsp)
     6e2: 88 44 24 ff    movb %al, -0x1(%rsp)
     6e6: 8a 44 24 ff    movb -0x1(%rsp), %al
```

No `sub %rsp` anywhere in the function; `idtSetGate` reached `-0x68(%rsp)`. That is textbook SysV
leaf-function red-zone usage.

The x86-64 red zone is 128 bytes below RSP that a leaf function may use without adjusting the stack,
on the promise that nothing else will touch it. **Interrupts break that promise**: the CPU pushes its
interrupt frame at RSP, directly on top of those locals. Correct and valuable in userland, where the
kernel switches stacks for you. In kernel or bare-metal code it is silent memory corruption from the
first timer tick after `sti` — no fault, no diagnostic, just wrong values later.

`dcc` had no way to prevent it: `compile.dart` passed no `-mno-red-zone`, and `llvm_emit.dart` emitted
`nounwind` with no `noredzone`.

## Why the test suite could not have caught this

Worth stating separately, because it says something about the suite rather than about this bug. The
conformance harnesses link `@bare` objects into **ordinary hosted processes**, where the red zone is
entirely legitimate and nothing ever writes below RSP. So a red-zone-using object passes every
behavioural test the project owns while being fatal in the environment `@bare` exists to target. A
green 21/21 was never evidence about this property. Filed as GAP-0027.

## Options

1. Pass `-mno-red-zone` in `compile.dart` unconditionally.
2. Add a `--no-red-zone` CLI flag for the user to remember.
3. Make it a property of the target: freestanding targets forbid it, hosted targets keep it.

## Decision

**Option 3**, plus emitting the `noredzone` LLVM function attribute — both, deliberately.

Option 3 because "freestanding" is *precisely* the property that makes the red zone illegal, and
ADR-0033's registry already models exactly that distinction. Encoding it as `DCTarget.forbidsRedZone
=> isFreestanding` makes it structurally impossible for a future target to get this wrong by
omission — the same argument the registry already makes for object format. Option 2 was rejected for
the obvious reason: a safety property that depends on someone remembering a flag is not a safety
property. Option 1 was rejected because it would disable the red zone for hosted targets too, costing
a real (if small) amount of performance on `--target host` builds for no safety benefit whatsoever —
there are no interrupts landing on a userland stack.

The attribute *and* the flag, rather than either alone, because they protect different things. The
flag governs how `clang` compiles this particular `.ll` in this particular `dcc` invocation. The
attribute travels **with the IR**, so the guarantee survives anyone compiling the emitted `.ll` by
hand, through a different driver, or at a different optimization level. A guarantee that exists only
in a command line is one command line away from being lost.

## Verification

Both halves were checked against real disassembly rather than assumed:

- A leaf function with `volatile` locals, compiled `-O2` for `x86_64-unknown-none-elf`, uses
  `-0x10(%rbp)` and `-0x8(%rbp)` with **zero `sub %rsp`** — locals living below the stack pointer.
  With `-mno-red-zone`, `sub %rsp` appears and they do not.
- The **attribute alone** produces the same fix: taking that function's `.ll`, appending `noredzone`
  to its attribute group and recompiling flips `sub %rsp` count from 0 to 1. So the IR-level
  guarantee is effective independently of the driver flag.
- `noredzone` is emitted for `bare-x86_64` and `bare-aarch64`, and correctly absent for
  `macos-arm64`, `linux-x86_64` and `windows-x86_64`.

`tests/conformance/no-red-zone/` checks both: it disassembles every example built for `bare-x86_64`
and fails on any negative `%rsp` displacement (or negative `%rbp` displacement with no stack
allocation, which is the shape the kernel disassembly showed), and it asserts the attribute is
present for a freestanding target and absent for a hosted one.

**The honest limit:** `dcc` invokes clang with no `-O` flag, and at `-O0` clang does not use the red
zone anyway. So that harness passes today with *or* without this fix. It is a forward regression
guard, not present-day proof — the present-day proof is the attribute assertion. The detector itself
was validated against a deliberately red-zone-using object (correctly FAILs) and the same object with
`noredzone` (correctly passes).

## Consequences

- `@bare` objects for freestanding targets are safe to run with interrupts enabled. `oscortex_core`
  can drop its mitigation — it currently forces an IST stack switch on all 256 IDT gates, which works
  but routes an OS around a compiler bug, exactly what `CLAUDE.md` rule 3's spirit says not to do.
- Hosted targets keep the red zone and its performance.
- aarch64 freestanding targets get the flag too, though AAPCS64 has no red zone to disable. `clang`
  accepts it without complaint, and asserting the property uniformly beats an arch-by-arch exception
  list that a newly added arch would silently fall out of.
- Unaddressed here, and worth someone's attention: DCDart's backend assumes SysV 16-byte stack
  alignment at function entry and this is documented nowhere, so a caller that violates it gets
  misbehaviour with no diagnostic. `oscortex_core` hit exactly this — a 4-byte `.bss` object above its
  boot stack left `stack_top` 4-mod-16.
