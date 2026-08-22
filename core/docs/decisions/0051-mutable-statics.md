# ADR-0051: Mutable static storage — `@bss`

**Status:** decided — **under explicit delegation from the project owner, 2026-08-22**, who approved
the narrow form in principle and then instructed that remaining decisions be taken and reviewed
afterwards rather than blocked on. Implemented and verified (`tests/conformance/bss/`).

## Context

DCDart had no way to keep anything. `oscortex_core` reached the same wall three times: it enumerates
six PCI devices and forgets all six, measures 127 MiB of usable RAM and forgets it, and can now read
any sector on a disk with nowhere to put what it read. It was carrying **424 bytes of
assembly-donated `.bss` across five hand-maintained blocks**, each reached through an `@extern`
address accessor that exists only to route around a missing language feature.

## Why this is decidable without unfreezing the memory model

`CLAUDE.md` rule 4 freezes §3. A global variable *sounds* like a §3 question, and in general it is —
but only for a specific reason: **a global holding an ARC-managed reference becomes an ARC root**,
which needs retain/release semantics, a defined lifetime (released when? never?) and eventually
thread-safety.

A global restricted to raw bytes raises none of those, because there is no reference for ARC to
manage. So the restriction is not a conservative first cut — **it is the entire justification**, and
that is why it is enforced by the compiler rather than stated as a convention. If a `@bss` block could
hold a `HeapObject` even by accident, the frozen decision would have been made silently.

In practice the type system does most of the enforcing: a `@bss` field must be declared `Bss`, so a
`HeapObject`-typed one fails in front_end before `dcc-lower` runs. The explicit check exists anyway,
because "the type system happens to prevent it" is a weaker guarantee than "we check".

## Decision

```dart
@bss final Bss tickCounter = const Bss(bytes: 8);
@bss final Bss idt         = const Bss(bytes: 4096, align: 4096);
```

The same `final` + `const` initializer shape ADR-0040 established for `@rodata`, for the same two
reasons: the `const` initializer makes the **size** compile-time known, and `final` keeps the
declaration's identity and its name at use sites (a `const` field's references are inlined by the CFE,
leaving no name to take the address of).

Read and written through `Bss.addressOf(x)` composed with `Pointer<T>.fromAddress`, identical to
`Rodata.addressOf`. Sharing that surface was deliberate: `@rodata` and `@bss` differ in exactly one
emitted token — `constant` versus `global` — and nothing else about them should differ either.

**`DCZeroInit` is a distinct IR node**, not a `DCConstArray` of zeros, because LLVM's `zeroinitializer`
occupies no space in the object file while an explicit array of zeros does. A 4 KiB page table or a
128 KiB frame bitmap written out literally would bloat every image that used one.

**Alignment is declared, not inferred.** `align: 4096` for a page table or an IDT is a hardware
contract — wrong alignment faults, it does not merely run slowly. A non-power-of-two is rejected
rather than rounded, because silently rounding a hardware requirement is how that fault gets shipped.

**`DCGlobal.isMutable` exists now and deliberately did not before.** ADR-0040 refused to add it while
the decision was unmade, on the grounds that an IR field existing only to be rejected pre-commits the
shape of an escalation nobody has held. That reasoning was right then and is spent now.

## Verification

`tests/conformance/bss/` checks the three properties that distinguish this from everything DCDart
could already emit:

- **zero-initialized** — the first `bumpTicks()` returns 1, not garbage
- **mutable** — a bitmap slot round-trips a written value
- **persistent** — state survives across separate calls, which nothing else in the language provides

Plus: the object stays freestanding-clean (a `.bss` global introduces no undefined symbol), symbol
sizes are exact (8 bytes, 4096 bytes) and land in `.bss`, and the restrictions are enforced —
non-power-of-two alignment, zero size, and a non-`const` size are each rejected by name.

## Consequences

- `oscortex_core`'s physical memory manager is unblocked, and its five hand-maintained donated `.bss`
  blocks become deletable along with their `@extern` accessors.
- **Still not expressible, and still deliberately:** a global holding a `HeapObject` or `Weak<T>`.
  That remains the frozen §3 question, untouched.
- **No initialization order, because there is no initialization.** Everything starts zeroed. A global
  needing a computed initial value must be filled by code at a point the program chooses — which is
  what a kernel wants anyway, and avoids the static-initialization-order problem C++ has.
- **No concurrency story.** A mutable global read and written from an interrupt handler and from
  ordinary code has no atomicity guarantee, and GAP-0033 (no memory barriers) applies directly. Fine
  for a single-core kernel where interrupt entry serializes; not fine at the first SMP bring-up.
  Filed as GAP-0039.
