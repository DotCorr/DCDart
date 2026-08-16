# Escalation 0002: Allocator threading model (DCDART_SPEC.md §12, open decision 2)

**Status:** escalated, not decided. Per `CLAUDE.md`: "Write the escalation... then continue on other
work. Do not block." Proceeding with M2's ARC work using a clearly-labeled, non-authoritative
temporary allocator (see `docs/decisions/0015-m2-minimal-arc-arena.md`) — this does NOT resolve the
question below, and that ADR says so explicitly.

## The problem

`DCDART_SPEC.md` §12 lists this as one of five decisions the spec's own authors call "genuinely
undecided... do not let an agent silently pick one":

> **Allocator threading.** Explicit parameter everywhere (Zig) vs. implicit context (Odin). Explicit
> is more honest and much noisier.

This determines how every `@bare` allocation call is spelled for the rest of the project's life —
`alloc(myAllocator, size)` threaded through every function that might allocate transitively, vs. some
form of ambient/thread-local allocator context. It's explicitly listed as must-close-before-M4, and
M2 (ARC) is the first milestone that actually needs to allocate anything.

## Options (as the spec itself frames them)

1. **Explicit parameter (Zig-style).** Every function that allocates (directly or transitively)
   takes an `Allocator` argument. Fully honest about cost — a function's signature tells you whether
   it allocates. Noisy: an `Allocator` parameter propagates through call chains that have nothing to
   do with allocation strategy otherwise.
2. **Implicit context (Odin-style).** An ambient allocator (thread-local or similar) that allocation
   calls read without it appearing in every signature. Quieter call sites; hides allocation cost from
   a function's type, and in `@bare` specifically raises real questions about what "thread-local"
   even means before a scheduler exists (M4+).

## Why this isn't decided here

This is a genuine, load-bearing API design choice with real ergonomic and correctness trade-offs
across the entire `@bare` surface — not a case where one option is obviously right and the spec is
just being cautious. The spec's own framing ("more honest and much noisier") shows both sides have
real weight. Deciding it inside an M2 implementation unit, under the pressure of "get ARC working,"
is exactly the failure mode `CLAUDE.md`'s escalation rule exists to prevent — a rushed choice made
for local convenience, not the tradeoff's actual merits, then permanently baked into DC-IR's call
surface once M2/M3 code depends on it.

## Recommendation (non-binding)

Lean explicit (option 1), for the reason the spec itself half-concedes: `@bare` is kernel/driver code
where allocation failure and cost are first-class concerns (spec §5's `panic()` model, §2's "no hidden
global heap" for `@bare`) — the noise is arguably the point, the same way Zig's explicit allocators
are noisy on purpose in exactly this domain. But this is a recommendation for whoever actually decides
it, not a decision — a real evaluation should look at what M2's actual call patterns turn out to need
once more of the ARC insertion logic exists, not be made speculatively now.

## What proceeds without waiting

`docs/decisions/0015-m2-minimal-arc-arena.md` implements just enough allocation to prove the `DCObject`
header/`Retain`/`Release` mechanics (which §3.1 *does* fully specify — this escalation is about the
`Allocator` *interface/threading*, not the header layout or refcount semantics) using a fixed internal
arena that is explicitly NOT presented as resolving this question, and will need to be replaced once
a real `Allocator` design is chosen.
