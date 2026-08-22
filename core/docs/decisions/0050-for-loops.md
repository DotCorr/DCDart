# ADR-0050: `for` loops, desugared to `while`

**Status:** decided — implemented and verified (`tests/conformance/forloop/`)

## Decision

`for (init; cond; update) body` lowers through the existing `while` machinery:

```
init;  while (cond) { body }  with `update` in its own block
```

Desugaring rather than writing a second loop lowering is the whole point. `_lowerWhile` already
carries loop-carried variable analysis, nesting (ADR-0044), `break`/`continue` (ADR-0047), heap-typed
locals (ADR-0048) and the exit-block parameter rule. A parallel implementation would have meant
re-deriving all of it and getting one subtly different — and the two bugs below show how easily that
happens even when reusing.

## The update clause needs its own block, and this is not cosmetic

The obvious desugaring appends the update to the end of the body:

```
while (cond) { body; update; }
```

That is **wrong**, and wrong in the worst direction. Dart's `continue` inside a `for` must still run
the update before re-testing. With the update appended to the body, `continue` branches to the header
and skips it — so `for (i = 0; i < n; i = i + 1) { if (odd) continue; }` never increments `i` on an
odd iteration and **loops forever**. Not a wrong answer: a hang.

So the update gets a dedicated block. `continue` targets that block, the body falls through to it, and
it branches to the header. A `while` has no updates, the block is not created, and its lowering is
byte-identical to before.

## Two silent hangs while building this, both the same shape

Both were infinite loops, neither produced a diagnostic, and both had the same cause: **a statement
carrying a loop-carried assignment that the analysis never walked.**

1. **The update clause was not collected.** `i = i + 1` lives in `stmt.updates`, not in the body, so
   `_collectLoopCarriedCandidates(stmt.body)` never saw it. The header got no phi for `i`, the
   condition compared the initial value forever.
2. Earlier, in ADR-0047, the same failure through `LabeledStatement`.

ADR-0047 made that walker throw on unrecognized *statements*, which was the right fix for the shape it
had seen. It did not help here, because the update clause was never handed to the walker at all — the
omission was at the call site, not in the walk. **An exhaustive visitor does not protect you from not
calling it.**

That is worth stating in GAP-0037's terms: the audit question ("what would have to be true for this to
be correct?") applies to *call sites* as much as to refusals. What had to be true was "every statement
that can assign a loop-carried variable is passed to the collector", and nothing checked it.

## Verification

- `sumTo` — the basic form.
- `nested` — a `for` inside a `for`, exercising ADR-0044 through the new path.
- `withBreak` — `break` out of a `for`, which required threading `LabeledStatement` through the
  desugaring (the CFE wraps a `for` exactly as it wraps a `while`).
- `withContinue` — the case above. It hangs under the naive desugaring.

## Consequences

- Another M3 prerequisite closed. Remaining: generics and `String`.
- `for (;;)` is rejected: the desugaring needs a condition expression, and an unconditional loop has
  no tested path. `while (true)` is equally unsupported for the same reason.
- `for-in` is untouched — it needs an iterator protocol, which needs generics and interfaces.
