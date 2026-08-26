# Escalation 0008: Closures need an indirect call, and an indirect call has no computable ownership — the elision model assumes a statically-known callee

**Status:** OPEN — not decided. Escalated because `CLAUDE.md` rule 4 freezes §3 at M3 and a closure
capture convention *is* an ARC convention; and because the enabling mechanism (indirect calls)
removes a fact every elision pass currently relies on.

**No current work is blocked by this document.** The non-capturing subset has since landed
(ADR-0057) and is deliberately built so that it answers none of the questions below — see §6, which
also reports the one number that makes §3 concrete rather than theoretical. What should not happen
is a *capturing* closure lowering landing that answers §2 and §3 by default rather than by decision.

Every claim below was checked against the compiler in this worktree, not inferred from
`known-gaps.md`. Where the earlier draft of this document was imprecise, the text says so.

## 1. The finding: three layers, only the top one is a lowering

**Layer 1 — `dcc-lower` had no closure case at all.** True, and it is the shallow part. It also has
two spellings, which is worth stating because "add a `FunctionExpression` case" undercounts it:
Kernel represents `final f = () => …;` as a `VariableDeclaration` with a `FunctionExpression`
initializer, invoked through `FunctionInvocation` on a `VariableGet`; and `u64 f(u64 v) => …;`
inside a body as a `FunctionDeclaration` *statement*, invoked through `LocalFunctionInvocation`.
Before ADR-0057 the first failed with `unsupported expression FunctionExpression` and the second
with `unsupported statement FunctionDeclaration` — different errors, same missing feature.

Rule 2 is satisfied by fixing this in `dcc-lower`: all four are existing upstream Kernel nodes, so
no Kernel IR node is added. That much of the original brief holds and is now done.

**Layer 2 — DC-IR cannot express a call through a value.** `dc-ir/lib/instructions.dart`:

```dart
final class Call extends DCInstruction {
  final DCValue? dest;
  final String targetName;      // <- a static symbol name, not an operand
  final List<DCValue> args;
  final List<bool> argOwnership;
```

`targetName` is a `String`. There is no `IndirectCall`, no function-pointer `DCType`, no `FuncPtr` —
grepped across `dc-ir/` and `backend/`, zero hits. **Every call DCDart can emit is a direct call to a
symbol known at compile time.** A closure that is stored, passed or returned is by definition a call
through a runtime value, so it needs a new DC-IR instruction plus backend work.

One nuance the earlier draft missed, and it cuts *for* the feasibility of layer 2 while leaving §3
untouched: the backend already emits a real indirect call today. ADR-0022's destructor dispatch
loads a function pointer out of the object header's `cls` field and emits
`call void %clsVal(ptr …)` (`backend/lib/llvm_emit.dart`). So the LLVM side of an indirect call is
not unknown territory — it is special-cased inside `Release`'s codegen for one fixed signature
(`void (ptr)`) with no DC-IR instruction driving it. The missing pieces are a DC-IR instruction, a
function-pointer type, and signature variance. **None of that makes §3 below any easier.**

This is permitted — DC-IR is ours; rule 2 protects *Kernel* IR — but it is a backend change, not a
lowering, and until this commit **no gap recorded it**. That was the single largest under-estimate in
the plan: GAP-0035's table lists closures as one row of seven, alongside rows like `for` loops that
were genuinely one lowering each. Now filed as **GAP-0052**.

**Layer 3 — a capturing closure needs somewhere to put the environment, and `@bare` has no
allocator.** Escalation 0002 (allocator threading, spec §12 open decision 2) is still **OPEN** —
re-read in this worktree to confirm, not assumed. The prelude says the same thing for the analogous
case: `StrBuf` (growable) needs the allocator §12's open decision 2 has not settled, and ADR-0053
shipped borrowed `Str` slices precisely because they need none. **A capturing closure is in
`StrBuf`'s position, not `Str`'s.**

The only heap that exists is ADR-0015's fixed internal arena, which the backend reserves as the
module-globals `dc_arena` / `dc_free_list` / `dc_free_top`. That is a **hidden global heap**, which
`CLAUDE.md` forbids for `@bare` in as many words ("`@bare` code takes an explicit `Allocator`. No
hidden global heap."), and which ADR-0015 itself labels non-authoritative and temporary. Lowering
capturing closures onto it would take a temporary one ADR carefully scoped and make it load-bearing
for a whole language feature.

## 2. The question rule 4 forces: what does a capture mean to ARC?

When a closure captures a heap reference, the compiler must choose a convention. The options are not
stylistic; each is a different answer to "who owns this, and when does it die":

- **By value** for scalars — uncontroversial, no ARC, no decision needed.
- **By strong reference** — the closure retains on capture, releases when the closure dies. Safe,
  and creates exactly the cycle `CLAUDE.md` already names: "Any closure capturing `this` and stored
  in a field is a cycle."
- **By `unowned`/`weak`** — no cycle, but capture can now dangle, and `weak` drags in ADR-0023's
  two-counter zombie-slot protocol onto every captured reference.

Whatever is chosen becomes an ARC convention and freezes after M3 with the rest of §3. This is not
arguable: it is a new entry in the same list rule 4 enumerates ("ARC conventions, `weak`/`unowned`
semantics").

**The cycle question has no good answer that is purely a compiler choice.** Swift's answer is a
capture list (`[weak self]`) — user-visible syntax, i.e. a §4 language-surface addition, not a
lowering. Rust's answer is `move` plus a type system that makes the cycle visible. DCDart has
neither, and `CLAUDE.md`'s cycle rule is **unenforceable** without some syntax to express the fix.
Inventing one inside an implementation unit is what rule 4 exists to prevent.

## 3. The sharper problem: indirect calls break elision

This is why this is an escalation and not only a gap, and it is not in GAP-0035.

`Call.argOwnership` exists, per its own comment, so an elision pass can tell "the callee borrows, so
a Retain/Release pair spanning this call is load-bearing" apart from "the callee consumes, so the
pair is redundant" — ADR-0025's worked example is exactly that ambiguity, and ADR-0031 is the pass
that exploits it. `dcc-lower` computes the fact **from the known callee's signature**.

For a call through a value the callee is not known. `argOwnership` is not conservatively derivable —
it is **not derivable at all**. Assuming "borrowed" is the safe direction, so every closure call site
becomes an **elision barrier**: keep every pair, retain and release across every invocation.

Spec §3.2 calls elision "the whole ballgame". M3's gate is a geometric mean of ≤10% overhead vs C,
and `ROADMAP.md` names **"a closure-heavy functional workload"** as one of the five benchmarks. The
benchmark that most exercises closures is therefore the one where elision is structurally weakest.
That is not a tuning problem discovered late; it is a property of the design, knowable now.

This compounds escalation 0007. 0007 argues M3 must measure atomic vs non-atomic refcounts because
otherwise the number measures a different language. The same argument applies here with more force:
if closures land with every call site an elision barrier, the functional benchmark measures unelided
ARC, and **"closures are slow in DCDart" gets frozen into the compat matrix as a fact about the
language when it is a fact about one missing analysis.**

## 4. Options

**Option 1 — Non-capturing closures only.** A function expression or local function declaration with
an empty capture set is not a closure at run time at all: it is a static function that happened to be
written inside another one. Hoist it, call it directly. **No allocation, no indirect call, no new
DC-IR, no §3 question.** Does not deliver the functional workload — a closure that cannot be passed
as a value is not much of a closure. **This is what landed; see §6.**

**Option 2 — Full closures onto the ADR-0015 arena, strong capture.** Fastest to a green test.
Silently promotes the temporary arena to permanent infrastructure, contradicts "no hidden global
heap" for `@bare`, decides escalation 0002 by accident, and decides §2's capture convention by
default. This is the option that looks like progress and costs the most later. Recommended against
explicitly, because it is what a unit under schedule pressure naturally does.

**Option 3 — Full closures, explicit `Allocator` at the closure site.** Honest and consistent with
escalation 0002's own (non-binding) lean toward explicit. But closure *creation* would take an
allocator parameter, so closures stop being ordinary expressions — a §4 change needing its own ADR,
and it presumes 0002's answer.

**Option 4 — Stack/inline environments for non-escaping closures; defer escaping ones.** A closure
that provably does not outlive its enclosing frame puts its environment in the frame: no heap, no
allocator question, `@bare`-clean, and it covers the `map`/`filter`/callback shapes the functional
workload is mostly made of. Escaping closures stay unsupported and keep their gap row. Strictly more
useful than option 1 and, unlike 2 and 3, it does not need escalation 0002 answered first. It does
need escape analysis, which the compiler does not have — and it still needs GAP-0052's indirect call
the moment such a closure is passed to a function rather than called in place, so §3's elision
barrier arrives with it.

## 5. Recommendation

**Option 1 is landed; scope option 4 as the real closure unit; do not decide §2's capture convention
inside either.**

1. **Do not describe ADR-0057 as "closures"** in the compat matrix or the README. It is
   *non-capturing* closures, and both now say so.
2. **GAP-0052 is filed** for the DC-IR indirect call. Until it existed, every plan touching closures
   under-estimated them, because GAP-0035's table made closures look like one lowering.
3. **Decide the capture convention as its own unit, before M3 freezes §3**, with the
   `[weak self]`-shaped language-surface question decided alongside it — `CLAUDE.md`'s cycle rule is
   unenforceable without syntax to express the fix.
4. **Add the closure-heavy benchmark to escalation 0007's "measure both" list.** If M3 is going to
   measure ARC cost, the indirect-call elision barrier belongs in that measurement, for 0007's own
   reason: cheap now, impossible after the freeze.

## 6. What §3 costs, measured rather than asserted

ADR-0057 landed option 1, and `examples/m2-closure/` contains the pair that turns §3 from an argument
into a number. `viaTopLevel` and `viaClosure` are the same program written two ways — the
`@owned`-consuming callee at top level, versus inside the body:

```
viaTopLevel:          alloc=1 retain=0 release=0
viaClosure:           alloc=1 retain=0 release=0
dropTop:              alloc=0 retain=0 release=1
viaClosure$dropLocal: alloc=0 retain=0 release=1
```

Identical, and the retain/release pair is *gone* in both — ADR-0031's call-consumed elision fires
through the closure call site exactly as through an ordinary one, because the callee is statically
known and `argOwnership` is therefore exact. `tests/conformance/closure/run.sh` asserts the equality
**and** asserts the absolute counts, so the equality can never pass by comparing two unelided
programs.

That is the baseline §3 predicts will be lost. The moment the same callee is reached through a value
rather than a name, `argOwnership` is unknown, the pair comes back, and the second and third lines
above become `retain=1 release=1`. **When someone builds GAP-0052's indirect call, re-run this
harness and diff these four lines.** If they move, that is the elision barrier arriving, measured on
a program that already exists, before the benchmark suite exists to be misled by it.

## 7. What proceeds without waiting

ADR-0057 (landed) and the gap filings. `String`/`StrBuf` (GAP-0045) and generic classes (GAP-0040)
are untouched by this and remain M3 prerequisites alongside capturing closures. Nothing here reopens
ADR-0055 or ADR-0056.
