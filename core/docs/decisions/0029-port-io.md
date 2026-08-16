# ADR-0029: x86 port I/O (`Port.outb`/`Port.inb`)

**Status:** VERIFIED — `core/examples/m2-port/port_io.dart` builds via real `dcc build --mode bare`,
passes `verify-freestanding.sh`, and `core/tests/conformance/m2-port/run.sh` reports an unqualified
PASS under WSL/Ubuntu: a real 16550 UART (COM1) initialization sequence disassembles to exactly 7
`outb` and 1 `inb` instruction, correct opcodes and operands, confirmed against a real
`llvm-objdump -d` disassembly (not guessed — the exact LLVM inline-asm syntax was test-compiled and
disassembled standalone before being wired into the backend). All 14 pre-existing conformance
harnesses re-verified with zero regressions.

## Context

This is the first real DCDart-language feature added in service of a downstream project:
`oscortex_core`, a from-scratch OS being developed alongside DCDart itself. Its first milestone (boot
+ prove it's alive via serial output) needs x86 legacy serial (COM1, a 16550 UART), which is
programmed via port I/O (`in`/`out` instructions) — not memory-mapped I/O, which is all `Pointer<T>`
supports. DCDart had no port-I/O primitive and no inline-asm primitive at all before this.

Building general inline asm (`asm`, `@naked`) or extern-to-external-symbol FFI (spec §6/§9) would have
been a much bigger, genuinely undesigned unit of work — link-time resolution of a symbol not defined
in the Kernel IR compilation unit is a new architectural concept `dcc` doesn't have at all today (it
only ever emits one self-contained relocatable object per compilation unit). That would violate this
project's "build exactly what's needed, not speculatively" discipline. Every legacy-x86 driver
(keyboard, PIT, PIC, and this UART) needs `outb`/`inb` specifically, though — a real, narrow,
immediately-motivated need, not a speculative add-on.

## Decision

**One narrow DC-IR instruction pair, not general inline asm.** `PortOut`/`PortIn`
(`core/dc-ir/lib/instructions.dart`), each with a **fixed** LLVM inline-asm string — architecturally
identical in shape and risk to how `Pointer<T>.value` was added (ADR-0010: recognized prelude member →
new DC-IR instruction → fixed LLVM shape). No general asm syntax is exposed to DCDart source at all.

**New prelude surface** (`core/runtime/dc-core-bare/prelude.dart`):
- `u16` — a new sized-int extension type. x86's port address space is genuinely 16 bits (ports go up
  to `0xFFFF`); `u8` is too narrow, `u32` is wider than the real hardware operand. Construction only
  (no operators), same minimal discipline as `u8`/`u32`.
- `class Port { static void outb(u16 port, u8 value); static u8 inb(u16 port); }` — static methods,
  not an extension type (there's no natural receiver value these should be instance methods on).
  Recognized in `dcc-lower` by `target.isStatic` + enclosing class name + library URI, mirroring how
  `Result.ok`/`Result.err` are recognized via `target.isFactory` — same pattern, different Kernel
  `Procedure` kind.

**`Port.outb` is void-returning, which exposed a real, previously-unimplemented gap.**
`dcc-lower/README.md` had already flagged: *"A void-returning callee can't be called as an expression
yet, only as a statement, which isn't wired up either (no target has needed it)."* This is that
target. `_lowerExpression` always returns a non-nullable `DCValue`, so a void call can't go through it
— `Port.outb(port, value);` as a bare statement is recognized in `_lowerStatement`'s
`ExpressionStatement` handling instead (a new `StaticInvocation`-as-statement case, alongside the
existing `InstanceSet`/`VariableSet` cases). `Port.inb` returns `u8`, so it's recognized in
`_lowerExpression` normally.

**Generalized sized-int literal construction.** Only `u64(1)`-style literal construction was
recognized before this (`u64|constructor#`); `u8`/`u32` were TYPES that existed (used for struct
fields and `Pointer<u32>`'s pointee) but nothing had ever needed to construct a literal `u8`/`u32`
VALUE from source. Building a UART init sequence needs literal `u8`/`u16` values constantly (port
numbers, register values). Generalized the single `u64|constructor#` check into a `switch` covering
`u8|constructor#`/`u16|constructor#`/`u32|constructor#`/`u64|constructor#` uniformly, via a small
shared helper — same literal-only restriction as before (spec §4.1: no implicit int/sized-int
conversion).

## The LLVM codegen — verified against a real disassembly before being wired in

AT&T `outb %al, %dx` needs the value in `AL` and the port in `DX` — hard register requirements of the
actual instruction encoding, so the codegen uses explicit hard-register constraints rather than
relying on register-class allocation:

```llvm
call void asm sideeffect "outb $0, $1", "{al},{dx}"(i8 %value, i16 %port)
```

For `inb`, LLVM numbers the (single) output operand first (`$0` = `{al}`, the result) then the input
(`$1` = `{dx}`, the port), so the asm string reads `"inb $1, $0"` to put the source (port) first and
the destination (result) second, matching real AT&T syntax:

```llvm
%dest = call i8 asm sideeffect "inb $1, $0", "={al},{dx}"(i16 %port)
```

Both strings were compiled standalone with `clang -c -target x86_64-unknown-none-elf` and disassembled
with `llvm-objdump -d` *before* being wired into `core/backend/lib/llvm_emit.dart`, confirming the
exact real opcodes (`ee` = `outb`, `ec` = `inb`) with correctly-ordered operands — not assumed correct
from reading the LLVM LangRef alone.

## Verification wrinkle: `outb`/`inb` are privileged instructions

Both are ring-0-only on real x86 — executing them in a normal Linux userspace process traps
(`SIGSEGV`). DCDart's usual conformance-test convention (compile → link → run as a normal Linux
process → check exit code) cannot apply here at all; running the compiled object would crash the test
harness itself, not the program under test. `core/tests/conformance/m2-port/run.sh` verifies
**structurally** instead: `dcc build` succeeds, `verify-freestanding.sh` passes (inline asm has no
symbol dependency, so this also confirms the new instructions introduced nothing runtime-visible), and
`llvm-objdump -d` on the resulting object confirms the exact expected instruction counts and mnemonics.
The real end-to-end proof that this *works* — executing as actual ring-0 kernel code — happens in
`oscortex_core`'s own M0 target, running under full-system QEMU emulation, not in DCDart's own test
suite.

## Consequences

- `docs/known-gaps.md` gets a new entry (below) noting this real, narrow capability now exists, and
  that general `asm`/`@naked`/extern-FFI remain correctly out of scope — not built speculatively
  alongside this.
- `u16` joins `u8`/`u32`/`u64` as a real, constructible sized-int type. No operators (`+`/`<`/etc.)
  were added for it — nothing needs them yet, same discipline as `u8`/`u32` before this.
- Void-returning calls as statements now work for this one recognized shape (`Port.outb`). A general
  `@bare`-to-`@bare` void call as a statement (the other half of the gap `dcc-lower/README.md` flagged)
  remains unimplemented — add it against a real target when one needs it, not speculatively here.
- `oscortex_core`'s own M0 kernel can now genuinely initialize and drive a 16550 UART — the next real
  unit of work is the kernel itself (boot stub, `kmain.dart`, link script, QEMU-based conformance
  harness), not further DCDart language work, unless the kernel surfaces another real gap the same way
  this one did.
