# Known gaps

Work queue, not a confession log (`CLAUDE.md`). Every entry: what was worked around, and the cost.

---

## GAP-0026 — No signed sized-integer types, so a C `int` parameter has to be declared `u32`

**Domain:** dcc-lower, runtime prelude (M1/M2, surfaced by ADR-0038's extern FFI)
**Status:** OPEN — ABI-correct today, interpretation-incorrect for negative values

`DCDART_SPEC.md` §4.1 `[LOAD-BEARING]` lists `i8 i16 i32 i64 isize` alongside the unsigned widths, and
`dc-ir/lib/types.dart`'s `DCInt` already carries a `signed` flag the backend honours (`IShr` picks
logical vs. arithmetic shift from it, ADR-0030). **The prelude implements only the unsigned half.**
There is no way to write a signed sized integer in DCDart source at all.

Harmless until ADR-0038, because nothing crossed an ABI boundary where the distinction was visible.
It is visible now: `core/examples/ffi-extern/libc_calls.dart` declares `int ffs(int)` as
`u32 ffs(u32)`. That is **ABI-correct** — `int` and `uint32_t` are the same 32-bit register operand on
both SysV-AMD64 and AAPCS64, differing only in interpretation — and every value the conformance target
uses is inside `0..2^31-1`, where the two interpretations agree. It would be **wrong** for a C
function that returns a negative value (`strcmp`, `read`'s `-1`, any `errno`-style API), which DCDart
would read as a huge unsigned number with no diagnostic anywhere.

**Cost of the workaround:** the extern surface is honest only for non-negative values, and the ADR and
the example both say so in a comment rather than leaving it as a trap. Any C API with a negative
sentinel is currently un-declarable correctly. Fixing it is prelude + `_lowerSignatureType` work, not
a backend change — `DCInt.signed` is already threaded through.

---

## GAP-0025 — `Pointer<T>` cannot appear in a function signature, which most real C APIs need

**Domain:** dcc-lower (M1, surfaced by ADR-0038's extern FFI)
**Status:** OPEN — pre-existing limit, not widened by ADR-0038, but now load-bearing

`_lowerSignatureType` maps `u8`/`u16`/`u32`/`u64` (extension types), `Result`, `HeapObject`
subclasses, and `Weak<T>`. It does **not** map `Pointer<T>`, in parameter or return position, and
throws naming the type. `Pointer<T>` has worked since ADR-0010 only as a LOCAL: constructed via
`Pointer<T>.fromAddress(...)`, read/written via `.value`, never passed or returned.

Nothing before ADR-0038 needed it — every conformance target that used a pointer built it inside the
function that used it. Extern FFI makes it immediately load-bearing, because most of libc takes one:
`strlen`, `memcpy`, `write`, `read`, `fopen`, and every "out parameter" API. ADR-0038's conformance
target routes around it by choosing three integer-only libc functions (`ffs`, `toupper`, `putchar`),
which is enough to prove the mechanism but not enough to call an interesting C library.

**Cost of the workaround:** the extern feature is real but its reach is narrow — integer-and-struct
signatures only. `oscortex_core`'s likely first uses (an assembly helper taking a register value, an
IDT-loading stub) fit inside that; a real C driver library would not. Extending
`_lowerSignatureType` for `Pointer<T>` is a small, self-contained change once a target needs it;
whoever does it should also decide whether `Pointer<Void>`/`void *` needs a spelling, which the
prelude has no type for today.

---

## GAP-0024 — Signed integer division is rejected, not implemented (needs an INT_MIN/-1 guard)

**Domain:** backend (M2)
**Status:** OPEN — unreachable today; rejected loudly rather than emitted wrong

`_emitDivRem` (ADR-0036) throws a specific `BackendError` if the dest type is a signed `DCInt`.
Unsigned division needs one guard (zero divisor); signed division needs a second, because
`INT_MIN / -1` overflows and is undefined behaviour in LLVM just as a zero divisor is. Only the first
guard is implemented.

This is unreachable right now: `runtime/dc-core-bare/prelude.dart` exposes only unsigned sized-int
types, so no signed value can reach the emitter. It is rejected anyway so that adding signed types
later cannot silently inherit codegen that is wrong in one corner.

**Cost of the workaround:** none today. When signed types land, this must be implemented in the same
change — as must the signed comparison predicates (ADR-0035 selects `ult`/`ule`/`ugt`/`uge`
unconditionally at the recognition site in `dcc-lower`, NOT in the backend, so that is the place that
has to learn about signedness). Both failures would be silent.

---

## GAP-0023 — No general boolean NOT; `!` works only as part of `!=`

**Domain:** dc-ir, dcc-lower (M2)
**Status:** OPEN

DC-IR has no NOT instruction. `!=` does not need one — ADR-0035 lowers `a != b` to a single
`icmp ne`, not to "compare then invert" — but a standalone `!flag`, or `!(a < b)`, has nothing to
lower to. `_lowerExpression` now throws a specific error naming this gap instead of the generic
"unsupported expression".

Implementing it is small (`xor i1 %v, true`, or a dedicated `INot`), but it raises a question worth
answering deliberately rather than by accident: DC-IR currently has no boolean-valued instruction
other than `ICmp`, and `DCBool` values only ever flow into `CondBranch`. A general `!` is the first
thing that would make booleans a real first-class value in the IR, which also affects whether
`DCBool` can appear in a function signature (today it cannot — ADR-0034 rejects it at the C ABI).

**Cost of the workaround:** invert the comparison by hand (`a >= b` instead of `!(a < b)`), or swap
the `if`/`else` branches. Both always possible, both a real readability tax. `&&` and `||` are
separately absent and are a larger question (short-circuit evaluation needs control flow, not an
instruction).

---

## GAP-0022 — Generated C headers emit structs in signature order, which is not guaranteed to be valid C

**Domain:** backend / FFI (M2)
**Status:** OPEN — unbuildable in the language today

`_collectStructs` in `backend/lib/c_header.dart` (ADR-0034) emits each distinct struct type in the
order it is first seen across function signatures. If a struct had a field whose type is another
struct, C would require the inner one to be defined first, and signature order does not guarantee
that. The generated header would fail to compile.

No DCDart program can build that shape: `@packed` structs hold scalars and pointers only. So this is
a latent ordering bug with no reachable trigger, recorded rather than fixed speculatively. The fix
when it becomes reachable is a topological sort over field types, which is also when a cycle (two
structs pointing at each other) becomes a real case needing a forward declaration.

**Cost of the workaround:** none today.

---

## GAP-0021 — A fresh clone of this repo could not build at all; the ignored vendor tree was not reproducible without undocumented manual steps

**Domain:** frontend / build reproducibility (all milestones)
**Status:** RESOLVED (2026-08-20) — `core/scripts/vendor-frontend.sh`

Found by cloning this repo onto a clean machine (macOS/arm64) that had never built it. `core/frontend/`
did not exist at all — `core/frontend/vendor/` is `.gitignore`'d by ADR-0005/0007's own decision (~212M
working tree plus its own nested `.git`), and nothing else under `frontend/` is tracked. Because
`dcc-lower` has a path dependency on the vendored `pkg/kernel`, **every package in the pipeline failed
`dart pub get`**, so `dcc` could not run and not one of the sixteen conformance harnesses could execute.
This was not a stale-artifact problem: it is the state of any fresh clone.

Restoring it needed three things, only the first of which was mechanically written down:

1. The sparse/shallow/partial clone command (ADR-0005) re-pinned to the `3.12.2` tag (ADR-0007) — the
   only step recoverable by reading the ADRs.
2. The workspace-detach pubspec edits (ADR-0007 decision item 2). These live **only** inside the
   ignored tree, so a re-clone silently reverts them to upstream's `resolution: workspace` form and
   `pub get` then demands all ~60 members of dart-lang/sdk's pub workspace be physically present.
   ADR-0007's own Consequences section predicted exactly this ("the detach is not a one-time patch
   that survives a re-clone... Worth a small script if re-vendoring becomes routine; not written now
   since it's happened exactly once"). It has now happened a second time.
3. A Dart SDK satisfying `^3.12.0-0`. The machine's `dart` was Flutter's bundled 3.11.0, which does
   not satisfy it — a confusing failure, because `dart` was on PATH and looked fine.

**Cost of the workaround (before the fix):** total, not partial. The project was unbuildable and every
claim in `core/README.md` unverifiable on a new machine, despite all of that code being correct and
committed. The private `dcdart-internal` repo exists specifically so this project survives a machine
switch; it covered the process docs but not the one ignored directory the build actually needs.

**Resolution:** `core/scripts/vendor-frontend.sh` reproduces the vendor end to end — clone at the
ADR-0005 sparse spec, verify the checkout is exactly ADR-0007's pinned commit
`d684a576a6aa954ae107a03b2b4e1d61c3bebe93` (hard-fail otherwise), rewrite all three pubspecs to their
detached form, then prove the result by running `dart pub get` across all six `core/` packages instead
of assuming. Idempotent; `--force` re-clones. Verified from a genuinely empty `core/frontend/` on
macOS/arm64, after which all sixteen conformance harnesses pass in a `linux/amd64` container.

---

## GAP-0020 — Heap- and weak-typed heap-object field stores rejected (undecided ownership policy)

**Domain:** dcc-lower (M2)
**Status:** OPEN — scalar (`DCInt`) heap-object field stores RESOLVED
(`docs/decisions/0032-if-else-merge-and-heap-field-store.md`); heap/weak-typed field stores throw a
clear error rather than guessing.

Found while writing `core/examples/demo-collatz/` (a real, hand-written program, not a narrow
conformance target): `_lowerHeapFieldLoad` (reading a `HeapObject` subclass's field) existed since
ADR-0016/0020, but its Store-direction counterpart never did — `counter.total = counter.total + n;`
threw "unsupported expression statement." Added `_lowerHeapFieldStore`, but scoped to scalar fields
only: overwriting a field that currently holds a strong heap/weak reference raises the exact same real
ownership question ADR-0027 already flagged for scalar-vs-heap LOCAL reassignment — does the store
release the old value first? does it need to retain the new one, or does it take over an existing
strong reference from the assigning expression? None of this is decided.

**Cost of the workaround:** none for the scalar case (resolved for real). Heap/weak-typed field
mutation after construction remains genuinely unsupported — a real gap for any program wanting a
mutable heap-typed field (e.g. a linked-list `next` pointer, an observer's target), not just a
theoretical one. Next step: this needs the same kind of ownership-policy decision move semantics
(ADR-0031) and scalar reassignment (ADR-0027) already flagged as undecided — likely resolved together
once a real program needs mutable heap-typed fields, not speculatively now.

---

## GAP-0019 — No general inline asm / `@naked` / extern-to-external-symbol FFI; only the narrow `Port.outb`/`Port.inb` primitive exists

**Domain:** dc-ir, backend, dcc-lower (M2, downstream: `oscortex_core`)
**Status:** OPEN — three of its five sub-items are now RESOLVED:
- `Port.outb`/`Port.inb` (`docs/decisions/0029-port-io.md`), the narrow case that motivated the entry;
- bitwise operators `&`/`|`/`^`/`<<`/`>>` (`docs/decisions/0030-bitwise-operators.md`);
- **extern-to-external-symbol FFI (`docs/decisions/0038-extern-symbols-and-linking.md`)** — see the
  struck-through item below. `@extern external` declarations, real `declare`s and relocations, real
  multi-object linking, verified by `tests/conformance/ffi-extern/run.sh`.

General inline `asm`, `@naked`, `@interrupt` enforcement, `@linkName` and `@section` remain
unimplemented, correctly deferred.

`oscortex_core` (a from-scratch OS being developed alongside DCDart, its own project) needed x86 port
I/O (`outb`/`inb`) for its first milestone's UART driver. Rather than build the general primitives spec
§6 ("dangerous five": `asm`, `@naked`, `Pointer.fromAddress`, `unowned`, `@noarc`) and §9 (reverse FFI —
DCDart code calling an external, non-DCDart symbol by name) describes, a single narrow DC-IR
instruction pair (`PortOut`/`PortIn`) with a FIXED LLVM inline-asm shape was added instead — real,
immediately motivated, verified against a real disassembly, but deliberately not a general mechanism.

**What's still missing, for real, when the next OS milestone needs it:**
- General inline asm (arbitrary instruction sequences from DCDart source) — needed for things like
  `cli`/`sti`, `lgdt`/`lidt`, `cpuid`, control-register reads/writes. None of these have a narrow,
  single-purpose escape hatch the way port I/O did; each would need its own case-by-case decision
  about whether a dedicated instruction (like `PortOut`/`PortIn`) or a real general `asm` mechanism is
  the right call, the same way this gap was resolved.
- `@naked` functions (no prologue/epilogue, needed for real interrupt/exception handler entry points).
- ~~Extern-to-external-symbol FFI — DCDart code calling a symbol not defined in its own Kernel IR
  compilation unit (e.g. a hand-written assembly helper in a companion `.S` file). `dcc` today only
  ever emits one self-contained relocatable object per compilation unit; resolving an external symbol
  by name is a new architectural concept it doesn't have.~~ **RESOLVED, ADR-0038.** `@extern external`
  + a module-level `DCModule.externFunctions` + an LLVM `declare` per symbol. `dcc` output is now one
  object among several: `tests/conformance/ffi-extern/run.sh` links four objects freestanding
  (`-nostdlib`) with zero undefined symbols left, links three natively and runs them, and calls real
  libc (`ffs`/`toupper`/`putchar`) with the stdout bytes checked. `oscortex_core` no longer has to
  route everything through the assembly-calls-DCDart direction.
  **Two follow-ups this opened, tracked separately:** GAP-0025 (`Pointer<T>` cannot appear in a
  signature, so most of libc is still un-declarable) and GAP-0026 (no signed sized-int types, so a C
  `int` must be declared `u32`).
  **Rule 1's meaning changed, and that change is RATIFIED:**
  `docs/escalations/0003-extern-c-calls-vs-freestanding.md` was decided by the project owner (option
  2) on 2026-08-20 — rule 1 becomes "zero undefined symbols *except ones the source explicitly
  declared*, checked mechanically." The check still hard-fails any undefined symbol the source did not
  declare, and `tests/conformance/ffi-extern/run.sh` step 3 asserts exactly that on every run.
- `@interrupt` function safety enforcement (no allocation inside an interrupt handler, compiler-
  enforced) — mentioned in `CLAUDE.md`'s coding rules as a real requirement, not yet built at all.
  **Whoever builds it also owes escalation 0003's second condition: `@extern` must be rejected inside
  an `@interrupt` function.** That could not be built with ADR-0038 because `@interrupt` does not
  exist; it is recorded here so it is not lost.
- `@linkName` and `@section` (spec §6's linker-control row). ADR-0038 deliberately did not build them:
  the Dart identifier is the C symbol name, which covers every symbol needed so far. `@linkName`
  becomes necessary the moment a C symbol's name is not a legal Dart identifier (a leading underscore
  at top level, a `$`, a C++-mangled name); `@section` is an outbound-direction property and belongs
  with whoever needs `.text.boot`.
- `@volatile` (GAP-0006, pre-existing) — whoever builds it needs to cover `PortOut`/`PortIn` too, not
  just `Load`/`Store`: both are genuine side effects that must never be reordered or elided once an
  optimizer exists.

**Cost of the workaround:** none for the narrow `Port.outb`/`Port.inb` addition itself (resolved for
real, verified against a real disassembly, not routed around), and none for extern FFI (resolved for
real, executed for real). The cost is scope: `oscortex_core`'s next real milestone (interrupts) still
needs `@naked` and `@interrupt` enforcement, which don't exist — and ADR-0038's extern surface, while
real, reaches only integer-and-struct signatures until GAP-0025 lands. Expect this entry to keep
growing real sub-items as that work starts, not to close outright.

---

## GAP-0018 — No function-call instruction in DC-IR at all; every conformance target is a single leaf function

**Domain:** dc-ir, dcc-lower, backend (all milestones so far)
**Status:** RESOLVED (2026-08-14) — see `docs/decisions/0018-function-calls.md`

`core/dc-ir/lib/instructions.dart` had no `Call` instruction; `core/dcc-lower/lib/lower.dart`'s
`StaticInvocation` handling only recognized prelude members. Every conformance target through M2's
alias slice was, and had to be, a single self-contained function with no calls out. Discovered (not a
deliberate scope cut recorded anywhere) while scoping GAP-0017's "heap reference passed as a function
argument" item, which needed a second function to pass one *to*.

**Resolved:** a new `Call` DC-IR instruction (`dest` nullable for void returns, `targetName`, `args`),
real LLVM `call` codegen in `core/backend`, and `dcc-lower` recognition of a `StaticInvocation`
targeting a sibling `@bare`-annotated top-level function (checked last among `StaticInvocation` shapes
so it can never shadow a real prelude member). Verified via `core/examples/m2-call/calls.dart` —
direct calls, a `Result`-returning callee, and a call composed with `.propagate()` with zero extra
plumbing needed — `core/tests/conformance/m2-call/run.sh` reports an unqualified PASS under
WSL/Ubuntu, zero regressions on the other six targets.

**What this does NOT resolve, on purpose (scope cut, see the ADR):** only scalar
(`u8`/`u32`/`u64`/`Result`) parameter/return types are handled — a `DCHeapPointer`-typed parameter or
return still throws (this is exactly GAP-0017's remaining item, now unblocked but not yet done). A
void-returning callee can't be called as an expression yet (only as a statement, which itself isn't
wired up — no conformance target has needed it). Recursion is untested, though nothing in the design
should prevent it.

---

## GAP-0017 — M2's naive Retain/Release insertion + weak references + first elision pass (RESOLVED); passes 1/2/4/5 + unowned/cycles/heap-in-loop remain

**Domain:** dcc-lower, backend (M2, M3+)
**Status:** items 1, 2 (pass 3 only), 3 (weak only), 5, AND item 6 (scalar-only `while` loops)
RESOLVED (2026-08-14/15/16, ADR-0017/0019/0020/0021/0022/0023/0025/0027/0028) — item 4 (plus
`unowned` within item 3, passes 1/2/4/5 within item 2, and heap/weak locals inside a loop body within
item 6) remain, correctly later-milestone/optional/sequenced-after-the-first-pass.

`core/tests/conformance/m2-heap/run.sh` proves the *core mechanism* (real `Alloc`/`Retain`/`Release`
codegen, real heap object construction/field access from source, a real leak test passing 1000 real
cycles under Linux) — genuinely the highest-risk part of M2 per `AGENTS.md`. What M2's exit criterion
(`ROADMAP.md`: "leak-free... `weak` references nil out correctly... elision firing") still needs:

1. **`Retain` insertion at every ownership-transfer point spec §3.1 describes — RESOLVED.** In order,
   across four ADRs: local-to-local aliasing (ADR-0017, `core/tests/conformance/m2-alias/run.sh`, 2000
   real cycles); heap-typed function parameters (borrowed by default, spec §3.2 item 2) and return
   types (ADR-0019, `.../m2-heap-param/run.sh`, 1000 leak-free borrowed-call cycles + a *bounded*
   return-transfer test); a `HeapObject` field referencing another `HeapObject` (ADR-0020,
   `.../m2-heap-field/run.sh`); and `@owned` parameters (ADR-0021, spec §3.2 item 2's other half,
   `.../m2-owned/run.sh`, **1000 real cycles, genuinely leak-free and UNBOUNDED** — the first M2
   heap-signature target that didn't need to stop short of the 64-slot arena). All shapes compose
   correctly with each other and with the pre-existing naive release policy (ADR-0016), confirmed via
   a full regression run after every single addition, zero regressions at any step.
2. **Elision (spec §3.2 passes 1, 3, 4, 5) — PASSES 3 and 4 (one case) RESOLVED; passes 1/2/5 and pass
   4's general cases remain.** Earlier drafts of this entry framed elision as purely M3 scope
   ("naive-but-correct is the right M2 target") — CORRECTED after re-checking `ROADMAP.md`'s own M2
   exit text directly: *"...`dc-objdump --arc` shows elision firing on the reference benchmark" is part
   of M2's exit criterion, not M3's.* M3's own exit is specifically the ≤10%-overhead *measurement* (a
   distinct, later gate). Pass 3 (redundant-pair removal) is implemented (`core/dc-elide/`) and
   demonstrably firing — `core/examples/m2-alias/alias.dart`'s `makeAliasAndReadValue` went from
   `retain=1 release=2` to `retain=0 release=1`, verified via `dc-objdump --arc` (ADR-0024). M2's exit
   criterion text is satisfied for "elision firing." **Still open:** passes 1 (escape analysis), 2
   (borrow inference proper — proving MORE un-annotated parameters could safely skip retain/release
   than the source explicitly marks; NOT the `@owned`/borrowed-by-default *contract* ADR-0019/0021
   already built, which is the ownership rule elision would optimize on top of, not the optimization
   itself — see ADR-0021's "one wrinkle worth recording"), 5 (uniqueness/reuse analysis), and pass 4's
   general cases (below) — each a real, larger analysis, appropriately sequenced after the narrowest
   pass proved the mechanism.

   **Move semantics (pass 4) — RESOLVED for the call-consumed, single-owned-argument case
   (`docs/decisions/0031-move-semantics.md`); general cases remain.** The target this was scoped from:
   `core/examples/m2-owned/owned.dart`'s `makeAndDropViaCall` (`final b = makeBox(v); return
   dropBoxAndReadValue(b);`) now shows `retain=0 release=0` (was `retain=1 release=1`), verified via
   `dc-objdump --arc` on the real compiled source. `Call` gained `argOwnership: List<bool>`
   (`core/dc-ir`), populated by `dcc-lower` from the same `@owned` check that already decided whether
   to emit a caller-side `Retain`; `dc-elide` now lets a pending retain survive a `Call` specifically
   when it matches an owned-consumed argument, but tracks it under a STRICTLY STRONGER invalidation
   rule than an ordinary pending retain (any later reference at all invalidates it, not just an opaque
   op) — the ADR's own "critical correctness subtlety" section explains why the weaker rule that's safe
   for ordinary pairs is NOT safe here (cancelling this pair leaves the object's LAST reference handed
   directly to the callee, unlike an ordinary pair where some other reference keeps it alive
   regardless). A dedicated negative test proves a "used again after the owned call" shape is correctly
   left alone. **What pass 4 still doesn't cover**, deliberately: moving into a struct/heap-object
   field, moving on a plain variable's last read with no call involved (closer to escape-analysis
   territory), moving across a loop back-edge, and `Weak<T>`'s own `@owned` convention (no weak-count
   elision story exists at all yet).
3. **`weak` (spec §3.3 layer 1) — RESOLVED (ADR-0023); `unowned` still not started.** A new
   `DCWeakPointer` type plus `MakeWeak`/`WeakLoad`/`DropWeak` DC-IR instructions; "nils out when the
   target dies" is real, backed by ADR-0022's destructor cascade for the "dies" part and a "zombie
   slot" (strong==0 but not yet freed while any weak reference remains) for correct dead-detection.
   `core/tests/conformance/m2-weak/run.sh`: 1000 real cycles (both the "already dead" and "still
   alive" paths), genuinely leak-free and UNBOUNDED, exact zombie-slot arena counts verified at every
   intermediate step. Scope cuts: no weak-to-weak aliasing (throws a clear error, same discipline as
   ADR-0017's original heap-aliasing fix), `unowned` (a non-nilling, trap-on-dead-access variant) not
   attempted.
4. **Cycle collection (ORC, spec §3.3 layer 2, `@hosted` only) and the static cycle lint (layer 3) —
   not started.** A real `weak` mechanism now exists to build the cycle-breaking pattern on top of
   (item 3, above), and a real object-death signal exists for ORC's own bookkeeping — more concretely
   scoped than before, but still a genuine next milestone, not a quick follow-on.
5. **Destructors / direct-call cascade — RESOLVED for DCDart's current non-polymorphic scope
   (ADR-0022).** `Alloc` now writes a destructor function's address into the header's `cls` field at
   construction (only when the class has ≥1 heap-typed field); `Release`'s now-uniform codegen calls
   through `cls` when non-null, before freeing the slot. `core/examples/m2-heap-field/heap_field.dart`
   was rewritten from asserting a deliberate bounded leak (ADR-0020's original, correct-at-the-time
   state) to asserting genuine, unbounded leak-freedom — 1000 real cycles, `Release`'s own doc comment
   ORIGINALLY said this dispatch belongs entirely in the backend, and that's exactly where it landed.
   **What's still deferred, correctly:** a REAL `ClassInfo` vtable for genuine dynamic dispatch (spec
   §4.3, M5+) — see GAP-0003 (retitled) and ADR-0022's "Rejected alternative" for why a full vtable
   would be premature complexity while every heap object's concrete class is still always statically
   known.
6. **`while` loops over scalar-only bodies — RESOLVED (ADR-0028); heap/weak locals inside a loop body
   remain unsupported, plus `for`/`do-while`/`break`/`continue`/nested loops.** This item used to say
   "loops with heap locals — unverified," implying loops existed and only the heap-local interaction
   was untested; that was corrected once, then resolved for real here. A real loop needed two
   independent things: mutable local variables (ADR-0027) and new DC-IR control flow for back-edges
   (this ADR) — both now exist. `_lowerStatement` recognizes `WhileStatement`, threading every
   loop-carried scalar local through a block-parameter loop header (DC-IR already represents merge
   points via block params, per `ssa.dart`'s own design — no new DC-IR instruction was needed).
   `core/examples/m2-loop/loop.dart` verifies both a straight-line loop body (`sumTo`, loop-carried
   variable threading) and a nested early-`return` inside a loop body (`firstAtLeast`, composing the
   loop with `_lowerIf`'s existing guard-clause pattern) — 50 + 19×15 checks, all correct. **A real
   backend bug was found and fixed along the way** (ADR-0028's own "bug found along the way" section):
   `phi`-node predecessor labels were computed from a DC-IR block's nominal label, not the REAL final
   LLVM label after internal sub-block splitting (arithmetic overflow trapping, `Alloc`'s OOM check,
   `Release`'s destructor path, `WeakLoad`'s dead/alive split all do this) — latent since M0, invisible
   until a loop's back edge became the first non-empty-args branch to follow a block containing
   arithmetic. Fixed via a two-pass emission restructure in `core/backend/lib/llvm_emit.dart`; zero
   regressions across the full 14-target suite. **Still explicitly unsupported, enforced by a real
   check (not silently mishandled):** heap- or weak-typed locals declared inside a loop body (the
   naive release policy has no policy for a back edge that isn't a `return` — see item 2's move
   semantics note for the shape of the ownership-policy question this raises), `for`/`do-while`
   (different Kernel AST shapes), `break`/`continue`, and nested loops. Each throws a clear
   `DccLowerError` rather than mis-scoping. **What was already proven before this ADR, closing
   ADR-0018's own "recursion is untested" flag**: a self-recursive `@bare` function works with ZERO new
   lowering logic (`Call`'s design, ADR-0018, already handled it correctly) —
   `core/examples/m2-recursion/recursion.dart` verifies recursive calls plus a heap object allocated
   fresh at every recursion level, releasing correctly in LIFO order, depths 0-60. Recursion remains a
   real alternative for "iterate toward a base case" but is not a substitute for the general loop this
   item now provides (no iterating over a collection, no `for`, no `break`).

**Cost of the workaround:** none for items 1/2(passes 3 and 4's resolved case)/3(weak)/5/6 (resolved
for real, not worked around). Item 4 (cycle collection/ORC) is correctly M3+/later: `ROADMAP.md`'s own M2 work list
("Retain/release insertion, destructors, weak/unowned, escape analysis, borrow inference,
redundant-pair removal, move semantics, uniqueness/reuse") never mentions cycle collection at all —
only spec §3.3's own layer numbering (this file's earlier framing) suggested otherwise. `unowned`
(item 3's other half) is genuinely optional until a real use case needs it.

**Next step:** item 2's remaining passes — escape analysis (1), borrow inference proper (2), move
semantics' general cases (4), uniqueness/reuse (5) — are each real, larger analyses; pick whichever a
real workload pressures first rather than building them all speculatively. Cycle collection and
`unowned` remain correctly deferred until a real use case needs them.

---

## GAP-0001 — No toolchain vendored, M0 unbuildable and unverifiable

**Domain:** frontend / backend (M0)
**Status:** fully resolved — see GAP-0005, also now closed

As of 2026-08-13, this is fully resolved as originally scoped:

1. `dart 3.12.2` and `clang`/`llvm-nm` (LLVM 22.1.8) installed via winget.
2. `dart-lang/sdk`'s `pkg/front_end`/`pkg/kernel`/`pkg/_fe_analyzer_shared` vendored at
   `core/frontend/vendor/dart-sdk/`, pinned to the `3.12.2` tag, `pub get` resolves cleanly. See
   ADR-0005/0007.
3. **`dcc build --mode bare add.dart -o add.o` now actually works and produces a real object file**
   (`core/dcc-lower` + `core/backend` are implemented — see ADR-0008 for the frontend strategy: an
   extension-type prelude, `core/runtime/dc-core-bare/prelude.dart`, lets real unmodified
   `front_end` parse `@bare`/`u64` syntax with zero source changes; `dcc-lower` walks the resulting
   Kernel IR via the vendored `pkg/kernel`; `backend` emits real LLVM IR text from the resulting
   `DCFunction` and shells to `clang -c`).
4. **`core/scripts/verify-freestanding.sh` reports `FREESTANDING: pass` against that real,
   `dcc`-produced `add.o`.** Not a hand-written `.ll` this time — the actual pipeline's own output.
5. **The arithmetic is verified correct**: the same real `dcc_lower`/`backend` code, re-targeted to
   the native host triple (since the ELF-targeted object can't link on native Windows — see GAP-0005),
   was compiled, linked against `main.c`, and run: exit code 5, i.e. `add(2, 3) == 5`.

**What this does NOT claim:** `core/tests/conformance/m0/run.sh` — the actual mechanical exit-
criterion check — does not report `M0: PASS` on this host, because its own step 3 (link the
freestanding ELF object against `main.c` and run it) correctly and honestly refuses to run on a
non-Linux host rather than fake success. See GAP-0005. The *code path* that step would exercise
(dcc-lower + backend, just re-targeted) has been proven correct per point 5 above; the *literal*
exit criterion — the same object that passed step 2, linked and run — has not been demonstrated on
this host and needs Linux/QEMU to complete, consistent with `DCDART_SPEC.md`'s own testing model for
`@bare` code.

---

## GAP-0005 — M0's literal exit criterion unverified on this host (Windows, no QEMU); code path proven, exact artifact not

**Domain:** backend / testing (M0)
**Status:** RESOLVED (2026-08-13) — verified for real under WSL2/Ubuntu

`core/tests/conformance/m0/run.sh` step 3 links the real, `dcc`-produced, freestanding
(`x86_64-unknown-none-elf`) `add.o` against `main.c` and runs the result, asserting exit code 5. This
needed a Linux host (Windows can't link ELF natively) — installed WSL2 + Ubuntu, `clang`/`llvm-nm`
(apt) and the matching Dart SDK (Linux x64 tarball, same `3.12.2` version as Windows), re-ran
`pub get` for `dc-ir`/`dcc-lower`/`backend`/`dcc` under the Linux Dart SDK (Windows-generated
`package_config.json` files don't resolve from Linux paths), then ran the actual conformance harness
unmodified from inside WSL (`/mnt/c/...` mount, no file copying needed).

**Result: `M0: PASS — dcc build -> verify-freestanding pass -> freestanding link -> add(2,3) == 5`.**
A real, unqualified pass on the literal exit criterion, no host-limitation caveat needed anymore. The
same run also confirmed `M1-pointer` and `M1-struct` pass unqualified — see their own entries.

**One real hiccup along the way, worth recording:** `wsl -d Ubuntu`'s *first* launch hung
indefinitely — it was waiting on an interactive Unix username/password prompt with no attached stdin,
which a non-interactive automation shell can never answer. Killed the stuck `wsl.exe`/`wslhost.exe`
processes, ran `wsl --shutdown` to reset the WSL2 VM cleanly, then relaunched with `wsl -d Ubuntu
--user root` to bypass the interactive setup entirely. Worth knowing if this needs doing again on a
fresh machine: don't wait on a hung first WSL launch, use `--user root`.

**Cost of the workaround:** none — this was a real capability gap (no Linux-linkable host), now
actually closed, not routed around.

---

## GAP-0007 — Result<T,E>/`?` propagation

**Domain:** dcc-lower, dc-ir, backend (M1 clause 3)
**Status:** RESOLVED (2026-08-13) — M1's third and final exit-criterion clause is done and verified

`ROADMAP.md` M1's third exit-criterion clause: "returns `Result<u64, Err>` through `?` propagation."

1. **RESOLVED (escalations/0001-question-mark-syntax.md):** `?` itself is not valid Dart syntax.
   **Decided:** a named-method approximation (`.propagate()`, recognized by `dcc-lower` the same way
   `.value`/field getters are) rather than forking `pkg/front_end`'s parser — the fork can't be
   verified here (no CFE regression suite, no expert review), the approximation can. The vendored
   front_end (ADR-0005/0007) stays ready for real syntax later.
2. **RESOLVED (ADR-0013):** `ICmp` added to `core/dc-ir`, lowered to LLVM `icmp` in `core/backend`,
   verified correct including the unsigned-vs-signed edge case (`ugt` on `0xFFFF...FFFF` vs `1`).
3. **RESOLVED (ADR-0014):** `Result<T,E>`'s value representation — `DCStruct` (already existed,
   previously only used descriptively by ADR-0011's pointer-backed pattern) reused as a genuine
   *by-value* aggregate type, with new `MakeStruct`/`ExtractField` DC-IR instructions lowering to
   LLVM `insertvalue`/`extractvalue`. Verified correct with a hand-built `{tag,payload}`
   construct-then-extract test, 4 cases, still freestanding. `core/runtime/dc-core-bare/prelude.dart`
   gained `Result` (`.ok`/`.err` factories, `.propagate()`) and `u64 operator <` (needed for a
   real `if` condition — verified its Kernel IR shape too: synthesizes as `u64|<`, same pattern as
   `u64|+`). All the Kernel IR shapes `dcc-lower` would need to recognize (`IfStatement.condition`/
   `.then`/`.otherwise`, `Result.ok`/`.err` as factory calls, `.propagate()` as an instance
   invocation) are empirically confirmed against real compiled output — this is genuinely
   implementation-ready, not just planned.
4. **RESOLVED — turned out not to be a real bug for DCDart's actual target.** While verifying the
   full wire-up, a hand-built test exposed a real *local* problem: `define {i64,i64} @f(...)`
   returning a raw LLVM aggregate did not match what `clang`/`gcc` expect for a C struct return on
   `x86_64-w64-windows-gnu` (Windows x64's ABI) — confirmed with a failing test
   (`makePair(111,222)` read back wrong). **Deliberately not guess-fixed at the time** — that mismatch
   was against the Windows-native retarget used only as a verification proxy (GAP-0005), not against
   `@bare`'s actual target. Once WSL/Ubuntu was available (GAP-0005), re-ran the identical test under
   real `x86_64-linux-gnu` (SysV): **`core/backend`'s existing, unmodified emission is correct** —
   SysV classifies a `{i64,i64}` struct (two plain-integer fields, ≤16 bytes) as a two-register
   return, exactly what was already being emitted. No backend change was needed. The Windows mismatch
   was real but irrelevant — a property of a host DCDart was never targeting, not of the compiler.
5. **RESOLVED — written, then fully verified.** `core/dcc-lower/lib/lower.dart`'s
   `_BareFunctionLowerer` was generalized from a flat single-block instruction list to a real block
   builder (`_startBlock`/`_finishBlock`/`_addInstr`, tracking `_blockOpen` so a statement after
   control flow that already returned on every path is a clear error, not silently mis-lowered) and
   now handles `IfStatement` (guard-clause style: every written branch must terminate; an `if`
   without `else` leaves the false path open as the fallthrough continuation), `Result.ok`/`.err`
   (→ `MakeStruct`), `.propagate()` (→ `ExtractField` + `ICmp` + `CondBranch`, checking the enclosing
   function's return type actually is `Result`), and `u64(<literal>)` construction (a shape hit while
   writing the conformance example: `StaticInvocation` targeting `u64|constructor#`).

   `core/examples/m1-result/result_demo.dart` (three functions: a plain guard-clause `Result`
   producer, and two exercising `.propagate()`'s Ok-continue and Err-early-return paths) builds via
   real `dcc build --mode bare`, passes `verify-freestanding.sh`, and — under WSL/Ubuntu —
   `core/tests/conformance/m1-result/run.sh` **reports an unqualified PASS**: real freestanding link,
   real run, all four checked values (`checkPositive(0)`→Err(999), `checkPositive(42)`→Ok(42),
   `doubleIfPositive(7)`→Ok(7) via `.propagate()`'s Ok path, `alwaysPropagatesErr(555)`→Err(555) via
   `.propagate()`'s Err path) came back exactly correct.

**Resolution summary:** every sub-item resolved. M1's third exit-criterion clause is genuinely done —
representation, primitives, `dcc-lower` source-level wiring, and runtime correctness on the real
target all verified, not assumed. See `core/docs/decisions/0014-result-value-representation.md` for
the full decision record.

---

## GAP-0006 — Pointer<T> load/store carry no `@volatile` guarantee

**Domain:** backend (M1)
**Status:** open, low urgency

`DCDART_SPEC.md` §6 requires `@volatile` MMIO access to never be reordered or elided by the
compiler. `core/dc-ir`'s `Load`/`Store` (added for `Pointer<u32>`, ADR-0010) carry no such marker,
and `core/backend/lib/llvm_emit.dart` emits plain (non-`volatile`) LLVM `load`/`store`.

**Cost of the workaround:** none paid yet — `dcc build` runs no LLVM optimization passes at all
right now (straight `clang -c` on hand-emitted IR, no `-O` level, no separate `opt` invocation), so
there is nothing today that would actually reorder or eliminate these loads/stores. The gap is real
but dormant: it becomes a correctness bug the moment optimization passes are introduced, not before.

**Next step:** when optimization passes are added (or when a real `@volatile` conformance test is
written), decide how volatility is represented in DC-IR — a flag on `Load`/`Store`, or separate
`VolatileLoad`/`VolatileStore` instructions — and thread `@volatile` recognition through
`core/dcc-lower`. Not designed now because guessing the DC-IR-level shape before a second real use
case (is volatility ever combined with other Load/Store variants? does `Atomic<u32>` want the same
mechanism?) risks the wrong shape, per this project's own "don't design past what's needed"
discipline.

---

## GAP-0002 — dcc CLI skeleton written but never executed

**Domain:** frontend / dcc (M0)
**Status:** resolved

**Resolution (2026-08-13):** now that `dart` is installed (GAP-0001), `dcc.dart` was actually run:
`--help` (exit 0), a missing-input-file invocation (exit 65, correct message), and a valid
`build --mode bare` invocation against the real `add.dart` (exit 1, throws
`PipelineNotImplementedError` with an accurate message, writes no output file). All match the
designed behavior. The error message itself was stale (claimed "no clang/llvm-nm in this
environment," no longer true, and claimed `core/frontend/` was empty, no longer true post-GAP-0001)
and was corrected in `core/dcc/lib/pipeline.dart`. Original text preserved below for the record.

`core/dcc/` now has a real argument parser for `dcc build --mode <bare|hosted> <input.dart>
-o <output.o>` (`core/dcc/bin/dcc.dart`, `lib/cli_args.dart`, `lib/pipeline.dart`) plus a
`runBuild()` seam that throws `PipelineNotImplementedError` and touches no filesystem output,
per `SKILL.md`'s rule against stubs that fake success. See
`core/docs/decisions/0002-dcc-bootstrap-language.md` for why it's plain hosted Dart.

This is downstream of GAP-0001, not a separate blocker: no `dart` executable exists in this
environment, so none of `core/dcc/bin/dcc.dart`'s code paths — argument parsing, the help
path, the missing-input-file path, the `PipelineNotImplementedError` path — have actually been
run. The implementation was reviewed by hand only.

**Cost of the workaround (there isn't one; same as GAP-0001):** do not report the `dcc` CLI as
"done" or "working" anywhere until it has actually been run against both valid and invalid
invocations on a machine with a Dart SDK.

**Next step:** once GAP-0001's toolchain vendoring lands, run
`dart core/dcc/bin/dcc.dart build --mode bare core/examples/m0-seam/add.dart -o add.o` and a
handful of deliberately-malformed invocations (missing `--mode`, bad mode value, missing input,
nonexistent input file, no arguments, `--help`) to confirm exit codes and messages match
`core/dcc/README.md`. Close this gap once confirmed, independently of GAP-0001 (that gap closes
when the CFE is vendored and the pipeline is real; this one closes when the CLI skeleton itself
is proven to run correctly).

---

## GAP-0003 — DC-IR has no heap-object / `ClassInfo` layout yet

**Domain:** backend (dc-ir)
**Status:** RESOLVED for the non-polymorphic destructor-cascade case (2026-08-15, ADR-0022); a REAL
`ClassInfo` vtable for dynamic dispatch remains open, correctly deferred to M5+

`core/dc-ir/types.dart` defines `DCHeapPointer(pointee)` — a `DCType` distinct from the raw-pointer
`DCPointer`, used to type `Retain`/`Release`'s operand (`core/dc-ir/instructions.dart`) so ARC ops
have a real type to check against. `pointee` is still always the `DCVoid()` placeholder (unchanged) —
DC-IR does not track a heap object's concrete field layout as part of the TYPE itself.

**Resolved:** a `HeapObject` holding a reference to another `HeapObject` now correctly releases it
when the parent dies, cascading to arbitrary depth — `Alloc` (`core/dc-ir`) gained an optional
`destructorName`, written into the object header's `cls` field at construction (spec §3.1); `Release`
needed no shape change at all, its codegen now uniformly checks `cls` and calls through it if
non-null. `dcc-lower` synthesizes one destructor `DCFunction` per `HeapObject` subclass with ≥1
heap-typed field. Verified via `core/examples/m2-heap-field/heap_field.dart`: 1000 real nested-
construct/read/destructor-cascade cycles, genuinely leak-free and unbounded.

**What this does NOT resolve, on purpose:** this is a **direct destructor call**, not a real
`ClassInfo` vtable — every heap object's concrete class is always statically known at its own `Alloc`
site (DCDart has no dynamic dispatch yet, spec §4.3's monomorphization is M5+ scope), so `cls` is
populated with exactly one function's address, never chosen among several at runtime. A genuine
multi-slot vtable (chosen by runtime type, needed once real subtype polymorphism exists) is real,
deferred M5+ design work — see ADR-0022's "Rejected alternative" for why building it now would be
premature complexity with no current behavioral benefit.

**Next step:** when M5+ designs real dynamic dispatch, `cls` can be repointed at a proper multi-slot
`ClassInfo` struct without changing `Release`'s shape again — its codegen already only requires `cls`
to be "either null or callable as `void (ptr)`," which a richer `ClassInfo`'s destructor-slot-first
layout would still satisfy. See `docs/decisions/0004-dc-ir-heap-pointer-without-classinfo.md` for the
original reasoning behind deferring the full design, and `docs/decisions/0022-destructor-cascade.md`
for what was actually built instead.

---

## GAP-0004 — DC-IR's DCDart-flavored source is not yet plain hosted Dart, and `dcc-bootstrap-language` (ADR-0002) sets a precedent it doesn't follow

**Domain:** backend (dc-ir)
**Status:** resolved

**Resolution (2026-08-13):** `docs/decisions/0006-toolchain-bootstrap-language.md` decided
ADR-0002's reasoning applies to the whole toolchain (`dcc`, `dcc-lower`, `dc-ir`, `backend`), not
just `dcc`'s CLI entry point. `core/dc-ir/ssa.dart`'s `ValueId.index`/`BlockId.index` and
`instructions.dart`'s `ConstInt.bits` were retyped from `u32`/`u64` to plain `int`, each with a doc
comment stating the conceptual width. All future `dc-ir`/`dcc-lower`/`backend` code should be
written as plain hosted Dart from the start. Original text preserved below for the record.

`core/docs/decisions/0002-dcc-bootstrap-language.md` (written for `core/dcc/`, concurrently with
this unit) decided that `dcc`'s own implementation is **plain hosted Dart** — real `dart:core`,
runnable on a stock Dart SDK — specifically because DCDart has no working compiler yet and
writing the compiler's own driver *in* DCDart is circular. That reasoning applies just as much to
`dcc-lower`/`dc-ir`/`backend`: whatever actually builds and walks a `DCFunction` at runtime has
the same chicken-and-egg problem `dcc` does.

`core/dc-ir/*.dart` (this unit) is written using DCDart-flavored syntax per this task's explicit
brief — sized integer field types (`u32`, `u64`, `usize`) on `ValueId`, `BlockId`, `ConstInt.bits`,
etc. — which are **not real Dart types**; `u32`/`u64`/`usize` do not exist in `dart:core`. If
`dc-ir`'s actual implementation ends up being plain hosted Dart (consistent with ADR-0002's
precedent), these files as written will not run as-is on a stock Dart SDK — the sized-int fields
would need to become `int` (with explicit masking/range checks standing in for the width, e.g.
`assert(bits <= 0xFFFFFFFF)` for a `u32` field) or a small unofficial "sized int" wrapper type,
neither of which is designed here.

**Cost of the workaround:** none paid yet — nothing has tried to execute `core/dc-ir/*.dart` (see
GAP-0001; there's no Dart SDK in this environment regardless). The cost is entirely deferred: the
first agent that tries to make `dcc-lower` actually construct and walk `DCFunction` values has to
resolve this mismatch before a single line of it runs.

**Next step:** when `dcc-lower` starts being implemented for real, decide explicitly (and record as
an ADR, not silently) whether `core/dc-ir/` becomes plain hosted Dart matching `core/dcc/`'s
precedent (in which case retype every `u8`/`u16`/`u32`/`u64`/`usize` field here to `int` with
documented range comments) or whether `dc-ir` gets its own bootstrap-language exception (in which
case say why the reasoning in ADR-0002 doesn't transfer). Either is fine; leaving it unstated is
not — the next agent should not have to rediscover that these files, as written, assume types the
host Dart runtime doesn't have.
