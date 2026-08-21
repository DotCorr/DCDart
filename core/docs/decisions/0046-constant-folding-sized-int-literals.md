# ADR-0046: Fold compile-time integer arithmetic in sized-int literals

**Status:** decided — implemented and verified

## Context

`u64(ataIdModelFirst - 1)` was rejected with:

> the argument must be an integer literal or a compile-time integer constant

while being exactly that. `ataIdModelFirst` is a `const int` and `27 - 1` is a compile-time constant by
any definition. **The error message described a rule the code did not implement.**

ADR-0037 had already widened this check once — from `IntLiteral` only to `IntLiteral` *or*
`ConstantExpression(IntConstant)` — after `demo-stats` hit the named-constant case. That fix took the
same shape as the bug: it widened the *pattern match* rather than making the check evaluate anything.
A constant expression that the CFE has not pre-folded still fails.

The CFE does not pre-fold it because an argument position is not a `const` context, so `first - 1`
arrives as a live `InstanceInvocation` of `dart:core`'s `int.-`.

Found by `oscortex_core`'s ATA driver, which paid for it with two extra named constants per site.
It is the **third** instance of the pattern GAP-0037 describes — a refusal narrower than its own
message — after nested `while` loops and the `break` exit-block assumption.

## Decision

Evaluate instead of pattern-matching. `_tryFoldConstInt` folds `+ - * ~/ % << >> & | ^` over operands
that are themselves foldable, recursively, and returns null for anything else.

**Reads `expr.name.text`, never `interfaceTarget`.** The operator belongs to `dart:core`'s `int`,
which is an unbound reference under `--no-link-platform` and throws on inspection. The invoked *name*
is a plain `Name` on the node itself and is always safe. This is the same trap ADR-0014 hit with
`bool` and ADR-0040 hit with `List` — third time, which is why it is called out here rather than
noted in passing.

**Deliberately not a general constant evaluator.** Integers only: no bools, no strings, no
user-defined `const` constructors. Those would each need their own representation decisions and none
has a caller. Division and modulo by zero return null — treated as non-constant rather than throwing,
because a compile-time division by zero deserves its own diagnostic rather than a crash inside the
folder. Shift counts outside 0–63 likewise.

## Verification

Folding: `first - 1`, `(sectorWords * 2) - (first + 1)` (nested, both directions), `base + 7`,
`1 << 20`, `0xFF & 0x3C`, `sectorWords ~/ 4` — all built natively and hand-checked against expected
values.

Rejection still works: a `final int` initialised at runtime still fails with the original message, so
the check was widened rather than removed.

## Consequences

- Kernel code can write `u64(ataIdModelFirst - 1)` and `u16(base + 7)` instead of declaring a named
  constant per site.
- **The pattern is now a class, not a coincidence**, and GAP-0037 says so. Three refusals in one day
  turned out to be narrower than their stated reason, and the common thread is that all three were
  written as *shape checks* — matching AST node types — where the stated rule was *semantic*. A shape
  check that is described in semantic language will drift from its own documentation the moment a new
  shape expresses the same meaning.
- ADR-0037's fix is superseded rather than wrong: it correctly added the shape that existed then. The
  lesson is that widening a pattern-match is what invited the same bug twice.
