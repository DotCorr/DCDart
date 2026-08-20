# Escalation 0005: The condition system — spec §5 structurally forbids the OS's core promise

**Status:** ESCALATED, NOT DECIDED. Nothing implemented. This is the language-side half of the thesis
recorded in `escalations/0004-runtime-reflection.md`; read that one first.

## 1. The requirement

Stated by the project owner, 2026-08-20:

> Exactly like Genera — you can live-patch an app if it's in a bad state, and now an LLM does that for
> you. No crashes.

Unpacked, that is a specific and demanding sequence: a program reaches a bad state → it **suspends
instead of dying** → something with full type knowledge inspects the live, still-intact state → it
produces a fix → the fix is installed into the running program → **execution resumes from the point of
failure**, not from a restart of the process. The novel part versus Genera is only the operator: a
model rather than a human at the console. Every mechanism underneath is the same, and every one of them
is missing today.

## 2. Why spec §5 blocks this, structurally

§5 specifies `Result<T, E>` with `?`/`.propagate()`, and `panic()` for unrecoverable states. Both
destroy exactly what resumption needs:

- **`panic()` halts.** Halting is the negation of the requirement.
- **`Result` propagation unwinds by construction.** `.propagate()` is an early return. By the time an
  error reaches a caller that knows what to do about it, every frame between the failure and the
  handler is *gone* — along with the locals, the partial state, and the exact instruction to resume
  at. The information needed to fix and continue is destroyed by the mechanism that reports the error.

This is the same reason exceptions cannot deliver this either, in any language that has them: `catch`
runs *after* unwinding. **The distinguishing property of a condition system is that the handler runs
BEFORE the stack is unwound, on top of the still-live failing frame.** That single property is what
makes `restart-case` possible, and it is the one thing that cannot be retrofitted later — it is a
decision about what the calling convention and the error path are allowed to destroy.

## 3. Restarts are the LLM's action space — this is the part that gets forgotten

A condition system is not "the debugger opens on error." It is: code at each level **declares, in
advance, what recovery is possible** — retry this operation, use this value instead, skip this record,
reallocate and continue, abort to this level. Common Lisp spells these `restart-case`; the handler
chooses among them by name.

Without declared restarts, an inspector can look but has nowhere to resume *to*, and the only available
action is still "die." **For an AI operator this matters more than it did for a human one:** the set of
live restarts is precisely the action space the model selects from. A human at a Genera console could
improvise; a model is far safer and far more useful choosing from an enumerated, type-checked set of
resumption points the program itself declared legal. Restarts turn "let an LLM edit my running kernel"
from something reckless into something bounded.

**Design consequence:** restarts should be a first-class declared construct, and they should be
*introspectable* — a suspended program must be able to report its available restarts, with their names,
parameters and types, through the same descriptor machinery escalation 0004 describes.

## 4. `Result` is not the enemy and should not be replaced

The recommendation is **not** to remove `Result<T, E>`. The two mechanisms answer different questions
and every mature system that has both keeps both:

- **`Result`** — *expected* failures that are part of the API contract. File not found. Buffer full.
  Parse error. The caller knows about these and should be forced to handle them. This is exactly what
  §5 got right and it should not be given up.
- **Conditions** — *exceptional* states where the immediate code genuinely does not know what the right
  answer is, and something with more context does. Allocation failure. Hardware fault. Invariant
  violation. Today these all funnel into `panic()`, which is where the crashes come from.

**The concrete proposal: `panic()` becomes `signal()`.** Every site that currently halts instead
suspends and offers restarts. `panic()` survives only as the terminal case where no handler exists and
no restart was declared — which in a fully built-out system should be vanishingly rare, and is itself a
useful signal about missing restarts.

## 5. A correction to escalation 0004 §4 — patch points, not indirection

Escalation 0004 warned that *intercession* (changing behaviour at runtime) costs indirection at every
call site and would defeat M3's ≤10%-vs-C gate. That framing was too pessimistic and should be revised
there once this is decided.

Live patching does not require standing indirection. It requires the *ability to install* it. The
established technique — Linux `ftrace`/`kpatch`, DTrace, Erlang hot code loading — is a **patch point**:
a few reserved bytes at function entry, a no-op in the normal case, rewritten to a jump when a patch is
installed.

The cost profile is completely different from indirection:

- **Unpatched:** one multi-byte `nop`. Not a branch, not a load, no indirect call, no devirtualization
  loss, no inlining loss. Effectively free.
- **Patched:** one direct jump, on exactly the functions actually under repair.

So **universal patchability is affordable, where universal intercession is not.** Every function can be
patchable at near-zero cost; only functions actually being operated on pay anything. Combined with
0004's "introspection is static data," this means the full thesis — every program knows what it is, and
every program can be operated on live — is compatible with the ≤10% gate. That is a much better answer
than the one 0004 gave, and it removes what looked like a forced choice between the thesis and the
performance gate.

## 6. The dependency nobody has named: this requires a resident compiler

**To install a fix into a running program, something must compile the fix, on the machine, while the
program is suspended.** Genera and Smalltalk had the compiler in the image; that is not incidental to
how they worked, it is the precondition.

Today `dcc` is, in its own words, "plain hosted Dart bootstrap tooling" — a cross-compiler that runs on
a developer's macOS or Linux box and emits objects for a target. **Nothing in this project can compile
anything on OSCortex itself.** For live patching to exist as described:

1. DCDart needs a working `@hosted` mode. It currently throws — `--mode hosted` is unimplemented and
   `runtime/dc-core/` is empty.
2. DCDart must **self-host** — a DCDart compiler written in DCDart, running as an OSCortex program.
   Today the compiler is written in Dart and needs the Dart VM.
3. That self-hosted compiler must run *on* OSCortex, which means OSCortex needs processes, a scheduler,
   virtual memory, a filesystem, and a libc-class runtime first.

**This is almost certainly the largest unplanned item in the project**, it is on no roadmap in either
repo, and every part of the live-patching promise sits behind it. It should be named as a milestone now
rather than discovered at the point someone tries to build the patcher.

A cheaper intermediate that preserves the demo and most of the value: **patches are compiled off-box by
a developer machine or an agent, shipped in, validated against the suspended program's descriptors, and
installed.** That gets live patching without self-hosting, and it is the right first step. It just is
not the end state, and the difference should be written down so nobody mistakes one for the other.

## 7. Where the supervisor lives — one place to improve on Genera

Genera ran the debugger inside the same image as the patient. That is what made it feel seamless, and it
is also why a bad enough error took the whole machine with it.

Recommendation: the supervisor — the thing holding the LLM's hands — should be **out of band**, with
full reflective access to the suspended process but its own address space and its own stack. The
patient suspends; the supervisor is untouched by whatever broke the patient. For a kernel that intends
to survive its own faults, this is not a refinement, it is the difference between "self-healing" and
"a more elaborate way to die."

## 8. Safety, since the operator is a model

Not optional if an LLM installs code into a running kernel:

- **Validate the patch against the live descriptors before installing** — signature, types, and layout
  checked against the actual running object graph, not against a source tree that may have drifted.
- **Atomic install with rollback.** A patch that makes things worse must be revertible from the
  supervisor, which is out of band precisely so it still can.
- **Restarts bound the action space** (§3). The model chooses among declared, type-checked resumption
  points rather than writing arbitrary control flow into a live kernel.
- **An audit log of every patch**, because a self-modifying system with no record of how it got to its
  current state is not debuggable by anyone, human or model.

## 9. What this needs from the rest of the project

- **Stack maps and typed frames** — shared with escalation 0004 §3.3. Needed to inspect a suspended
  frame at all. Note again that §0 cites stack maps as a reason to reject tracing GC; they are required
  here regardless.
- **Static `.rodata` emission** — 0004 §5. Restart tables and condition descriptors are static data.
  Still the blocking prerequisite for everything.
- **A calling convention that preserves enough frame information to resume.** This is the item that
  touches **spec §3 and CLAUDE.md rule 4**, and therefore must be decided **before M3**, or resumable
  conditions can never be added without breaking the freeze.

## 10. Recommendation

1. Keep `Result<T, E>` for expected failures, unchanged. It is right.
2. Add conditions as a **separate axis** for exceptional states, with handlers running **before**
   unwinding, and `panic()` demoted to the no-handler-no-restart terminal case.
3. Make restarts a declared, introspectable construct — they are the AI operator's action space.
4. Adopt **patch points** rather than standing indirection (§5), and revise 0004 §4 accordingly.
5. Name the **self-hosting/resident-compiler** milestone explicitly (§6), and adopt off-box patch
   compilation as the deliberate first step rather than an accident.
6. Decide the frame/calling-convention question **before M3**.

## 11. What proceeds without waiting

All current work. Extern FFI (ADR-0038) and `oscortex_core` M1 are unaffected. The item that should
start immediately regardless of how this is decided is static `.rodata` emission, which is already
blocking a kernel milestone on its own merits.
