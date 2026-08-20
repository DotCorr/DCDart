# ADR-0035: Complete the integer operator set across all four widths, and lower `==`/`!=` from `EqualsCall`

**Status:** decided — implemented and verified (multiplication traps on overflow; real algorithms run
correctly)

## Context

Before this change the language's arithmetic surface was, in full:

- `+`, `-` on **u64 only**
- `<` on **u64 only**
- `&`, `|`, `^`, `<<`, `>>` on all four widths (ADR-0030)

No multiplication at all. No `<=`, `>`, `>=`, `==`, `!=` anywhere. No arithmetic or comparison of any
kind on u8/u16/u32. This is why `examples/demo-collatz/collatz.dart` had to spell `3 * n` as
`n + n + n` and halving as `n >> u64(1)`, and why `demo-account` compared balances with `<` only.

Scoping the work turned up something worth stating plainly: **almost none of this needed new
codegen.** `IMul` has existed in `dc-ir/lib/instructions.dart` since M0 with a real `llvm_emit`
dispatch case (`_emitArith('mul', ...)`), and `ICmpPredicate` has declared all ten LLVM condition
codes (`eq`, `ne`, `ult`, `ule`, `ugt`, `uge`, `slt`, `sle`, `sgt`, `sge`) just as long. The
instructions were sitting there with no source-level operator wired to them. This is a
frontend-recognition change, not a backend change.

## Decision

### 1. Prelude: declare the operators at every width

`*`, `<`, `<=`, `>`, `>=` on u8/u16/u32/u64, and `+`/`-` on the three narrower widths that lacked
them.

### 2. `dcc-lower`: one generalized block, and delete three special cases

ADR-0030 already introduced a generalized `"<width>|<op>"` recognizer (parsing with `indexOf('|')`,
never `split('|')`, since `|` is itself an operator name). Extending that block covers every new
operator at every width at once.

The three dedicated `u64|+` / `u64|<` / `u64|-` blocks that predated it were **removed**, not left
alongside. They would have shadowed the general path for u64 with byte-identical behaviour — the
duplicate-implementations-of-one-concept shape that `SKILL.md`'s coherence sweep exists to catch.

One real subtlety: the generalized block passed `widthType` as the destination type, which is correct
for bitwise and arithmetic ops but **wrong for comparisons**, whose result is a `DCBool`. Dest type is
now chosen per-op alongside the instruction. Getting this wrong would have been silent — an `icmp`
emitted into an `iN` slot.

Comparisons select the **unsigned** predicates (`ult`/`ule`/`ugt`/`uge`), which is correct because
every sized-int type the prelude exposes is unsigned. `llvm_emit` prints `predicate.name` verbatim and
derives no signedness of its own, so a future signed type must choose the `s`-prefixed predicates *at
that recognition site*, not downstream. Recorded here because the failure would be silent.

### 3. `==` / `!=` cannot use that mechanism at all

**Dart refuses to let an extension type declare `operator ==`** — "This extension member conflicts
with Object member '=='", verified against the installed SDK. So there is no `u64|==` procedure for
the prelude to declare or for lowering to match. The CFE emits a structurally different node:
`a == b` becomes an `EqualsCall` bound to `dart:core::Object::==`, and `a != b` becomes
`Not(EqualsCall)`.

Options considered:

1. Named methods — `a.eq(b)` / `a.ne(b)` — which lower cleanly as `u64|eq` StaticInvocations.
2. Recognize `EqualsCall` (and `Not(EqualsCall)`) directly in `_lowerExpression`.

**Option 2.** DCDart's premise is Dart syntax; `a.eq(b)` where every other language writes `a == b`
would be a visible tax on every program forever, to save a small amount of lowering work once.

`!=` is emitted as a single `icmp ne`, not as "compare, then invert". This matters: DC-IR has no NOT
instruction, so the invert form would have needed one.

Operand types are read from the **lowered DC-IR values**, not from front_end's inferred static types.
That follows ADR-0014's rule — under `--no-link-platform` an inferred `bool`/`Object` type is a real
but unbound platform node that crashes on inspection. Mismatched widths are rejected rather than
implicitly converted, since spec §4.1 has no implicit integer conversions.

## Consequences

- Real algorithms are now expressible. Verified running natively: Euclid's gcd, digit-sum, a
  primality test (`i * i <= n`, `n % i == 0`), factorial.
- `*` traps on overflow like `+`/`-` (spec §4.1). Verified: `factorial(20)` returns
  2432902008176640000 (correct, the largest that fits in u64) and `factorial(21)` dies with SIGTRAP
  rather than wrapping.
- All sixteen pre-existing conformance targets still pass with zero changes, including after the three
  dedicated blocks were deleted.
- A general boolean `!` is still unimplemented, and now throws a specific error saying so rather than
  a generic "unsupported expression" (GAP-0023).
- Signed integer types still have no prelude support; the unsigned-predicate choice above is the thing
  to revisit first when they get it.
