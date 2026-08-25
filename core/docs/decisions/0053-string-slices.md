# ADR-0053: String slices — `Str` as a borrowed `{ptr, len}` fat pointer

**Status:** decided under delegated authority — implemented and verified (`tests/conformance/str/`)

**Escalation status, stated first because it governs how to read the rest.** Spec §7 (strings) is on
`CLAUDE.md`'s escalate-only list alongside §3 and §4.1. The owner delegated the remaining M3
decisions explicitly ("take whatever step to get to the goal with no compromise, I would give you my
feedback after it's done"), so this was decided rather than escalated, and it is recorded here with
its reversal path so the delegation is reviewable rather than merely asserted. Same handling as
ADR-0048 and ADR-0051.

## Context

`Str` is one of GAP-0035's M3 prerequisites (**not the last — see below**). Nothing in `@bare` could hold text at all: string literals were
rejected by lowering, so a kernel could not name a device, print a panic message, or compare a
filesystem entry.

The constraint that decides the shape is that this type has to work **before a heap exists**.
`oscortex_core` parses FAT 8.3 names and multiboot strings during early boot, `@interrupt` functions
are forbidden from allocating by the compiler, and spec §12's open decision 2 (the allocator) is
unsettled. A text type that needs an allocator is a text type the kernel cannot use where it most
needs one.

## Decision

`Str` is a **borrowed, non-owning UTF-8 slice**: `{ ptr: Pointer<u8>, len: u64 }`, passed by value,
lowered to LLVM `{ptr, i64}`. String literals are emitted into `.rodata` as `internal constant
[N x i8]` and interned by exact byte content. `length` is **bytes**. `address` yields the `u64` of
element 0.

Three properties follow, and all three are why this shape was chosen over the alternative:

- **Allocation-free slicing.** A substring is an offset and a shorter length. FAT 8.3 names can be
  split in place, `argv` can be split without copying, an ELF section name is a slice into the
  section-name table that already exists in memory.
- **No allocator dependency at all**, so it works in `@bare`, in `@interrupt`, and before the heap.
- **No ARC involvement**, so it does not interact with the memory model this milestone is about to
  freeze. A `Str` is two machine words with no ownership; there is no retain, no release, and
  nothing for elision to get wrong.

The rejected alternative was a length-prefixed blob (`ptr` alone, with the length stored in front of
the bytes). It is one word instead of two and needs no fat-pointer support in the backend. It was
rejected because **every slice becomes an allocation**: taking a substring means writing a new length
header somewhere, which is exactly the operation that cannot happen in the places this type exists
to serve. `dc-sys-21` reached the same conclusion independently from the kernel side, which is worth
recording — the agreement was arrived at twice rather than propagated once.

### `length` is BYTES, and this is the largest deliberate divergence from Dart

`"héllo".length` is **6** in DCDart and **5** in upstream Dart. Dart's `String.length` counts UTF-16
code units; `Str.length` counts UTF-8 bytes.

This is not a detail to be listed in a compatibility table and forgotten. It is a value that is
silently correct for pure-ASCII text and silently wrong the first time a non-ASCII byte appears,
which is the worst available failure shape — it will pass every test anyone writes by hand and fail
in the field. So it is asserted rather than documented, twice and independently, in
`tests/conformance/str/`: once at runtime (`utf8Len()` must return 6) and once on the emitted IR
(`@dc.str.2` must be `[6 x i8]`, since a 5-element global would mean the literal was *measured* in
code units rather than merely reported that way).

It is also the reason `Str` is a distinct type rather than a `String` alias. `Str` is an
`extension type const Str(String _value)`, which was not the first attempt: exposing `.length` on
plain `String` resolved to `dart:core`'s `String.length` and returned an `int` of UTF-16 code units.
The frontend answered a question we did not ask, correctly, and the only way to stop it was to make
the receiver a type `dart:core` does not own.

### Interning is by exact bytes, and identical literals share one global

Two occurrences of `"shared"` produce one `@dc.str.N`. This matters beyond code size: `Str` carries
no identity, so nothing observable distinguishes the two, and merging them is free.

The check that interning is by **content** and not by something looser is the second half. The
conformance target declares five distinct literals and writes one of them twice, then asserts exactly
five globals. Keying on length would collapse `"hello"` and `"héllo"` — both five source characters —
and a runtime address comparison alone would not notice, because it only ever compares literals that
*should* match.

### Dead literals cost zero bytes, which makes object-level checks subtle

`Str("hello").length` folds to the constant `5`, which leaves the pointer dead, and LLVM then drops
the unreferenced `internal` global entirely. So `"hello"` is **correctly absent** from the object
file while `"ABC"` — the literal that `sumBytes` actually walks — is present.

This is the behaviour we want (an unused literal should not occupy `.rodata` in a kernel image), but
it is a trap for any test that greps an object for a literal it declared. `tests/conformance/str/`
asserts bytes only for the dereferenced literal, and says why in the harness rather than leaving the
next person to rediscover it from a confusing failure.

## What this does NOT do

**`String` and `StrBuf` are not here.** Spec §7 specifies an owning, heap-allocated `String` and a
mutable `StrBuf`. Both require the allocator that spec §12's open decision 2 has not settled, so
neither is implemented and neither is decided here. There is no concatenation, no formatting, no
`toString`, and no way to produce a `Str` that does not already exist somewhere in memory. GAP-0045.

**No UTF-8 validation and no decoding.** `Str` asserts its bytes are UTF-8 by construction from a
literal; a `Str` built from a raw pointer by a caller is trusted. There is no code-point iterator, no
`runes`, no case mapping, no comparison beyond bytes. A `Str` over invalid UTF-8 is not detected.

**Nothing prevents a dangling `Str`.** It is non-owning by design, so a `Str` into a freed buffer is
a use-after-free with no ARC and no borrow checker to stop it. Today every `Str` in existence points
into `.rodata` and is immortal, so this is latent rather than live — but it becomes live the moment
`String` lands, and it is the first thing a lifetime story has to answer. GAP-0046.

**This does not make M3 reachable, in two separate ways, and an earlier draft of this ADR got the
first one wrong.** That draft said `Str` was "the last M3 prerequisite". It is not, and the error is
worth recording because it is the kind that makes a project think it is one step from a gate it is
three steps from. GAP-0035's own table still lists **closures** (`unsupported expression
FunctionExpression` — there is no `FunctionExpression` handling anywhere in `lower.dart`, confirmed
by reading it, not by trusting the table), and ADR-0052 opened **GAP-0040, generic classes**, which
blocks the hashmap benchmark. `ROADMAP.md`'s five-benchmark suite is not writable until both land.
Credit where due: `dc-sys-21` caught this and I verified it rather than accepting it.

**The second way is the memory model, and it is the one with a deadline.**
`docs/escalations/0007-arc-refcount-atomicity.md` is now answered: ARC retain/release counts are
**not atomic**, and that is not a correctness bug today. It is unreachable *structurally* rather
than by luck — a non-atomic read-modify-write is corrupted only by reentrancy, on one core the only
reentrancy source is an interrupt, and no DCDart function can be an interrupt handler today
(`@interrupt` and `@naked` do not exist in the prelude and there is no general inline `asm`,
GAP-0019). Not an incident.

**But the deadline is not reachability, it is measurement.** M3's gate is a number — geometric mean
ARC overhead ≤10% vs C — and that number will be measured against non-atomic refcounts. If the
answer later turns out to be "atomic", the number measured a different language. And flipping it
afterwards is not a small patch: atomic counters would be necessary but not sufficient, because
`_emitRelease` is a decide-then-act sequence (decrement, compare, destruct, check weak, push free
slot) and ADR-0023's zombie-slot protocol is a two-counter invariant. Answering "atomic" after the
freeze means re-deriving `Release` and the weak protocol against a concurrency model that is already
frozen.

**So this ADR attaches one condition to M3, and it is cheap today and impossible later:**

> **M3 must measure ARC overhead in BOTH refcount modes, atomic and non-atomic, and record both
> numbers.** Making retain/release atomic is a throwaway change to one function right now. After the
> freeze it is not available at all. The freeze should be taken with the cost of atomicity known
> rather than assumed.

Also worth writing down, because it is the genuinely interesting finding: spec §6 already forbids
`@interrupt` functions from touching ARC'd shared state. **The spec wrote the mitigation before
anyone realised it was one** — and it is prose that nothing enforces. When `@interrupt` lands, that
sentence needs to become a compiler check, not a paragraph.

## Consequences

- **Reversal path.** The externally visible commitments are `Str`'s two-word layout, byte-counted
  `length`, and content interning. Layout is reversible while `Str` crosses no published ABI boundary
  — it is not yet in any emitted C header, because `c_header.dart` has no mapping for it (GAP-0047),
  and adding one is the point of no return. Byte-counted `length` is the *hard* one to reverse: it is
  reversible in the compiler at any time and unreversible in every program written against it,
  because the change is silent for ASCII. If this is to be revisited, it must be revisited before
  anyone writes non-trivial text code, not after.
- **A requirement on whoever implements `String`:** it must not be `Str` with an owner bit. Reusing
  one type for borrowed and owned text is how a language ends up unable to answer "may I keep this?"
  at a call site. Two types, with an explicit widening from `String` to `Str`.
- `Str` has no `c_header.dart` mapping, so a `@bare` function taking or returning one cannot be
  called from C yet. `{ptr, len}` by value is representable in the C ABI, so this is unimplemented
  rather than blocked. GAP-0047.
- The `PtrToInt` DC-IR instruction was added for `Str.address` and is general — it is the missing
  half of the existing `IntToPtr`, and pointer-to-integer comparison now works for every pointer,
  not only for slices.
