# Escalation 0001: `?` postfix propagation is not valid Dart syntax

**Status:** decided provisionally (per `CLAUDE.md`: "Write the escalation... then continue on other
work. Do not block."). Recommendation acted on below; revisit if a human disagrees.

## The problem

`DCDART_SPEC.md` §5: `?` postfix operator propagates `Err` (`final page = allocPage()?;`). Every
other DCDart syntax extension built so far (`@bare`, `u64`/`u32`/`u8`, `Pointer<T>`, `@packed`/
`Struct`) was expressible as ordinary Dart in `core/runtime/dc-core-bare/prelude.dart` — extension
types, annotation classes, plain classes — letting real, unmodified, vendored `pkg/front_end` parse
and type-check it with zero source changes (ADR-0008). `?` as a bare postfix operator on an arbitrary
expression is not something Dart's grammar has at all. There is no library-level trick that makes
`expr?` parse; this needs an actual change to the parser.

## Options

1. **Fork `pkg/front_end`'s parser.** Add `?` as valid postfix syntax, desugar it during CFE lowering
   into existing Kernel IR node shapes (a let-binding + conditional, no new Kernel IR node needed —
   consistent with `CLAUDE.md` rule 2, "the answer is almost always a lowering in dcc-lower... not a
   new node," except here the lowering would live in front_end's own desugaring, not dcc-lower, since
   dcc-lower only sees Kernel IR after the fact). Real, faithful to spec. Also real, substantial
   compiler-frontend engineering: modifying `pkg/front_end`'s scanner/parser/resolver — thousands of
   lines of code this project has no ability to run the existing regression suite against, no CI, and
   no reviewer deeply familiar with the CFE's internals to catch subtle breakage (error recovery,
   IDE/LSP tooling that also depends on front_end, incremental compilation assumptions).
2. **Named-method approximation.** A method call — e.g. `result.propagate()` — recognized by
   `dcc-lower` via Kernel IR shape matching, exactly the same pattern already used for
   `Pointer<T>.value`/struct field access (ADR-0010/0011). Valid, ordinary Dart; zero front_end
   changes; immediately buildable and verifiable with the exact toolchain and discipline already
   proven across four prior features this session. Not literally `?` — a real syntax gap, honestly
   labeled as such, not silently presented as equivalent.

## Recommendation: Option 2, for now

The risk profile is the deciding factor, not preference. Option 1 is real engineering this project
will eventually need (true builtin syntax is explicitly the long-term goal per ADR-0008), but
attempting a parser fork with no way to verify it doesn't break anything else in front_end is exactly
the kind of unverified, guessed-at change this project's culture (`CLAUDE.md`, `SKILL.md`) rejects —
"don't guess, verify against reality" has held for every decision so far specifically because each
one WAS empirically checked against a running toolchain. A parser change can't be spot-checked the
same way; it needs either deep CFE expertise or front_end's own test suite, neither available here.

Option 2 keeps the exact same verification discipline intact and produces a real, working
`Result<T,E>` propagation mechanism today. It is not a permanent decision — `core/frontend/vendor/
dart-sdk/pkg/front_end` remains vendored and ready (ADR-0005/0007) for whenever this project has the
dedicated capacity for real parser work, at which point `propagate()` becomes sugar for `?` rather
than the only way to write it, and existing DCDart source keeps compiling either way (dcc-lower would
just gain a second recognized shape for the same semantics).

## What this decision does NOT resolve

Naming (`propagate()` vs. something else) and the exact recognized shape are implementation details
for whoever builds it, not fixed by this escalation — track in `docs/known-gaps.md` GAP-0007 as that
work proceeds.
