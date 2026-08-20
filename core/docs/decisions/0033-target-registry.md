# ADR-0033: A target registry, and `--target` as a separate axis from `--mode`

**Status:** decided — implemented and verified on macOS/arm64 (native Mach-O) and Linux/x86-64 (ELF)

## Context

`dcc/lib/pipeline.dart` hardcoded one line:

```dart
const targetTriple = 'x86_64-unknown-none-elf';
```

That single constant was the *only* thing preventing DCDart from producing native macOS, Windows or
Linux object files. Everything downstream was already target-agnostic and nobody had noticed:

- `emitModule` and `compileToObject` both already accept a `targetTriple` parameter.
- The emitted LLVM IR has no `datalayout` line, no `dso_local`, and no explicit calling convention
  (`m0-target.md` §1 decided this deliberately, to keep the C ABI plain).
- The trap machinery uses `llvm.trap` and `llvm.*.with.overflow.*`, which are recognized-by-name
  intrinsics on every LLVM target, not x86-only.

The one genuinely non-portable construct is `Port.outb`/`Port.inb` (ADR-0029), which emits x86
`outb`/`inb` inline asm.

Proof this was the only blocker: passing `arm64-apple-macosx` to the existing, unmodified backend
produced a Mach-O object that linked into an ordinary macOS binary and ran correctly on the first
attempt. 17 of the 18 example targets — including the entire ARC suite (heap objects, weak
references, the destructor cascade, `@owned` transfer) — ran natively on arm64 with no codegen change
whatsoever. Only `m2-port` failed, exactly as predicted.

## The conflation that caused the problem

`--mode` (spec §2, `bare` vs `hosted`) had been doing double duty in people's heads. It actually
answers a completely different question from "which machine":

| | question | values |
|---|---|---|
| `--mode` | which language subset and runtime may the source use | `bare` (no allocator/ORC/threads/throw), `hosted` (needs a runtime nobody has built) |
| `--target` | which machine, OS and object format to emit | x86-64/aarch64 × none/linux/macos/windows |

These are orthogonal. A `@bare` object file is a plain C-ABI object file, so it links into an
ordinary hosted C program with real libc — `examples/demo-collatz/main.c` had been doing exactly that
since ADR-0032, which is the clue that was sitting in the repo the whole time.

So `--mode bare --target macos-arm64` is a legitimate, now-verified combination. It emphatically does
**not** mean hosted mode is implemented.

## Options

1. Accept an arbitrary LLVM triple string on `--target` and pass it through to `clang`.
2. A closed registry of targets the backend has actually been tested against, rejecting anything else.
3. Keep the hardcoded triple and add a separate `--native` boolean flag.

## Decision

**Option 2.** `core/backend/lib/targets.dart` defines a `DCTarget` — triple plus the facts the
compiler needs to decide things (`arch`, `os`, `objectFormat`) — with eight registered targets
(x86-64 and aarch64 × bare/linux/macos/windows), short aliases (`macos-arm64`), and a `host` alias
that resolves the machine `dcc` is running on. `DCTarget.defaultTarget` is the original
`x86_64-unknown-none-elf`, so every pre-existing invocation compiles byte-for-byte what it did before.

Rejected option 1 because an unrecognized triple would produce an object file nobody has ever tested,
which is precisely what `CLAUDE.md`'s testing rules exist to prevent. An honest "not supported yet"
listing the eight that are is more useful than a silent maybe.

Rejected option 3 because a boolean cannot express cross-compilation, and the whole point is that the
axis has more than two values.

`checkFeatureSupport(target, usesPortIo:)` rejects the one real target/feature mismatch *before*
invoking `clang`. Without it, building `m2-port` for arm64 fails deep inside clang with a message
about an invalid asm operand that never mentions `Port.outb`. With it:

```
dcc build: this program uses Port.outb/Port.inb, which emit x86 `outb`/`inb`
instructions (docs/decisions/0029-port-io.md), but --target macos-arm64 is
aarch64. Port I/O is x86-only (and ring-0-only). Build this program for an
x86-64 target, or drop the port I/O.
```

## Consequences

- DCDart now compiles to native code on every platform C targets, which was the point. Verified end
  to end on macOS/arm64: `dcc build --target host` → plain `clang` link against real libc → runs.
- The freestanding guarantee is unchanged and still checked. A `--target host` object is still
  freestanding-clean; targeting an OS does not link a runtime in.
- `--mode hosted` still throws. Nothing here implemented spec §2's hosted runtime, and the error says
  so.
- Adding a ninth target means adding a real conformance target for it, not just an enum case.
- The default stays `bare-x86_64` deliberately. Changing the default to `host` would silently change
  what all sixteen existing harnesses compile, and their step 3 is Linux/x86-64-specific for reasons
  unrelated to this ADR.
