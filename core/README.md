# core/ — the project

Everything buildable lives here. The repo root holds only the six guide docs (`CLAUDE.md`,
`AGENTS.md`, `DCDART_SPEC.md`, `ROADMAP.md`, `README.md`, `SKILL.md`) — read those first, they are
not repeated here. See `docs/decisions/0001-directory-layout.md` for why.

Layout follows the compiler pipeline in `DCDART_SPEC.md` §1:

| Path | Maps to spec §1 stage | Status |
|---|---|---|
| `frontend/` | DCDart CFE (fork of `pkg/front_end`) | vendored at `vendor/dart-sdk/`, pinned at the `3.12.2` tag, `pub get` resolves cleanly (docs/decisions/0005, 0007). Not invoked directly — shells to `dart compile kernel` instead (ADR-0008); the vendored copy is ready for when a real fork is needed |
| `dcc-lower/` | Kernel IR → DC-IR | **implemented, working, fully verified** for M0/M1 (all clauses) and M2's eleven ARC/elision/recursion/mutability slices, ADR-0016 through ADR-0027 (real heap objects, alias retain, calls, heap-typed signatures, heap-typed fields, `@owned` parameters, destructor cascade, weak references, redundant-pair elision, verified recursion, scalar reassignment) |
| `dc-ir/` | DC-IR: typed SSA, explicit retain/release | real pub package (`dc_ir`), plain hosted Dart per ADR-0006. Arithmetic, `Load`/`Store`/`IntToPtr`/`PtrOffset`, `ICmp`, `Branch`/`CondBranch`, `MakeStruct`/`ExtractField`, `Alloc`/`Retain`/`Release`, `Call`, `MakeWeak`/`WeakLoad`/`DropWeak` (M2, ADR-0018/0022/0023). Consumed for real by `dcc-lower` and `backend` |
| `dc-elide/` | Elision passes (spec §3.2) | **`elideRedundantRetainReleasePairs` implemented and verified** (ADR-0025, spec §3.2 pass 3) — a separate small package (only depends on `dc_ir`) purely so its own test suite can use `package:test`, which `dcc_lower`'s vendored-`kernel` dependency can't reconcile. 4 isolated unit tests (2 positive, 2 negative/safety) plus real end-to-end firing verified via `dc-objdump --arc` |
| `backend/` | DC-IR → LLVM IR → object file | **implemented, working, fully verified** for M0/M1, plus M2's real ARC codegen (`Alloc`/`Retain`/`Release` against a fixed arena, ADR-0015), real function-call codegen (`Call`, ADR-0018), a real destructor-dispatch call through the object header's `cls` field (ADR-0022), and real weak-reference codegen with zombie-slot semantics (ADR-0023) — compiled via `clang -c` |
| `dcc/` | the `dcc` CLI driver | **`dcc build --mode bare` produces real object files** for all thirteen example targets below, all passing their conformance harnesses. `--mode hosted` still throws (no backend target designed for it) |
| `dc-objdump/` | ARC instruction counter (`CLAUDE.md`'s testing rules) | **`dc-objdump --arc <source.dart>` implemented and verified** (ADR-0024) — counts `Alloc`/`Retain`/`Release`/`MakeWeak`/`WeakLoad`/`DropWeak` per function at the DC-IR level (the only place these are countable at all — they're inlined, not symbols, by the time `backend` is done). Every count cross-checked exactly against every M2 ADR's own hand-derived trace, zero mismatches. Now also what proves ADR-0025's elision pass actually fires |
| `runtime/dc-core-bare/` | `dc:core.bare` — zero-dependency freestanding subset | `prelude.dart`: `bare`, `u64` (`+`, `<`), `u32`, `u8`, `Pointer<T>`, `@packed`/`Struct`, `Result` (`.ok`/`.err`/`.propagate()`), `HeapObject`, `@owned`, `Weak<T>` — see ADR-0008, 0010, 0011, 0014, 0016–0023 |
| `runtime/dc-core/` | `dc:core` — hosted stdlib | empty |
| `examples/m0-seam/` | M0 target (`add.dart`, `main.c`) | **`tests/conformance/m0/run.sh`: unqualified PASS** |
| `examples/m1-pointer/` | M1 target (`mmio.dart`, `main.c`) | **`tests/conformance/m1-pointer/run.sh`: unqualified PASS** |
| `examples/m1-struct/` | M1 target (`header.dart`, `main.c`) | **`tests/conformance/m1-struct/run.sh`: unqualified PASS** — cross-checked byte-for-byte against an independent C reference struct |
| `examples/m1-result/` | M1 target (`result_demo.dart`, `main.c`) | **`tests/conformance/m1-result/run.sh`: unqualified PASS** — real struct-by-value `Result` return, both `.propagate()` paths |
| `examples/m2-heap/` | M2 target (`box.dart`, `main.c`) | **`tests/conformance/m2-heap/run.sh`: unqualified PASS** — 1000 real alloc/construct/read/release cycles under real Linux, heap returns to baseline every time |
| `examples/m2-alias/` | M2 target (`alias.dart`, `main.c`) | **`tests/conformance/m2-alias/run.sh`: unqualified PASS** — 2000 real alias/read/release cycles (straight-line + branched), leak-free, proves Retain-on-alias (ADR-0017) |
| `examples/m2-call/` | M2 target (`calls.dart`, `main.c`) | **`tests/conformance/m2-call/run.sh`: unqualified PASS** — direct calls plus a call composed with `.propagate()`, proves `Call` (ADR-0018) |
| `examples/m2-heap-param/` | M2 target (`heap_param.dart`, `main.c`) | **`tests/conformance/m2-heap-param/run.sh`: unqualified PASS** — 1000 leak-free borrowed-parameter cycles + 60 bounded return-ownership-transfer calls, proves ADR-0019 |
| `examples/m2-heap-field/` | M2 target (`heap_field.dart`, `main.c`) | **`tests/conformance/m2-heap-field/run.sh`: unqualified PASS** — 1000 real nested-construct/read/destructor-cascade cycles, genuinely leak-free and UNBOUNDED (proves ADR-0020 + ADR-0022 together; originally a bounded, deliberate-leak test until the destructor cascade landed) |
| `examples/m2-owned/` | M2 target (`owned.dart`, `main.c`) | **`tests/conformance/m2-owned/run.sh`: unqualified PASS** — 1000 real construct/transfer/consume cycles, genuinely leak-free and UNBOUNDED, proves `@owned` (ADR-0021) |
| `examples/m2-weak/` | M2 target (`weak.dart`, `main.c`) | **`tests/conformance/m2-weak/run.sh`: unqualified PASS** — 1000 real weak-reference cycles (dangling + alive paths), exact zombie-slot arena counts, genuinely leak-free and UNBOUNDED, proves `Weak<T>` (ADR-0023) |
| `examples/m2-recursion/` | M2 target (`recursion.dart`, `main.c`) | **`tests/conformance/m2-recursion/run.sh`: unqualified PASS** — self-recursive calls, depths 0-60, a heap object per stack frame, all correct and leak-free, proves recursion (ADR-0026, closing ADR-0018's own "untested" flag) and the new `u64 operator -` |
| `examples/m2-mutable/` | M2 target (`mutable.dart`, `main.c`) | **`tests/conformance/m2-mutable/run.sh`: unqualified PASS** — 400 scalar reassignment checks (straight-line + branch-scoped), proves `VariableSet` lowering (ADR-0027) and the `_values` branch-scoping fix it required |
| `tests/conformance/`, `tests/leak/` | per `SKILL.md` §4 | **all thirteen `run.sh` harnesses report an unqualified PASS**, verified under WSL2/Ubuntu (real freestanding link + real run on the actual `x86_64-unknown-none-elf` target). `tests/leak/` empty — the `m2-*` harnesses are the de facto leak tests; a dedicated `dc-test --leakcheck` harness is future work |
| `scripts/verify-freestanding.sh` | the spine check (`CLAUDE.md` rule 1) | **`FREESTANDING: pass`** against real `dcc` output, all thirteen targets, confirmed on both Windows and Linux |
| `tools/bare-symbol-allowlist.txt` | consumed by the check above | still empty/draft — none of the thirteen targets needed anything allowlisted |
| `docs/` | compat-matrix, known-gaps, decisions, escalations | 27 ADRs, 2 escalations, 9 gaps (8 resolved or resolved-for-current-scope — `unowned`/real vtable dispatch/elision passes 1,2,4,5/cycles/real loop control-flow remain within GAP-0003/0017, correctly deferred; GAP-0006 `@volatile` still fully open) |

## Current milestone: M1 done, M2's naive ARC insertion done, M2 overall in progress

**M1 — done.** All three exit-criterion clauses satisfied and verified end to end (real `dcc build` →
real freestanding link → real run, under WSL2/Ubuntu on the actual target):

1. ✅ **`Pointer<u32>` MMIO read/write** — `examples/m1-pointer/`, ADR-0010.
2. ✅ **`@packed` struct matching a known C layout byte-for-byte** — `examples/m1-struct/`, ADR-0011.
   Needed **zero changes to `core/backend`**.
3. ✅ **`Result<u64, Err>` via `?` propagation** — `examples/m1-result/`, ADR-0013/0014. `?` isn't
   valid Dart syntax (`escalations/0001`), approximated as `.propagate()`. A genuine struct-return ABI
   question came up mid-verification and was resolved by testing under the real target, not guessing
   — `docs/known-gaps.md` GAP-0007, worth reading as a case study in not fixing what isn't broken.

M0 is done the same way: real freestanding object, real overflow-trapping arithmetic (ADR-0009),
linked and run for real.

**M2's naive ARC insertion, destructor dispatch, AND weak references — DONE.** `ROADMAP.md`'s M2 exit
criterion is "allocation-heavy programs run leak-free... `weak` references nil out correctly...
elision firing" — the FULL criterion needs later work too (see below), but every ownership-transfer,
object-death, AND weak-reference shape `DCDART_SPEC.md` §3.1/§3.2/§3.3-layer-1 describes now has real,
verified codegen, across ten ADRs:

1. **(ADR-0015/0016)** The core mechanism: `Alloc`/`Retain`/`Release` codegen against a fixed internal
   arena (explicitly NOT the real `Allocator` — spec §12's open decision 2, `escalations/0002`), real
   heap object construction and field access from source (`class Box extends HeapObject`), naive
   release-on-scope-exit. `examples/m2-heap/box.dart`: 1000 real cycles, leak-free.
2. **(ADR-0017)** Local-to-local aliasing (`final b2 = b;`) — tracking heap locals by
   `VariableDeclaration` identity, not `DCValue` identity (two locals can share one DCValue with no
   copy instruction to tell them apart). `examples/m2-alias/alias.dart`: 2000 real cycles, leak-free.
3. **(ADR-0018)** Real function-to-function calls — a new `Call` DC-IR instruction, discovered as a
   totally missing gap (GAP-0018) while scoping this work: there was no way to call one `@bare`
   function from another at all before this. `examples/m2-call/calls.dart`: direct calls plus a call
   composed with `.propagate()`.
4. **(ADR-0019)** Heap-typed function parameters (borrowed by default, spec §3.2 item 2) and return
   types. `examples/m2-heap-param/heap_param.dart`: 1000 leak-free borrowed-parameter cycles + a
   *bounded* return-transfer test (bounded because nothing could release a returned reference yet).
5. **(ADR-0020)** A `HeapObject` field referencing another `HeapObject`.
6. **(ADR-0021)** `@owned` parameters — spec §3.2 item 2's other half ("Only `@owned` params
   transfer"), found already specified in the spec rather than needing a fresh design decision.
   `examples/m2-owned/owned.dart`: **1000 real cycles, genuinely leak-free and UNBOUNDED** — the first
   M2 heap-signature target that didn't have to stop short of the arena's capacity.
7. **(ADR-0022)** A destructor cascade — `Alloc` writes a destructor function's address into the
   object header's `cls` field (spec §3.1) at construction; `Release`'s codegen (needing NO shape
   change at all — exactly as its own original doc comment anticipated) calls through it when non-null,
   before freeing the slot. `examples/m2-heap-field/heap_field.dart` — ADR-0020's own target — was
   rewritten in place from asserting a deliberate, bounded, predicted leak to asserting **1000 real
   cycles, genuinely leak-free and UNBOUNDED**, once the destructor that fixes exactly that leak
   existed. **This is a direct destructor call, not a real `ClassInfo` vtable** — there's no dynamic
   dispatch anywhere in DCDart yet (spec §4.3, M5+), so every heap object's concrete class is always
   statically known at its `Alloc` site; a real multi-slot vtable is correctly deferred, not built
   prematurely — see the ADR's "Rejected alternative."
8. **(ADR-0023)** `weak` references (spec §3.3 layer 1) — a new `DCWeakPointer` type,
   `MakeWeak`/`WeakLoad`/`DropWeak` DC-IR instructions, and "zombie slot" semantics: a dying object
   with an outstanding weak reference is left `strong == 0` but NOT yet freed, until its last weak
   reference also drops. `examples/m2-weak/weak.dart`: **1000 real cycles, genuinely leak-free and
   UNBOUNDED**, both the "target already died" path (nils out correctly) and the "target still alive"
   path (retains and returns the live reference), with exact zombie-slot arena counts matching the
   predicted values at every intermediate step — and it passed on the FIRST real build, every
   intermediate prediction in the design holding up empirically without a single fix needed.
9. **(ADR-0025)** The first real elision pass — spec §3.2 pass 3, redundant-pair removal
   (`retain(x); ...; release(x)` with no release of `x` in between → delete both). Discovered, while
   scoping "what's left," a real correction: `ROADMAP.md`'s own M2 exit text names "`dc-objdump --arc`
   shows elision firing" as M2 scope, not M3's (M3 is specifically the LATER ≤10%-overhead
   *measurement*) — earlier framing in this project's own docs had this wrong. `dc-objdump --arc`
   (ADR-0024) now shows it firing concretely: `examples/m2-alias/alias.dart`'s
   `makeAliasAndReadValue` goes from `retain=1 release=2` to `retain=0 release=1`, verified before and
   after, with `examples/m2-owned/owned.dart` and `examples/m2-weak/weak.dart` provably UNCHANGED
   (two dedicated negative tests prove the pass correctly refuses to cancel a pair spanning a `Call` or
   a weak op, where doing so would be unsafe). Lives in a new small package, `core/dc-elide/`, purely
   so its own test suite can depend on `package:test` — `dcc_lower`'s vendored-`kernel` path dependency
   makes that impossible in `dcc_lower`'s own pubspec.

10. **(ADR-0027)** Scalar (non-heap) local variable reassignment — `VariableSet` lowering for
    same-width `u8`/`u32`/`u64` locals, one prerequisite of two for a real loop construct (the other,
    loop control flow, remains unimplemented). Found and fixed a real SSA-dominance bug along the way:
    `_values` (the variable-binding table) lacked the same per-branch snapshot/restore `_heapLocals`/
    `_weakLocals` already had, so a reassignment inside an `if`-branch leaked into a sibling branch or
    the fallthrough continuation. `examples/m2-mutable/mutable.dart`: 400 checks (straight-line +
    branch-scoped), all correct after the fix.

Every slice was verified against the FULL conformance suite (all thirteen targets) after landing, zero
regressions at any step — see `docs/known-gaps.md` GAP-0017/GAP-0003 for the itemized history.

**What M2 still needs** (elision's remaining passes — escape analysis, borrow inference proper, move
semantics, uniqueness/reuse, spec §3.2 passes 1/2/4/5 — each a real, larger analysis, appropriately
sequenced after item 9's first pass proved the mechanism) is genuinely M2-scope work, not deferred; a
FULL M3 ≤10%-overhead pass needs all of it, but M2's own literal exit text is satisfied by "elision
firing," which item 9 already demonstrates. **Correctly scoped as LATER milestone work**, confirmed
directly against `ROADMAP.md`'s own M2 work-item list (which never mentions cycle collection at all):
cycle collection (spec §3.3 layers 2/3 — item 8's `weak` mechanism and item 7's destructor cascade are
its two prerequisites, both now real), `unowned` (spec §3.3's other layer-1 variant, trap-on-dead-
access instead of nil-on-dead-access), and a real `ClassInfo` vtable for genuine dynamic dispatch (M5+,
GAP-0003 retitled, not closed outright).

**What closed GAP-0005** (the Windows-can't-link-ELF blocker common to every target): WSL2 + Ubuntu,
`clang`/`llvm-nm` (apt), a matching Linux Dart SDK. Local tooling gap, not a DCDart limitation — `dcc`
itself ran fine on Windows all along.
