# ADR-0045: Word and doubleword port I/O (`outw`/`inw`/`outl`/`inl`)

**Status:** decided — implemented and verified (`tests/conformance/m2-port/`)

## Context

ADR-0029 built byte-width port I/O only, deliberately: it was scoped to the one thing
`oscortex_core`'s UART needed. PCI bus enumeration then needed more, and not as a convenience —
**PCI configuration space is only decoded for doubleword accesses.** A byte or word read of
`CONFIG_DATA` does not return a narrower slice of the register; it returns the wrong thing. So
`outl`/`inl` are the only access width that works there at all.

The kernel had already routed around it with a hand-written `portio.S` supplying exactly these four
instructions and nothing else — the protocol stayed in DCDart, only the instruction was donated. That
is the narrowest possible workaround, and it is deletable now.

## Decision

Add `outw`/`inw`/`outl`/`inl` to `Port`, alongside the existing byte forms.

**No new DC-IR instruction, and no new IR field.** `PortOut` and `PortIn` already carry typed
operands — `value.type` and `dest.type` — so the width is already in the IR. The backend derives the
mnemonic suffix and the accumulator register from it:

| width | mnemonic | register | LLVM type |
|---|---|---|---|
| u8 | `outb`/`inb` | `al` | `i8` |
| u16 | `outw`/`inw` | `ax` | `i16` |
| u32 | `outl`/`inl` | `eax` | `i32` |

64-bit is **rejected** with a specific error rather than emitted: x86 defines port access for byte,
word and doubleword only, and there is no `outq`. Handing that to clang would fail later with a worse
message.

This keeps ADR-0029's shape exactly — fixed inline-asm forms marked `sideeffect`, not general `asm`
(GAP-0019 stays closed at the same width it was). The new forms inherit GAP-0036's regression
harness for free, since that pins the `sideeffect` property rather than a particular mnemonic.

## Verification

`tests/conformance/m2-port/` now asserts the **mnemonic and the register together**:

```
outl %eax, %dx      inl %dx, %eax
outw %ax, %dx       inw %dx, %ax
outb %al, %dx       inb %dx, %al
```

Checking the mnemonic alone would miss the failure mode that actually matters: `outl` paired with
`%ax` is a width bug that assembles fine and writes half the register. All read out of a real
disassembly, following ADR-0029's own discipline of verifying the asm shape against `llvm-objdump`
rather than reasoning about AT&T operand order.

Still structural rather than executed, for ADR-0029's original reason — these are privileged,
ring-0-only instructions that trap in a normal process. Real end-to-end proof happens in
`oscortex_core` under full-system emulation.

## Consequences

- `oscortex_core` can delete `portio.S` entirely and four `@extern` declarations with it: its
  `kmain.o` goes from **29 declared externs to 25**, and a `.S` file disappears.

  (An earlier draft of this ADR said "12 to 8", relayed from the kernel side before either of us had
  checked. Their agent read `verify-freestanding`'s actual output and corrected it. Recorded rather
  than silently fixed, because a measured claim that turns out to be someone's recollection is worth
  noticing — the number was wrong in the flattering direction.)
- PCI enumeration becomes expressible in DCDart rather than in donated assembly.
- The three-width table is now the complete x86 port surface. Nothing further is needed here, unlike
  most gaps this project closes partially.
