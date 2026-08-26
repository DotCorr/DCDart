# Escalation 0011: does DCDart's ARC convention say anything about a RETURN VALUE?

**Raised by:** ADR-0063 (elision across an aliasing `Release`), which closed a use-after-free and
paid a measured ~4% on the `json` benchmark to do it.
**Area:** spec §3 (memory model) — **CLAUDE.md rule 4**, frozen after M3.
**Blocking:** nothing. ADR-0063 landed without it. This asks whether the cost it paid can be bought
back before the freeze, because after M3 it cannot be.

## The question in one line

DCDart says who owns a **parameter** (`@owned`, ADR-0021) and, since ADR-0060, carries that in a
function pointer's type. **It says nothing about whether a returned reference is a fresh `+1` that
nothing else aliases.** Should it?

## Why it came up

ADR-0063 made elision pass 3 invalidate pending retains on any surviving `Release`, because two
DCValues can denote the same object and the pass cannot tell. Exactly three pairs stopped being
elided. The one that costs is in `json`'s `parseArray`:

```dart
final child = parseValue(p);   // %43 -- a Call result
final t = tail;                // %20 -- a Load
...
tail = child;                  // Retain %43 ... Release %20 ... Release %43
```

`Release %20` sits inside the pair, so the pair survives. **It is genuinely unprovable locally:**
`%20` is a `Load` and `%43` is a `Call` result, and nothing in DC-IR says they are different objects.

They *are* different objects — `parseValue` returns a freshly allocated node every time. That fact
exists in the source and is destroyed at the ABI boundary.

## Why this is a §3 question and not a dc-elide question

It is not an analysis that can be strengthened. There is no fact in the callee's DC-IR that the
caller is failing to read; **the fact is not represented anywhere.** Any answer adds something to the
ARC calling convention, which is what rule 4 freezes.

It is also the same shape as the problem ADR-0060 already solved once, in the other direction: escalation
0008 §3 concluded argument ownership was "not conservatively derivable — it is not derivable at all"
through a function pointer, and the answer was to put it **in the type**. This is the return-value
half of that sentence, and it has never been asked.

## Options

**A. Do nothing.** Return values stay unannotated; pass 3 keeps refusing these pairs.
*Cost:* the measured ~4% on `json` stands, and grows with any workload built on "container method
returns a node". That is most of what a stdlib is. *Benefit:* zero risk, zero surface.

**B. `@unique` on a return type — a promise that the returned reference is a fresh `+1` no live
value aliases.** Written by the author, checked by nothing at first.
*Cost:* it is the sixth dangerous annotation, and a wrong one is a double free with no diagnostic —
the exact failure mode CLAUDE.md's "unsafe surface" rule exists for. *Benefit:* smallest possible
change, and it composes with ADR-0060 by riding in `DCFuncPtr` the same way `@owned` does.

**C. Derive it.** A function whose return value is provably a fresh `Alloc` that never escaped before
returning gets the bit inferred, no annotation.
*Cost:* real intraprocedural escape analysis plus a call-graph order; the first thing in the compiler
that is a genuine optimisation pass rather than a lowering. *Benefit:* no new unsafe surface, no
source change, and it would fire on `parseValue` and on every constructor-like function in a stdlib.

**D. Defer past M3 and accept it can never be added.** Explicit, so nobody re-litigates it later
under the impression it is still open.

## Recommendation

**C, with B as its escape hatch, decided before M3 closes.**

C is the version with no new way to write a double free, and the analysis it needs is the same escape
analysis ADR-0063 declined to build for the *caller* side — where it was worthless because the values
in question come from calls. Behind a call is exactly where it pays.

B should exist only as the annotation C's analysis cannot reach (an `extern` C function, an
`asm` body), and if B ships it needs the ADR-0021 treatment: a comment stating the invariant at every
use, and reviewers rejecting uses without one.

**If neither is affordable before the freeze, say so and pick D explicitly.** The thing worth avoiding
is A-by-default — carrying a known ~4% and a known-unrepresentable fact into the frozen model because
nobody chose.

## What is already true regardless of the answer

- The use-after-free is fixed and stays fixed; nothing here reopens it.
- The measurement is mechanical: `bash core/bench/elision-delta.sh bench/benchmarks/json/bench.dart`
  reads `19 -> 19` today. Any option that works moves the second number.
- The intra-block limit measured by GAP-0062 is a **separate** cause with a **separate** fix. Neither
  subsumes the other, and they should not be attempted together.
