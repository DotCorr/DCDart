# Escalation 0006: ARC semantics for storing a heap reference into a field

**Status: RESOLVED 2026-08-22 by explicit owner delegation — see ADR-0048.** The owner was shown
this escalation, chose not to adjudicate it item by item, and instructed that the decision be taken
and reviewed afterwards rather than blocked on. The recommendation below (option 2) is what was
implemented; the ADR records the risk that made it worth a human's minute, and the exact two call
sites to change if the review reverses it.

Original status was: escalated, not decided. Per `CLAUDE.md`: write it, recommend, then continue on other work.
Nothing is blocked on the answer — the unblocked M3 prerequisites (instance methods, `for` loops,
generics) are being worked in the meantime.

## Why this is an escalation and not an implementation detail

`CLAUDE.md` lists "any change to §3 (memory model)" as escalate-only. A field store holding a heap
reference is an ownership transfer point, and §3.1 says only that the compiler "inserts
`dc_retain`/`dc_release` at ownership transfer points" — it does not say what the convention is at
this particular one. So the convention has to be chosen, and the choice is §3.

**It is also on a deadline that is easy to miss.** Rule 4 freezes the memory model *after M3*. This
decision is a prerequisite of the tree/graph benchmark, which is a prerequisite of M3, which is what
freezes it. If it is inherited from whatever the first implementation happens to do, it gets frozen
without ever having been decided. Deciding it under benchmark pressure is the worst available timing.

## The problem

`a.next = b;` where `next` is heap-typed. Today this is rejected outright (GAP-0020), which is why no
DCDart program can build a linked list, tree, or any mutable data structure — and why four of M3's
five benchmarks cannot be written.

Three sub-questions, and only the third is genuinely open:

1. **Does the store release the old value?** It must. The field held a strong reference; overwriting
   it without releasing leaks, and `examples/m2-heap-field/` already proves the destructor cascade
   depends on fields holding exactly one strong reference each.
2. **Ordering?** Retain-new-before-release-old, always. The reverse breaks self-assignment
   (`a.next = a.next`) by freeing the object between the two operations. This is settled ARC practice,
   not a DCDart choice.
3. **Does the store retain the new value?** *Usually*, but not when the right-hand side is already a
   fresh, unowned +1 — `a.next = Node(...)` hands over the reference `Alloc` just created, and
   retaining it would over-count by one and leak.

## Options for (3)

1. **Always retain, and have the fresh-allocation case release afterwards.** Simple and uniformly
   correct; costs a retain/release pair on the most common shape, which elision pass 3 (ADR-0025)
   would then have to remove.
2. **Retain unless the RHS is a known fresh-ownership source.** Reuses `_isFreshHeapOwnership`, which
   `dcc-lower` already has and already applies to `@owned` parameters (ADR-0021) for exactly this
   reason. No pair is emitted, so nothing has to be elided.
3. **Make field stores `@owned`-style transfers always**, requiring an explicit retain at the call
   site when the caller wants to keep its own reference. Most explicit, most un-Dart-like, and pushes
   refcount reasoning into user code.

## Recommendation

**Option 2**, with (1) and (2) above as settled: release the old value, retain the new one before
releasing the old, and skip the retain when the RHS is a fresh-ownership source.

The reasoning is that it is not a new invention. `_isFreshHeapOwnership` exists, is already the
project's answer to "does this expression hand me a reference I own", and is already applied at the
structurally identical site — passing a fresh allocation to an `@owned` parameter. Option 1 would
emit a pair that ADR-0025's pass then deletes, which is the same outcome by a longer route and only
when that pass fires. Option 3 is a different language.

What makes this worth a human's minute rather than my judgement: option 2 makes correctness depend on
a *static analysis* (`_isFreshHeapOwnership`) being right. If that analysis is ever wrong in the
conservative direction the program leaks; in the aggressive direction it double-frees. Option 1 is
slower but cannot double-free. That is a real safety-versus-cost tradeoff, and it is exactly the kind
of thing rule 4 exists to keep out of an implementation unit's hands.

## What I am doing meanwhile

Not blocking. `for` loops, instance methods and generics are all M3 prerequisites with no memory-model
implications, and they are being built while this waits.
