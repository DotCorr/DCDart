# ADR-0034: `dcc --emit-header` generates the C declarations, instead of callers hand-writing them

**Status:** decided — implemented and verified (C program calls DCDart through the generated header,
including a struct returned by value)

## Context

DCDart already emitted plain C-ABI object files. `m0-target.md` §1 deliberately specified no
`dso_local` and no custom calling convention, which is why `examples/demo-collatz/main.c` could write

```c
extern uint64_t collatzSteps(uint64_t start);
```

and simply link. So the *object* side of "other languages can FFI into us" was finished before this
ADR — nothing about the binary interface needed changing.

What was missing was purely declarative, and it is the dangerous half. Every caller had to hand-write
those `extern` lines and keep them in sync with the Dart source by eye. A wrong prototype is not a
compile error and not a link error: it is silent ABI corruption at the call site. Get `uint32_t` vs
`uint64_t` wrong on one parameter and the program reads garbage, in a way that is invisible in both
sources.

## Options

1. Document the ABI and let callers hand-write `extern` declarations (the status quo).
2. Generate a C header from the lowered DC-IR, as part of the same build that emits the object.
3. Generate bindings for several languages (C, Rust, Python `ctypes`, Go `cgo`).

## Decision

**Option 2.** `core/backend/lib/c_header.dart` walks the same `DCModule` the object file is emitted
from and writes a header: include guard, `<stdint.h>`/`<stddef.h>`/`<stdbool.h>`, `extern "C"` for
C++ callers, `@packed` struct typedefs, an opaque `DCHeapRef`, and one prototype per function.
`dcc build ... --emit-header out.h` produces it alongside the object.

Deriving from DC-IR rather than from Dart source is the whole point: the header cannot disagree with
the object, because both come from the same structure.

Rejected option 3 as premature. Every one of those languages can consume a C header (Rust via
`bindgen`, Python via `cffi`, Go via `cgo`), so C is the one that unlocks the rest. Emitting four
binding formats before a single real consumer exists would be building four things nobody has
validated.

### Type mapping, and the two places it refuses

| DC-IR | C |
|---|---|
| `DCInt(w8..w64, signed)` | `uint8_t`…`uint64_t` / `int8_t`…`int64_t` |
| `DCInt(wSize)` | `size_t` / `ptrdiff_t` |
| `DCVoid` | `void` |
| `DCPointer(T)` | `T *` (`void *` for pointer-to-void) |
| `DCHeapPointer` | `DCHeapRef` (opaque `void *`) |
| `DCWeakPointer` | `DCWeakRef` (opaque `void *`) |
| `DCStruct` | a `@packed` struct typedef |
| `DCBool` | **rejected** |

`ptrdiff_t` rather than `ssize_t` for signed word-size: `ssize_t` is POSIX and absent on MSVC, and
this header has to compile on Windows.

**`DCBool` is refused, not mapped.** It lowers to LLVM `i1`; C's `_Bool` is a full byte whose upper
bits are undefined for an `i1`. Spelling it `bool` would produce a header that compiles, links, and
is silently wrong — exactly the failure this emitter exists to prevent. No DCDart signature can carry
a bool today (comparisons only ever feed `CondBranch`), so this is unreachable rather than a
limitation, and it now fails loudly if that ever changes.

Heap and weak references are deliberately opaque. A DCDart heap object carries an ARC header (spec
§3.1) whose layout is explicitly not frozen; letting C dereference one, or `free()` it, would corrupt
the refcount. The generated comment says so.

## Consequences

- C, C++, Rust, Python, Go and Zig can call DCDart without anyone hand-transcribing a signature.
- Verified for real: a C program including only the generated header — with no `extern` of its own —
  calls a DCDart function returning `Result<u64,u64>` **by value** and reads back the correct tag and
  payload. The struct ABI works across the boundary.
- The header is written only after the object file succeeds, so a failed build never leaves a
  stale-but-plausible `.h` beside a missing `.o`.
- This covers DCDart-called-from-C only. The other direction — DCDart calling an arbitrary external C
  symbol — remains unsolved and is still GAP-0019.
- A struct with a struct-typed field would be emitted in signature order, which is not guaranteed to
  be valid C definition order. Unbuildable in the language today; recorded as GAP-0022 rather than
  solved speculatively.
