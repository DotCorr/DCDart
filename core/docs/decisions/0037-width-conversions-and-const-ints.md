# ADR-0037: Explicit width conversions (`.toU32()`), and accepting named `const int`s

**Status:** decided — implemented and verified (`examples/demo-stats/` runs correctly)

## Context

Both changes here were found the same way ADR-0032's were: by writing a real program rather than a
single-ADR conformance target. `examples/demo-stats/stats.dart` walks a `u32` array that the C caller
owns, computing sum, mean, max and a threshold count — the first DCDart program to do pointer
arithmetic over a buffer rather than read one fixed address.

It failed to compile twice, for two unrelated reasons.

### Gap 1 — no way to widen an integer, at all

Summing a `u32` array into a `u64` accumulator requires widening. There was no way to express it.
Not "no convenient way" — no way at all: the extension types' representation field is `_value`,
library-private, so a program outside the prelude cannot reach it, and there is no cast that gets
around a private member.

DCDART_SPEC.md §4.1 had already decided what should exist:

> No implicit widening or narrowing. `u8 → u32` requires `.toU32()`. Explicit is the entire point.

So this was unimplemented spec, not an open design question — no escalation needed (`CLAUDE.md`'s
escalation rule covers *changes* to §4.1, and this changes nothing).

### Gap 2 — named constants were rejected while bare literals worked

`const int stride = 4;` then `u64(stride)` failed with "only integer-literal arguments are handled",
while `u64(4)` succeeded. By the time lowering sees it, the CFE has evaluated the named constant and
replaced the reference with a `ConstantExpression` wrapping an `IntConstant` — a different node from
`IntLiteral`, though both denote the same compile-time integer.

## Decision

### Conversions: one instruction, not three

New `IConvert { dest, source }`. The direction is derived from the two types already present, rather
than being a field:

- dest wider → `zext` if the source is unsigned, `sext` if signed
- dest narrower → `trunc`
- equal widths → no-op (still emitted as `add 0`, since `dest` must be a defined SSA name)

Rejecting the alternative of three instructions (`ZExt`/`SExt`/`Trunc`) for the same reason `IShr`
derives `lshr` vs `ashr` from its operand instead of being two instructions: separate opcodes let a
caller construct a combination that contradicts the types, and that is not a state worth being able
to represent.

**Narrowing truncates and does not trap.** That is deliberate and consistent with spec §4.1: writing
`.toU8()` *is* the safety mechanism. The programmer said the word "narrow", so the discarded high
bits are the stated intent — unlike an arithmetic overflow, which is always an accident and therefore
traps.

Prelude gains `toU8()`, `toU16()`, `toU32()`, `toU64()` on all four widths (16 methods). Lowering
recognizes them in the same `"<width>|<op>"` block as the operators, but on a **unary** path: an
extension-type method call passes only the receiver positionally, so it cannot reuse the binary
helper.

`sext` is unreachable today (no signed prelude types) but is written now because the alternative —
`zext` unconditionally — is wrong in a way that is invisible until the first negative number is
widened, long after whoever wrote it has moved on.

### Constants: accept both node shapes

Lowering now accepts an `IntLiteral` **or** a `ConstantExpression` wrapping an `IntConstant`.
Rejecting one while accepting the other is a distinction with no reason behind it, and it pushes
programs toward magic numbers: `demo-stats` wanted a named `_u32Bytes = 4` precisely because a bare
`4` repeated across three functions is how the classic pointer-arithmetic bug gets written.

## Consequences

- Array traversal is expressible: `Pointer<u32>.fromAddress(base + i * u64(4))` needed `*` (ADR-0035)
  and the mean needed `~/` (ADR-0036); this ADR supplies the last missing piece, the widening.
  Verified end to end — C `malloc`s and fills a buffer, DCDart walks it, every value hand-checked.
- Named `const int`s work, so code can name its constants.
- `dc-elide` needed an `IConvert` case. As with ADR-0036, the sealed `DCInstruction` hierarchy forced
  it rather than leaving it to be noticed later.
- Conversions between an integer and a pointer, or between a `u64` and `f64`, are still absent —
  neither has a reachable use, and floats have no backend at all.
- Still no source-level array *type*. This is pointer arithmetic by hand, which is exactly what C
  offers and no more; a real slice/array type with bounds information is a separate, larger design.
