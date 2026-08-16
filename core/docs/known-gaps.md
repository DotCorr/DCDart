# Known gaps

Work queue, not a confession log (`CLAUDE.md`). Every entry: what was worked around, and the cost.

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
2. **Elision (spec §3.2 passes 1, 3, 4, 5) — PASS 3 RESOLVED (ADR-0025); passes 1/2/4/5 remain.**
   Earlier drafts of this entry framed elision as purely M3 scope ("naive-but-correct is the right M2
   target") — CORRECTED after re-checking `ROADMAP.md`'s own M2 exit text directly: *"...`dc-objdump
   --arc` shows elision firing on the reference benchmark" is part of M2's exit criterion, not M3's.*
   M3's own exit is specifically the ≤10%-overhead *measurement* (a distinct, later gate). Pass 3
   (redundant-pair removal: `retain(x); ...; release(x)` with no release of `x` in between → delete
   both) is now implemented (`core/dc-elide/`) and demonstrably firing — `core/examples/m2-alias/
   alias.dart`'s `makeAliasAndReadValue` went from `retain=1 release=2` to `retain=0 release=1`,
   verified via `dc-objdump --arc` (ADR-0024) before and after, with zero regressions across all 11
   conformance targets and two dedicated negative tests (a call-spanning pair, a weak-op-spanning
   pair) proving the pass correctly refuses to touch cases where it can't prove safety. M2's exit
   criterion text is satisfied for "elision firing." **Still open:** passes 1 (escape analysis), 2
   (borrow inference proper — proving MORE un-annotated parameters could safely skip retain/release
   than the source explicitly marks; NOT the `@owned`/borrowed-by-default *contract* ADR-0019/0021
   already built, which is the ownership rule elision would optimize on top of, not the optimization
   itself — see ADR-0021's "one wrinkle worth recording"), 4 (move semantics), and 5 (uniqueness/reuse
   analysis) — each a real, larger analysis, appropriately sequenced after this first, narrowest pass
   proved the mechanism.

   **Move semantics (pass 4), scoped but deliberately NOT implemented yet — a real architectural
   finding, not a stub.** The obvious next target is `core/examples/m2-owned/owned.dart`'s
   `makeAndDropViaCall` (`final b = makeBox(v); return dropBoxAndReadValue(b);`): `b` is used exactly
   once, as an `@owned` call argument, and is never referenced again — under move semantics the
   caller's `Retain`+`Release` pair around that call is entirely redundant (the callee's own release
   already accounts for it), which would take this function from `retain=1 release=1` to `retain=0
   release=0`. **Why `dc-elide`'s existing pass can't safely do this**: `Call` (`core/dc-ir`) carries
   no per-argument ownership metadata — from a pure DC-IR vantage point, a retain/release pair
   spanning a `Call` is indistinguishable between "the callee borrows, so the pair is load-bearing"
   (unsafe to remove, ADR-0025's own negative test) and "the callee fully consumes via `@owned`, so
   the pair is redundant" (safe to remove) — nothing at the DC-IR level says which. Two real ways
   forward, neither started: (a) tag `Call.args` (or a parallel list) with an ownership category per
   argument, letting a DC-IR-level pass reason about it directly; (b) do it at LOWERING time instead
   (`_lowerBareCall` already sees the Kernel-level `@owned` annotation directly), which needs a
   reference-count pre-pass over the Kernel IR body to prove a given use is a variable's ONLY use —
   itself a real correctness hazard if it doesn't stay in exact lockstep with `_lowerExpression`'s own
   recognized-shape dispatch (an under-count would incorrectly apply the optimization to a variable
   still used elsewhere — a genuine use-after-free, not a cosmetic bug). Deliberately not rushed in an
   unsupervised pass, per `CLAUDE.md`'s own words on elision regressions being "invisible at runtime
   and catastrophic in aggregate."
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

**Cost of the workaround:** none for items 1/2(pass 3)/3(weak)/5/6 (resolved for real, not worked
around). Item 4 (cycle collection/ORC) is correctly M3+/later: `ROADMAP.md`'s own M2 work list
("Retain/release insertion, destructors, weak/unowned, escape analysis, borrow inference,
redundant-pair removal, move semantics, uniqueness/reuse") never mentions cycle collection at all —
only spec §3.3's own layer numbering (this file's earlier framing) suggested otherwise. `unowned`
(item 3's other half) is genuinely optional until a real use case needs it.

**Next step:** item 2's remaining passes — escape analysis (1), borrow inference proper (2), move
semantics (4), uniqueness/reuse (5) — are each real, larger analyses; pick whichever a real workload
pressures first rather than building all four speculatively. Cycle collection and `unowned` remain
correctly deferred until a real use case needs them.

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
