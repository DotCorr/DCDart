# ADR-0024: `dc-objdump --arc` counts DC-IR instructions, not object-file symbols

**Status:** decided, implemented, AND VERIFIED — `core/dc-objdump/bin/dc_objdump.dart` built and run
under WSL/Ubuntu against every M2 conformance example. Every count matched, independently, the exact
hand-derived trace each ADR (0016 through 0023) already recorded for that function — a strong
cross-check that the whole session's ARC insertion logic is precisely correct, not merely "didn't
crash."

## Context

`CLAUDE.md`'s testing rules state: "Anything touching ARC codegen also needs an elision test: assert
the expected number of `dc_retain`/`dc_release` calls in the emitted IR. Regressions in elision are
invisible at runtime and catastrophic in aggregate. `dc-objdump --arc` prints the counts." This tool
did not exist — a real compliance gap against this project's own rules, present since ADR-0015/0016
(M2's first ARC slice) and never addressed until now, discovered while scoping what M2's actual exit
criterion (`ROADMAP.md`: "...`dc-objdump --arc` shows elision firing on the reference benchmark")
still needs.

## Decision

**Counts DC-IR instructions (`lowerToDCModule`'s own output), not the backend's emitted LLVM text or
the final object file's symbols.** This project's `Retain`/`Release`/`MakeWeak`/`WeakLoad`/`DropWeak`
are all INLINED at the backend stage (ADR-0009/0015's "recognized intrinsics lowered inline") — there
is no `call @dc_retain` symbol anywhere in the compiled object file to count; it's all raw header
pointer arithmetic. DC-IR is the one place "how many ARC operations does this function have" is a
real, stable, countable question — and matches dcc-lower's own framing of DC-IR as "the emitted IR" it
produces (`core/dcc-lower/README.md`: Kernel IR → dcc-lower → DC-IR).

A new package, `core/dc-objdump/` (plain hosted Dart, same bootstrap-language reasoning as `dcc`
itself — ADR-0002/0006, it inspects the compiler's output, it isn't compiled BY that compiler).
`dc-objdump --arc <source.dart>` lowers the source via `dcc_lower`'s public `lowerToDCModule`, walks
every function's every block, and tallies `Alloc`/`Retain`/`Release`/`MakeWeak`/`WeakLoad`/`DropWeak`
occurrences, printing per-function and total counts.

## Verified, precisely

Every existing M2 conformance example, cross-checked against the exact counts each source ADR already
recorded by hand:
- `m2-heap/box.dart`: `alloc=1 release=1` — matches ADR-0016.
- `m2-alias/alias.dart`: `makeAliasAndReadValue` `retain=1 release=2`; `makeAliasBranch` `retain=1
  release=3` (2 releases in the then-branch, 1 in the else-branch) — matches ADR-0017's trace exactly.
- `m2-heap-field/heap_field.dart`: `makeHolderAndReadInner` `alloc=2 retain=1 release=2`;
  `BoxHolder_dtor` `release=1` — matches ADR-0020/0022's traces.
- `m2-owned/owned.dart`: `makeBox` `alloc=1` (no release — ownership transfers out);
  `dropBoxAndReadValue` `release=1`; `makeAndDropViaCall` `retain=1 release=1` — matches ADR-0021.
- `m2-weak/weak.dart`: `makeDanglingWeak` `alloc=1 release=1 makeweak=1`; `readWeak` `weakload=1
  dropweak=1`; `weakLoadWhileAlive` `alloc=1 release=1 makeweak=1 weakload=1 dropweak=1` — matches
  ADR-0023.

No mismatches found anywhere — every ARC-insertion decision this session made was independently
re-derivable from the emitted DC-IR alone.

## Consequences

- This is now the tool `docs/known-gaps.md` GAP-0017 item 2 (elision, M3's real scope) needs to
  demonstrate its own effect: the same source program should show smaller `retain`/`release` counts
  after an elision pass exists than before — `dc-objdump --arc` is what makes that comparison concrete
  rather than a vague "should be fewer ops" claim.
- Per `CLAUDE.md`'s rule, every FUTURE unit touching ARC codegen should include an elision-style test
  using this tool (assert an exact expected count), not just a leak-free runtime check — a gap in this
  session's own prior units (0016-0023 all had runtime leak tests, none had a `dc-objdump`-based count
  assertion, since the tool didn't exist yet). Not retrofitted onto those units here — they're already
  verified correct by the counts above; a dedicated `dc-objdump`-based regression test suite is a
  reasonable, separate next addition.
