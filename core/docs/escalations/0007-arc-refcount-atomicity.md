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

---

## 7. This is one concurrency model with three consumers, not three questions

**Added after the fact, from the DCDart side, because this document is what gets read at freeze
time and the scope above is narrower than the decision actually is.**

Sections 1–6 frame this as a question about refcounts. It is not. Three separate mechanisms have now
been built that each assume single-threaded, interrupt-free execution, each for locally good reasons,
each recorded honestly — and **they cannot be answered independently without ending up mutually
incoherent:**

| # | mechanism | what is non-atomic | recorded in |
|---|---|---|---|
| 1 | **ARC refcounts** | `retain`/`release` are load-add-store | this escalation |
| 2 | **The heap** | bump cursors and free-list heads are plain loads and stores | ADR-0058 |
| 3 | **IPC channels** (`oscortex_core` M20) | SPSC free-running counters with a stated publication order and deliberately no fences | `oscortex_core` GAP-0165 |

**Why they are one decision.** A design with atomic refcounts and a non-atomic free list is not a
partial fix, it is an incoherent one: `release` would correctly reach zero from two threads exactly
once, then both would race on the free-list head and produce a cycle in the list or a double-free.
The refcount's atomicity buys nothing unless the allocator's does too. The same holds in the other
direction — a thread-safe allocator under non-atomic refcounts protects the wrong layer, since the
corruption happens before `free` is ever called.

**The IPC case is worth reading closely, because the agent that built it made the right call for a
reason that generalises.** It declined to use ADR-0055's atomics. Not from ignorance: on one core
with interrupts clear they are pure cost, and using them would have **disguised** the single-core
dependency rather than removed it — a fence that does not actually establish the property still
looks, to a later reader, exactly like one that does. So the dependency is recorded explicitly
instead of being papered over. That is the correct treatment for all three, and it is why none of
this is an incident: every one of them is a *stated* assumption, not a hidden one.

**What this changes about the recommendation.** §5 recommends reopening this document with M3's
measurement in hand. That still holds, with one addition: the measurement and the decision must cover
the allocator as well as the refcounts, because **the cost of atomicity is not a refcount property —
it is the sum across all three mechanisms**, and measuring only the refcount half would understate it
in exactly the direction that makes "just make it atomic later" sound cheaper than it is.

Concretely, for whoever holds this at freeze time: the question is not *"should retain/release be
atomic?"* It is *"what is DCDart's concurrency model, and what do refcounts, the allocator and any
shared-memory channel each have to guarantee under it?"* Answering the narrow question first and
deriving the others from it is how the three end up disagreeing.

---

## 8. §5's requested measurement, taken

§5 recommended that this document be reopened with M3's number in hand rather than deciding
atomicity speculatively. The measurement now exists (`bench/`), so here it is.

**Cost of atomic refcounts on a workload that actually executes ARC: 2.79×.**

`arc-churn` allocates and releases one short-lived heap object per iteration — one `Release` per
iteration, nothing else:

| configuration | median | vs C |
|---|---|---|
| C baseline (`malloc`/`free`) | 49.9 ms | 1.00× |
| DCDart, non-atomic refcounts | 57.5 ms | 1.15× |
| DCDart, atomic refcounts | 160.6 ms | 3.22× |

### 3.22× IS NOT THE PRICE OF THREAD SAFETY. IT IS THE FLOOR.

Stated first and in these words, because it is the sentence most likely to be lost when someone
quotes only the headline. **Anyone citing 3.22× as the cost of making DCDart's ARC thread-safe is
quoting the wrong number.** "Atomic mode" makes each contiguous refcount load/add/store an
`atomicrmw seq_cst` and changes nothing else. Still non-atomic in that mode:

- `_emitRelease`'s **decide-then-act** sequence (decrement, compare, destruct, check weak, push free
  slot) — the atomic decrement guarantees exactly one thread sees zero, and then both threads race
  through everything after it.
- ADR-0023's **two-counter zombie protocol**, whose invariant spans the strong and weak counts
  together, which no single-word atomic can establish.
- The **free-list push** (ADR-0058) — plain loads and stores.
- **`WeakLoad`'s retain**, which is emitted across a branch and therefore stays non-atomic even in
  atomic mode. Counted and reported separately by the harness rather than quietly included.

A correct concurrent ARC needs all four. Each is more than an instruction swap, and none of them is
in the 3.22×.

### And only one of the three consumers has been priced at all

Per §7, refcounts, the allocator and `oscortex_core`'s IPC channels are one concurrency model with
three consumers. The scoreboard as of 2026-08-26:

| consumer | atomicity | priced? |
|---|---|---|
| ARC refcounts | non-atomic | **yes — this section** |
| The heap (ADR-0058) | non-atomic bump cursors and free-list heads | **no** |
| `oscortex_core` IPC channels (M20) | SPSC, free-running counters, deliberately no fences | **no** (GAP-0165) |

A real answer pays for all three. One third of the bill is in hand.

**Read this as an upper bound, not a prediction.** `arc-churn` is deliberately unamortised — it does
nothing but allocate and release, so the refcount update is a large fraction of the work. Real code
does something between its retains. The honest statement is that atomicity costs **up to** 2.79× on
the ARC operations themselves, and what that does to a program depends entirely on how much of its
time is ARC.

**Three things that make this number smaller than the true cost of "make ARC atomic", and they are
the reason this section does not close the escalation:**

1. **It prices the instruction, not the correctness.** The rewrite makes each contiguous
   load/add/store an `atomicrmw seq_cst`. It does **not** touch `_emitRelease`'s decide-then-act
   sequence, ADR-0023's two-counter zombie protocol, or the free-list push. A concurrency-correct
   ARC needs all of those, and each is more than an instruction swap.
2. **`WeakLoad`'s retain is emitted across a branch** and therefore stays non-atomic even in atomic
   mode. Counted and reported separately by the harness rather than quietly included.
3. **The allocator is still non-atomic** (ADR-0058). Per §7 above, atomic refcounts over a
   non-atomic free list is not a partial fix, so any real answer pays for both.

**Verified, not assumed: atomic mode does not violate `CLAUDE.md` rule 1.** `bare-x86_64` emits
`lock`-prefixed RMW, `bare-aarch64` an `ldaxr`/`stlxr` loop, `macos-arm64` `ldaddal`;
`verify-freestanding.sh` passes on all three and no `__atomic_*` libcall appears. The cost is
instructions, not a runtime dependency — which removes the one objection that would have made this a
non-decision.

### A separate cost the gate will include, which nobody had priced

The harness's own self-test came out at **1.27× C on `fib`** — a benchmark with no heap and no ARC,
which should have been 1.0×. Chased rather than reported: DCDart's **trapping arithmetic**
(`llvm.uadd.with.overflow` plus a branch to `llvm.trap`) blocks the accumulator-recursion→loop
transform LLVM gives the C version at `-O2`. Compiling the same C source with
`__builtin_add_overflow`/`__builtin_trap` reproduces DCDart's machine-code shape exactly, and against
*that* baseline the residual is **1.000×** — so the harness's flags, linkage and instrument are
right, and 100% of the gap is language semantics.

**That means M3's number will include roughly 25–50% overhead on integer-heavy code that has nothing
to do with ARC.** The gate is stated as "ARC overhead vs C". Trapping arithmetic is not ARC. Whoever
holds the gate has to decide whether the ≤10% target is against C-with-C-semantics or
C-with-DCDart-semantics, and that should be a decision taken deliberately rather than a surprise
discovered while reading a failing gate.
