# ADR-0030: Bitwise operators (`&`, `|`, `^`, `<<`, `>>`)

**Status:** VERIFIED — `core/examples/m2-bitwise/bitwise.dart` builds via real `dcc build --mode bare`,
passes `verify-freestanding.sh`, and `core/tests/conformance/m2-bitwise/run.sh` reports an unqualified
PASS under WSL/Ubuntu: real execution (not just structural, since these are ordinary, unprivileged
instructions), `&`/`|`/`^` exhaustive over a real value range at `u64`, `<<`/`>>` over a real range,
and `&` verified at `u32`/`u16`/`u8` too. All 15 pre-existing conformance harnesses re-verified with
zero regressions.

## Context

`oscortex_core`'s next milestone after M0 (boot) is interrupts — IDT setup, PIC remapping, real
register-flag manipulation. All of that needs bitwise operators, which DCDart's own spec lists in its
"Cut" section and which nothing built so far had needed. This is also the exact fix for a known gap
already flagged in `oscortex_core`'s own `docs/known-gaps.md` (GAP-0002/GAP-0001): the UART init in
`kmain.dart` writes without polling the Line Status Register's Transmit-Holding-Register-Empty bit
first, specifically because `LSR & 0x20`-style masking wasn't expressible.

## Decision

**One narrow instruction set, generalized once across the existing four sized-int widths**, rather
than anything wider (no general bit-manipulation "intrinsics" surface, no `Atomic<u32>` combined
mechanism — nothing built needs those yet). `core/dc-ir/lib/instructions.dart` gained `IAnd`/`IOr`/
`IXor`/`IShl`/`IShr` — identical shape to `IAdd`/`ISub`/`IMul`, minus the `Overflow` field (bitwise ops
don't have DCDart's arithmetic overflow-trap semantics; spec §4.1's traps apply to `+`/`-`/`*` only).

**`IShr`'s logical-vs-arithmetic choice lives in the backend, not a new instruction or predicate.**
Unlike `ICmp`, where `ult` vs `slt` are both independently meaningful choices on either signedness,
shift-right's behavior is fully determined by the shifted value's own type — so
`core/backend/lib/llvm_emit.dart` just reads `lhs.type`'s `signed` flag to choose `lshr` vs `ashr`,
which can't go out of sync with the operand the way a separately-tracked flag could. Every current
DCDart sized-int type (`u8`/`u16`/`u32`/`u64`) is unsigned, so this always lowers to `lshr` today —
the `ashr` path exists and is exercised by the backend's own type check, but nothing in the prelude can
reach it yet (no signed sized-int type has real prelude support).

**Prelude operators added to all four widths at once** (`u8`/`u16`/`u32`/`u64`), not just `u64` —
unlike `+`/`-`/`<` (added incrementally, one at a time, as each was separately needed), the real
motivating uses span multiple widths in the SAME milestone (UART status bytes are `u8`, GDT/IDT
segment selectors are `u16`, IDT/GDT entry fields are commonly `u32`), so adding the identical five
operators to all four at once avoided four near-identical follow-up ADRs for no real benefit. `>>`
only, not Dart's `>>>` triple-shift — with every current type unsigned, arithmetic and logical
right-shift are the same operation, so there's nothing for `>>>` to distinguish yet.

**`dcc-lower` generalized to one recognition block instead of twenty.** The existing `u64|+`/`u64|<`/
`u64|-` checks were each their own `if` block (one recognized shape per operator, added incrementally
as ADR-0009/0014/0026 needed them). Adding the same five operators to four widths at once would have
meant twenty near-identical blocks; instead, `target.name.text` (already known empirically to follow a
`"<width>|<op>"` shape) is parsed once via `indexOf('|')`/`substring` — NOT `String.split('|')`, since
the OR operator's own name is literally the character `|`, and splitting `"u64||"`-shaped text on
every `|` would wrongly produce extra empty parts instead of `["u64", "|"]`. Width and operator are
each looked up through a small `switch`, mirroring the same generalization already applied to
`u64(1)`-style literal construction (ADR-0029) once it needed to cover `u8`/`u16`/`u32` too.

## Consequences

- `known-gaps.md` (DCDart repo) records this as the resolution of the bitwise-operator half of the
  "no `asm`/general primitives" gap — general inline asm, `@naked`, and extern-FFI remain correctly
  unimplemented; this ADR doesn't touch any of them.
- `oscortex_core`'s own known-gaps entry for unpolled UART writes can now be fixed for real — tracked
  as a follow-up in that repo, not this one.
- `u64` now has `+`, `-`, `<`, `&`, `|`, `^`, `<<`, `>>`; `u8`/`u16`/`u32` each have `&`, `|`, `^`, `<<`,
  `>>` (construction plus these five, no `+`/`-`/`<` yet — added exactly as needed, same discipline as
  everywhere else in this project, not speculatively ahead of a real use).
