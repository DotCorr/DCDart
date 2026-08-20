# Escalation 0004: Reflection is the product, not a feature — DCDART_SPEC.md §0 must be rewritten

**Status:** DECIDED IN PRINCIPLE BY THE PROJECT OWNER (2026-08-20). Design NOT ratified. Nothing
implemented. **This document was rewritten the same day it was written** — the first version
recommended opt-in reflection, and that recommendation was wrong. The reasoning is preserved below,
because how it was wrong is the most useful thing in this file.

## 1. What the owner actually said

Reflection is not a language feature being requested. It is the founding thesis of the operating
system that consumes this language. In the owner's own framing:

> Programs today are zombies. They do things and react to things with no idea what they are. A program
> doesn't know it's a class. It doesn't know this memory is a player's health bar. Zero self-awareness.
> So much of the job today is strapping programs to a table, hooking them to debuggers, and reading
> their thoughts from outside the program space. Every single tool — disassemblers, compilers,
> debuggers — exists to take the information lost on the journey down to machine code and reconstruct
> it. We need programs smart enough to do surgery on themselves without having to crash.

The explicit reference point is the Symbolics Lisp Machine, rebuilt modern. The explicit modern
motivation is that most code is now written by, or with, LLMs — and an introspectable system removes
the read-the-source-guess-the-layout-attach-a-debugger loop that currently sits between an agent and
the thing it is trying to change. Non-native programs (Linux, Windows) are expected to be *simulated*;
native programs are expected to be self-aware by construction.

This is a coherent and historically grounded position. Genera, Smalltalk-80, Self, and Oberon all made
some version of this bet; Singularity and Midori made it again with static typing. The observation
that the entire reverse-engineering toolchain exists to undo the compiler's own information loss is
correct and is not usually stated this plainly.

## 2. Why the first version of this document was wrong

The first version recommended `@reflect` as an opt-in annotation, so that dead-code elimination and
monomorphization would be preserved for every type that did not ask for reflection. That is a sound
recommendation for a systems language that wants to *offer* reflection.

It is the wrong default for this project, for one reason: **opt-in reflection means zombie-by-default,
and zombie-by-default is the exact condition the OS exists to abolish.** A system where
self-awareness is a flag someone remembers to set is a system where the interesting object — the one
you actually need to inspect at 3am, in a driver you didn't write — is the one that didn't set it.

The default must invert. Reflection is on; opting *out* is the annotation, and it should be reserved
for places that genuinely cannot pay: interrupt hot paths, boot code that runs before descriptors
exist, and code where the metadata is provably unreachable.

## 3. The conflation that has to be undone first

"Programs smart enough to do surgery on themselves without having to crash" is four mechanisms, not
one. They have very different costs, and treating them as a single feature is how this gets designed
badly:

1. **Type and layout metadata** — *what is this?* Field names, offsets, types, sizes, supertypes.
   Answers "this memory is `player.health`." This is static data in `.rodata`. **Nearly free at
   runtime.**
2. **Code identity** — a function knowing its own name, signature, source location, and ideally its
   own DC-IR. Enables a program to reason about its own behaviour rather than just its own data.
   **Cheap in time, real in image size.**
3. **Typed stack introspection** — walking your own call stack with typed frames rather than guessing
   from frame-pointer chains. This requires **stack maps**, and it is worth noting the irony: spec §0
   rejects tracing GC partly because it "requires stack maps and safepoints." Self-surgery needs them
   anyway. If we are paying for stack maps regardless, one of §0's stated reasons for rejecting GC
   quietly evaporates — that should be acknowledged rather than left as a silent inconsistency.
4. **A condition system** — the ability to stop at the point of failure with the stack *intact*,
   inspect, repair, and resume. **This is not reflection at all**, and it is the mechanism that
   actually delivers "without having to crash."

Point 4 is the sharpest issue in this document. Spec §5 specifies `Result<T, E>` plus `panic()`, and
`panic()` halts. Halting is the opposite of what was asked for. The Lisp machine's real superpower was
never `describe` — it was `handler-bind`/`restart-case`: an error suspends the computation, a live
debugger opens *inside the running image* with the frame still live, and you can fix and continue.
**Reflection tells you what things are. The condition system is what lets you not die while you fix
them.** Both were named in one sentence; they need separate designs, and §5 currently contradicts the
second one.

## 4. Recommended architecture: split introspection from intercession

This is the recommendation, and it is what makes the thesis survivable alongside this project's other
commitments.

- **Introspection** — *reading* what things are. Type descriptors, field tables, method tables,
  code identity. This is static data plus generated lookup code. It costs image size and dead-code
  elimination. **It costs essentially nothing at runtime.**
- **Intercession** — *changing* behaviour at runtime. Replacing a method, hot-patching a function,
  interposing on a field access. This requires indirection at every affected call site and defeats
  devirtualization and inlining. **This is where the performance goes to die.**

Lisp machines and Smalltalk conflate the two, and pay for both everywhere. **The proposal is:
introspection default-on and total; intercession opt-in per function or module, via an explicit patch
point.**

Why this matters concretely: `ROADMAP.md`'s M3 gate is a geometric mean of **≤10% overhead vs. C**, and
it is described as the gate that nothing downstream starts until it is green. A system with
indirection at every call site will not hit 10%. A system with rich static metadata and statically
bound calls will — the descriptors are `.rodata` that nobody dereferences on the hot path. **This split
is what lets the project have total self-awareness and still pass its own performance gate.** Without
it, one of the two has to be abandoned, and that decision would be far more expensive later.

A program under this design can answer "what am I", "what are my fields", "what is at this address",
"what called me" — completely, always, with no flag set — while a `player.health` load still compiles
to a single `mov`.

## 5. The prerequisite nobody has noticed yet

**DCDart has no static or global data of any kind.** This is not a reflection problem; it is recorded
in `oscortex_core`'s own `docs/known-gaps.md` GAP-0004, discovered because the kernel could read the
Multiboot memory map but had nowhere to *keep* it.

Type descriptors are static data. **Reflection cannot be built at all until static/`.rodata` emission
exists.** That makes static data a hard prerequisite, ahead of every other item here, and it is
currently blocking a kernel milestone independently — which means it should be scoped and built on its
own merits regardless of what happens to this escalation.

## 6. The membrane problem — and what it means for ffmpeg

**C libraries are zombies by construction, and linking them does not fix that.** An FFI call into
ffmpeg hands control to a region with no descriptors, no typed frames, and no self-knowledge. Every
FFI boundary is a hole in the reflective world, and the holes are exactly where the large,
useful, already-written software lives.

This is a genuine tension between two of the project's stated goals ("use the existing C ecosystem"
and "no zombies"), and it deserves an explicit decision rather than being discovered later:

- **FFI it in** — fast, direct, but ffmpeg becomes an opaque organ inside a transparent body. You get
  the capability and lose the property, locally.
- **Simulate it** — the owner's own stated approach for foreign programs. Isolated and honest about
  what it is, at real cost in performance and effort.
- **Describe the boundary** — the interesting middle: the FFI declaration itself carries full
  descriptors, so the *interface* is reflective even though the *implementation* is opaque. The system
  knows exactly what it handed over and what it got back, and can say so, even though it cannot see
  inside. This is cheap, and it is probably the right default.

Recommendation: option 3 as the default, option 2 for anything untrusted or genuinely foreign.

## 7. Why this is time-critical — CLAUDE.md rule 4

Rule 4 freezes the memory model after M3. Reflection lands directly on it:

- If every object's header carries a type-descriptor pointer, that is **spec §3.1**, which is
  `[LOAD-BEARING]` and frozen at M3.
- The `cls` field already exists and already holds a destructor pointer (ADR-0022), and
  `dc-ir/lib/types.dart` already anticipates it becoming "vtable + destructor + layout descriptor." So
  the hook exists. Whether it becomes a full descriptor pointer must be decided **before** the freeze.
- Dynamic `invoke` returning a heap value needs an ownership convention the caller cannot know
  statically. ADR-0019/0021/0031 settle this for statically known calls only.

**If these are not decided before M3, reflection cannot be added afterwards without breaking the
freeze that the entire stdlib and compat matrix depend on.** This is the single most schedule-sensitive
item in the project right now, and it is not currently on any milestone.

## 8. What must happen next

1. **This stops being an escalation and becomes a spec section.** An OS-defining thesis does not
   belong in `docs/escalations/`. §0's non-goals table must be rewritten: reflection moves out of
   "not doing," and the row should say what is now core (total introspection, opt-in intercession,
   real dispatch) and what remains excluded (`dart:mirrors`, `noSuchMethod`, `dynamic` — these force
   *unbounded* metadata and buy nothing the descriptor model doesn't already give).
2. **Ratify or reject the introspection/intercession split (§4).** Everything else depends on it,
   including whether M3's ≤10% gate is still achievable as written.
3. **Scope static/`.rodata` data emission as its own unit (§5).** It is a prerequisite here and an
   active blocker in `oscortex_core` regardless.
4. **Decide the §3.1 header question and the dynamic-call ownership convention before M3 (§7).**
5. **Open a separate escalation for the condition system (§3.4)**, because it contradicts spec §5 and
   is not a reflection question. Next free number is 0005.

## 9. What proceeds without waiting

Nothing here blocks current work. Extern FFI (escalation 0003, ADR-0038) and `oscortex_core`'s M1
interrupts milestone are both independent. Reflection should not be *started* until items 2 and 3 are
answered — building it on the wrong shape costs more than waiting. Item 3 can start immediately.
