# Escalation 0007: ARC's refcounts are non-atomic, and that is a spec §3.1 decision nobody has made

**Status:** OPEN — not decided, not implemented either way. Escalated because `CLAUDE.md` rule 4
freezes §3 at M3 and this is a §3 question currently being answered by default rather than by
decision.

**The short answer, since it is what everyone will want first:** non-atomic retain/release is **NOT a
correctness bug today** — it is structurally unreachable on one core, because no DCDart function can
be an interrupt handler and there are no threads. It also does **NOT need SMP** to become one: the
nearest trigger is `@interrupt` landing, which is single-core and on `oscortex_core`'s near roadmap.
And the decision's urgency does not come from either — it comes from M3 measuring a number that is
only meaningful once this is settled. See §2.

**No current work is blocked.** ADR-0055 and ADR-0056 shipped without touching this. What should not
happen is M3 being declared green before this is answered.

## 1. The finding

`backend/lib/llvm_emit.dart`'s `_emitRetain` is, verbatim:

```
%strong    = load i32, ptr %header
%newstrong = add i32 %strong, 1
store i32 %newstrong, ptr %header
```

`_emitRelease`, `_emitMakeWeak`, `_emitWeakLoad` and `_emitDropWeak` are the same shape. So is the
free-list push in `_emitFreeSlotPushback`, and `@dc_free_top` is a module-global.

**Every refcount update in DCDart is a non-atomic read-modify-write.** It is precisely the shape
GAP-0039 was filed about, one layer down — and unlike a `@bss` tick counter, this one is emitted by
the compiler without anyone asking, on every ownership transfer, in every program.

This was found while building ADR-0055, not by an audit. Building atomics is what made the
inconsistency visible: the language now has a way to say "this update is indivisible", and the
compiler's own most frequent update does not use it.

## 2. Is this a correctness bug TODAY? No. Does it need SMP to become one? Also no.

Both halves matter, and the second is the one that gets mis-stated.

**Today: not a bug, and unreachable for a structural reason rather than by luck.** A non-atomic
read-modify-write is corrupted only by *reentrancy* — something must run between the load and the
store and touch the same counter. On a single core the only reentrancy source is an interrupt, so
corruption requires an interrupt handler that itself performs ARC on the same object. **No DCDart
function can be an interrupt handler.** `@interrupt` does not exist in the prelude, `@naked` does
not exist, and there is no general inline `asm` (GAP-0019); `oscortex_core`'s ISRs are hand-written
assembly, which does no DCDart ARC. There are no threads (spec §12 open decision 1, unresolved) and
no second core. There is presently no mechanism by which DCDart-emitted code can be reentered at
all. Recursion is not reentrancy in the relevant sense — same stack, same sequence.

So: **not a live correctness bug. Do not treat this as an incident.**

**But "only at SMP" is wrong, and it is the framing that would get this deprioritised.** SMP is the
LAST of three triggers, not the first:

1. **`@interrupt` landing, with any handler that touches an ARC'd object. Single core. No SMP
   required.** `oscortex_core` already has an interrupts milestone, so this is the nearest trigger by
   a wide margin. Spec §6 does forbid it — `@interrupt` "forbids allocation, blocking, ARC on shared
   state" — and that is the interesting part: **the spec already knows, and wrote the mitigation
   before anyone noticed it was one.** The prohibition is prose. Nothing in the compiler enforces it
   (GAP-0019), so the day `@interrupt` exists, the guardrail is a sentence in a spec.
2. **A `@hosted` thread model.** Spec §0 already promises "OS threads + channels" as the redesign of
   `dart:isolate`. The moment a channel can carry a reference, this is live.
3. **SMP bring-up.** Two cores retaining the same object lose a count and free an object still
   referenced — a use-after-free, not a leak.

**And the schedule pressure does not depend on any of the three.** Even if this stayed unreachable
forever, M3's number is measured against non-atomic refcounts; if the answer is later "atomic", that
number measured a different language. Reachability governs how urgent the *fix* is. Rule 4 governs
how urgent the *decision* is, and those are not the same clock. This document is about the second.

## 2a. Atomic counters would be necessary, not sufficient

Worth stating because it changes the size of the eventual fix, and therefore the cost of deciding
late. Swapping three instructions in `_emitRetain` is the easy part. Two protocols would each need
re-deriving under concurrency:

- **`_emitRelease` is a decide-then-act**: decrement, compare to zero, run the destructor, check the
  weak count, push the slot onto the free list. Making the decrement atomic gives the right answer to
  "did I bring it to zero" (an `atomicrmw sub` returns the previous value), but the destructor, the
  weak-count check and the free-list push are separate steps afterwards.
- **ADR-0023's zombie-slot protocol** — `strong == 0` but not yet freed while a weak reference
  survives — is a two-counter invariant. Two counters made individually atomic do not make a
  two-counter invariant atomic.

So the honest cost of answering "atomic" after M3 is not a three-line patch; it is re-deriving
`Release` and the weak protocol against a concurrency model that would by then be frozen.

## 3. Why it must be settled before M3, not after

Two independent reasons, and the second is the one that actually forces the schedule.

**Rule 4.** §3.1's header is `[LOAD-BEARING]` and frozen after M3. Whether `strong`/`weak` are
atomically updated is a property of that header's contract, not an implementation detail: it changes
what a `Weak<T>` read is allowed to observe, whether the zombie-slot protocol in ADR-0023 is sound
under concurrency, and whether the arena free list needs a lock. Escalation 0004 §7 already flagged
that the `cls` field's fate must be decided before the freeze. This is the sibling question on the
same 16 bytes, and it was not on anyone's list.

**M3's number is invalid if this changes afterwards.** This is the sharper reason. M3's gate is a
geometric mean of ≤10% overhead vs C, and atomic reference counting is the single largest known cost
in an ARC implementation — a `lock`-prefixed RMW is on the order of tens of cycles against roughly one
for a plain increment, and it is unelidable exactly where elision matters least (escaped, shared
objects). A suite measured with non-atomic refcounts that later become atomic does not need
re-running; it needs **re-deciding**, because the number it produced was measuring a different
language. Spec §3.2 puts elision at "the whole ballgame" and M3 is where that claim is tested.

## 4. Options

**Option 1 — Non-atomic forever; heap objects are thread-local by construction.**
The Rust `Rc` position. Cheapest, and it composes with spec §3.4's stable-pointer FFI story
unchanged. Requires a `Send`/`Sync`-shaped discipline the type system does not have and which is
itself a large §4 addition. Without that discipline it is not a decision, it is the current situation
with a document attached.

**Option 2 — Atomic always.**
The Swift/Objective-C position. Correct everywhere, needs no new type-system machinery, and is the
only option that is safe under a thread model nobody has designed yet. Costs the M3 gate real
percentage points on exactly the reference-heavy code M3 measures. Swift's own answer to that cost was
years of ARC optimizer work, which is the work spec §3.2 already schedules.

**Option 3 — Two types: non-atomic and atomic, chosen at the reference site.**
The Rust `Rc`/`Arc` split. Correct and fast, and the only option that lets the hot path stay one
`incl`. It doubles the ARC conventions (§3.2's five elision passes each need to know which they are
looking at), needs the type system to prevent a non-atomic reference escaping to another thread, and
is unambiguously a §3 + §4 change.

**Option 4 — Non-atomic by default, atomic under an annotation.**
Cheapest correct-looking option and the most dangerous, because the failure mode of forgetting the
annotation is a use-after-free that reproduces under load and never under a debugger. This is
escalation 0004's own argument about opt-in reflection, in a place where the cost of being wrong is
much higher: the interesting object is the one that did not set the flag.

## 5. Recommendation

**Ratify option 1 explicitly and narrowly, for M0–M3 only, with two conditions.** Not because it is
the right long-term answer — option 3 probably is — but because it is the only one that can honestly
be decided now: options 2, 3 and 4 all depend on the thread model, which is spec §12 open decision 1
and unresolved. Deciding a concurrency property of the memory model before deciding whether there is
concurrency is how the wrong thing gets frozen.

The two conditions are what make it a decision rather than a deferral:

1. **Write it into spec §3.1 as a stated limit**, in the same sentence as the header layout: DCDart
   heap references are thread-local; sharing one across threads is undefined and the compiler does
   not detect it. Today this is true, undocumented, and indistinguishable from an oversight.
2. **M3 measures BOTH.** The benchmark suite runs once with the current non-atomic `_emitRetain` and
   once with a `lock`-prefixed variant — which is a small, throwaway change to one function in
   `llvm_emit.dart`, not a design. That produces the one number this decision actually needs: the
   price of option 2. If the delta is small, option 2 becomes obviously right and the whole question
   collapses. If it is large, option 3's complexity is justified by evidence rather than by analogy
   to Rust. **This is cheap now and impossible after M3 freezes**, which is the entire argument for
   doing it inside the M3 unit rather than as follow-up work.

I do not recommend deciding options 2, 3 or 4 in this escalation. I recommend that the M3 benchmark
unit be scoped to produce the measurement above, and that this document be reopened with that number
in hand, before the freeze.

## 6. What proceeds without waiting

Everything. ADR-0055 and ADR-0056 are complete and touch none of this — they operate on raw integers
through raw pointers, which raises no §3 question, the same boundary ADR-0051 drew for `@bss`. The
kernel's tick counter and frame bitmap are fixed today regardless of how this is answered. The only
thing that must not happen is M3 being declared green on a number measured without knowing which
language it measured.
