# Escalation 0009: monomorphization multiplies `cls` values and code size, and M3 measures neither

**Status:** OPEN — not decided. Escalated because `CLAUDE.md` rule 4 freezes spec §3 at M3, and
ADR-0054 changed *how many* of the entities §3.1's header points at exist, without changing the
header. Nothing here blocks any current work.

**Numbering note:** 0008 was claimed by a closure-capture escalation being filed in parallel; this
took 0009 to avoid a collision rather than because 0008 is used. A hole is cheaper than a collision.

**The short answer, since it is what everyone will want first:** ADR-0054 did **not** change the
object header, the layout rules, the ARC conventions or any `@bare` runtime symbol. Rule 4 is not
tripped. What it changed is that the number of distinct destructors, and the amount of code, now
scale with the number of instantiations — and **M3 is the gate that measures DCDart's cost, and it
measures neither of those.** This is the same argument escalation 0007 makes about atomic refcounts,
applied to the other thing spec §4.2 chose deliberately.

## 1. What ADR-0054 actually did to §3.1

Nothing, directly. `Alloc` still writes the destructor's link name into the header's `cls` field
exactly as ADR-0022 defined, `Release` still dispatches through it, and the 16-byte header is
byte-identical. A generic class adds no DC-IR instruction, no backend knowledge and no runtime
symbol.

Two second-order facts are worth putting on the record before the freeze:

**`cls` is a destructor slot, not a type identity, and monomorphization makes that visible.**
`Box<u64>` and `Box<Node>` are the same source class. `Box<u64>` has `cls == null` — no destructor,
nothing to release. `Box<Node>` has `cls == &Box$Node_dtor`. So two objects of "the same class" carry
different `cls` values, and one carries none at all. Under the current contract that is exactly
right: the field means "how do I die", and they die differently.

It stops being right the moment anything wants `cls` to answer "what am I". Escalation 0004 §7
already flagged that the `cls` field's fate must be decided before the freeze, in the context of
reflection. This is the sibling observation from the other side: **whatever `cls` becomes, generic
classes have already multiplied the number of distinct answers it would have to encode**, and a
`Box<u64>` has no slot to put one in, because it has no destructor to point at.

I am not proposing to change it. I am recording that "add a type identity to `cls` later" is now
strictly more expensive than it was before ADR-0054, and that the freeze should be taken with that
priced in rather than discovered afterwards.

## 2. The measurement, which is the part with a deadline

Spec §4.2 chose monomorphization deliberately, and its known cost is code size. ADR-0052 said, in as
many words, *"Nothing measures it yet."* ADR-0054 multiplied what there is to measure — instantiations
now carry field layouts, destructors and full method bodies, not just function specializations — and
**still nothing measures it.**

M3's gate is a geometric mean of ≤10% ARC overhead versus C. Code size is not in that number, and it
should not be shoehorned in. But M3 is the one time the five-benchmark suite gets built, run and
characterised, and the containers those benchmarks need are precisely the code that instantiates
generics. After M3 the memory model freezes, the stdlib gets written against it, and "how much does
monomorphization actually cost us" becomes a question nobody can cheaply answer on a clean baseline
again.

What I am asking for is small and mechanical, not a design:

1. **Record object-file size per benchmark**, and the count of emitted instantiations
   (`_HeapLayouts.instantiations.length` plus the specialization count — both already exist in the
   compiler, neither is printed). A one-line addition to a build the M3 unit is running anyway.
2. **Record the ratio** of instantiated bytes to hand-written-concrete-container bytes for at least
   the hashmap, which is the benchmark generics exist for. The concrete version is what the kernel
   already writes today, so the comparison is against real code rather than a hypothetical.

If the ratio is small, §4.2's choice is vindicated with evidence instead of by analogy to Rust and
C++, and the bounds in ADR-0054 can be raised without anxiety. If it is large, that is a fact worth
knowing *before* the stdlib is written monomorphically end to end, because retrofitting any sharing
strategy — outlining identical bodies, a dictionary-passing path for cold code — after the stdlib
exists is a different and much worse project than allowing for it now.

**This is cheap now and awkward later**, which is the same argument escalation 0007 makes for
measuring both refcount modes, and I think it should be handled the same way: as scope on the M3
benchmark unit, not as follow-up work.

## 3. Options

**Option 1 — Do nothing; declare code size out of scope for M3.**
Defensible: M3's stated gate is ARC overhead, and adding a second axis invites scope creep. The cost
is that the language commits to monomorphization for its whole stdlib with zero data, and the first
real number arrives when someone complains about a binary.

**Option 2 (recommended) — Add the two measurements above to the M3 benchmark unit, gate on neither.**
They are recorded and published, not thresholds. Nothing can fail because of them. This is deliberate:
a threshold nobody has evidence for is worse than a number nobody has yet, and the whole point is to
acquire the evidence that a threshold would need.

**Option 3 — Add a code-size threshold to M3's gate.**
Premature. There is no baseline to set it against, and setting one by intuition would either be
trivially met or block M3 for a reason nobody can justify.

**Option 4 — Design a sharing mechanism now (outlining, or dictionary passing for cold code).**
Rejected as premature for the same reason, and it would violate this ADR's own best property: today
every pass downstream of `dcc-lower` is unaware that generics exist. A sharing mechanism is exactly
what ends that.

## 4. Recommendation

**Option 2**, plus one sentence in spec §3.1 recorded alongside the header layout when it freezes:
that `cls` is the destructor slot and carries no type identity, and that under monomorphization two
instances of one source class may hold different `cls` values or none. Today that is true,
undocumented, and indistinguishable from an oversight — the same defect escalation 0007 identified in
the thread-locality of heap references, and worth fixing the same way.

I do not recommend deciding the fate of the `cls` field here. That is escalation 0004's question and
it needs the reflection decision alongside it; this document only asks that the answer be priced with
monomorphization in view.

## 5. What proceeds without waiting

Everything. ADR-0054 is complete, its conformance target passes, the suite is 36/36, and nothing in
this document changes a line of it. The only thing that should not happen is M3 being declared green
having measured neither the code size of the strategy §4.2 chose nor — per escalation 0007 — the
refcount mode it assumed.
