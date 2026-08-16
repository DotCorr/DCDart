# backend — DC-IR → LLVM IR → object file

Maps to `DCDART_SPEC.md` §1's final stage. **Implemented and working, fully verified** for M0's `add`,
all three M1 exit-criterion targets, and M2's ARC/control-flow slices through ADR-0028 (real heap
allocation/ARC, alias retain, function calls, destructor dispatch, weak references, real `while`-loop
back edges) — every conformance harness in `core/tests/conformance/` (fourteen targets) reports an
unqualified PASS under WSL/Ubuntu (real build → real freestanding link → real run on the actual
`x86_64-unknown-none-elf` target).

**M2 (ADR-0015/0016):** `Alloc`/`Retain`/`Release` now have real codegen against a fixed internal
arena (`@dc_arena`, `@dc_free_list`, `@dc_free_top` — module-level globals, emitted only when a
function actually allocates). `PtrOffset` (`base + offsetBytes` as a raw pointer, works on both
`DCPointer` and `DCHeapPointer`) supports heap-object field access. `DCHeapPointer` now maps to `ptr`
in `_llvmType` (previously deliberately threw, to force ARC codegen to exist first — it does now).
This arena is explicitly **not** the real `Allocator` (spec §12 open decision 2,
`docs/escalations/0002-allocator-threading.md`) — see the ADRs for what it is instead and why.

**M2 (ADR-0018):** `Call` now has real codegen — a plain LLVM `call` (or `call void` when the callee
returns nothing), no vtable/dispatch involved. Every function is emitted as a top-level `define` in
one pass, so call target order doesn't matter — no forward-declaration step was needed.

**M2 (ADR-0022):** `Alloc` gained an optional `destructorName` — when present, its function address
(a real symbol, valid as a plain `ptr` value under LLVM's opaque pointers) is written into the object
header's `cls` field at construction instead of `null`. `Release` needed NO shape change at all: its
codegen is now uniformly "after strong hits zero, load `cls`; if non-null, call through it as `void
(ptr)` before freeing the slot" — this dispatch works identically regardless of how many classes exist
or how deep a destructor cascade goes, since dcc-lower only ever needs class information at `Alloc`
sites (always statically known), never at release sites. **This is a direct call through a
statically-resolved function pointer, not a real `ClassInfo` vtable** — DCDart has no dynamic dispatch
anywhere yet (spec §4.3, M5+ scope), so `cls` is always populated with exactly one possible function's
address, never chosen among several at runtime. See `docs/decisions/0022-destructor-cascade.md`.

**M2 (ADR-0023):** `MakeWeak`/`WeakLoad`/`DropWeak` now have real codegen (`DCWeakPointer` also maps
to plain `ptr`). `Release`'s free-slot logic was extended: after a destructor runs, it now checks the
header's `weak` count (offset 4) too — zero frees the slot as before, nonzero leaves it a "zombie"
(`strong == 0`, not yet on the free list). `DropWeak` shares the actual free-list-push arithmetic with
`Release` via one new helper, `_emitFreeSlotPushback`, rather than duplicating it. `WeakLoad` is the
one place in this file, outside `_phiLines`'s DC-IR block-parameter lowering, that hand-writes a
real LLVM `phi` directly — it needs two genuinely different destination values (null vs. the live
address) merged from two internal branches, which none of this file's other multi-block instructions
(`_emitArith`'s trapping path, `_emitAlloc`) needed, since those only ever define their result once,
before branching.

**M2 (ADR-0028) — a real bug, latent since M0, found and fixed:** `while`-loop back edges (`_lowerWhile`,
`core/dcc-lower`) needed no new DC-IR instructions, but exposed a real bug in this file's
predecessor-label tracking. `_collectPredecessors` (feeding `_emitPhiNodes`, now `_phiLines`) computed
each predecessor's LLVM label as the DC-IR block's own NOMINAL entry label — wrong whenever that
block's body contains an instruction that internally splits into more than one real LLVM block before
its DC-IR terminator, which `_emitArith`'s overflow trapping, `_emitAlloc`'s OOM check, `Release`'s
destructor/free-slot path, and `_emitWeakLoad`'s dead/alive split all do (each calls `startBlock` more
than once). Whichever internal sub-block is current when the DC-IR terminator is actually emitted is
the TRUE predecessor — this has been wrong since M0's overflow-trapping arithmetic (ADR-0009), but
stayed invisible because `_lowerIf`'s `CondBranch` has always passed empty `trueArgs`/`falseArgs` (no
merged value ever crossed an `if`/`else`), so no `phi` ever depended on a predecessor label being
correct until a loop's back edge became the first non-empty-args branch to follow a block containing
arithmetic. **Fix:** emission is now two-pass. Pass 1 emits every block's real instructions and records
each DC-IR block's TRUE final internal label via a new `_FunctionEmitter.lastFinishedLabel` getter
(the label of whichever internal sub-block `terminate()` most recently closed). Pass 2 — now that every
block's real final label is known, including a loop header's back edge, whose source block is emitted
textually AFTER the header — computes real predecessor edges from these captured labels and prepends
each block's phi lines to its own nominal entry label via a new `_FunctionEmitter.prependToLabel`
method. Verified via the exact LLVM IR dump that first exposed the bug (a real `clang` "PHI node
entries do not match predecessors!" / "Instruction does not dominate all uses!" verifier failure, not a
hypothetical), then via the full fourteen-target conformance suite with zero regressions — no other
target's codegen changed at all, confirmed by identical pass/fail behavior before and after. See
`docs/decisions/0028-while-loop.md`'s own "a real backend bug found along the way" section.

## File map

| File | Contents |
|---|---|
| `m0-target.md` | The original design doc — the *why* behind the M0-era choices. Read this first. |
| `lib/llvm_emit.dart` | `emitModule(DCModule)` → real LLVM IR text |
| `lib/compile.dart` | `compileToObject(llPath, objPath)` → shells to `clang -c` |

## Why `clang -c`, not `llc` (§3a of the design doc)

The design doc recommends `llc` as primary. This implementation uses `clang -c` instead because the
LLVM installs this project uses (winget's `LLVM.LLVM` on Windows, `apt`'s `llvm`/`clang` on
Ubuntu/WSL) ship `clang`/`llvm-nm` but no standalone `llc` binary. §3b's caveat table about several
`-f*` flags being "likely no-op for `.ll` input" is accepted here since this is the path actually
relied on, not a fallback.

## What's implemented

- **`DCInt`/`DCPointer`/`DCBool`/`DCStruct` types.**
- **`IAdd`/`ISub`/`IMul`** (all three present as a vocabulary — see `core/dc-ir/instructions.dart`).
  `Overflow.trapping` emits real trapping codegen (ADR-0009):
  `llvm.{u|s}{add|sub|mul}.with.overflow.iN` + a branch to `llvm.trap()`/`unreachable` — verified
  still freestanding (these are recognized intrinsics lowered inline, never an external call).
  `Overflow.wrapping` is plain `add`/`sub`/`mul` (already wraps on fixed-width integers).
- **`Load`/`Store`/`IntToPtr`** (ADR-0010, `Pointer<T>`) — opaque `ptr` type, pointee type carried by
  the instruction, not the pointer's own LLVM type.
- **`Branch`/`CondBranch`** with real multi-block + LLVM `phi`-node lowering (ADR-0012, predecessor
  tracking fixed for real in ADR-0028 — see the M2 section above). DC-IR's block *parameters* (not phi
  instructions — see `core/dc-ir/README.md`) are translated to real LLVM `phi`s here, since that
  translation is a backend/codegen concern per DC-IR's own design. First exercised for a loop back edge
  (ADR-0028) — `if`/`else` has never passed non-empty branch args.
- **`ICmp`** (ADR-0013): `icmp <pred> <type> %lhs, %rhs`, predicate names matching LLVM's own
  condition codes exactly. Verified including the unsigned-vs-signed edge case (`ugt` correctly
  treats `0xFFFF...FFFF` as larger than `1`, not as `-1`).
- **`MakeStruct`/`ExtractField`** (ADR-0014): by-value aggregates (`DCStruct` reused as a genuine
  by-value type, not just ADR-0011's pointer-backed layout descriptor). `MakeStruct` → a chain of
  `insertvalue` from `undef`; `ExtractField` → `extractvalue`. **Struct-by-value return across a
  C-callable boundary is verified correct** under the real SysV target (see below) — an earlier
  concern about Windows' different ABI turned out to be irrelevant to DCDart's actual target.
- **`PtrOffset`/`Alloc`/`Retain`/`Release`** (ADR-0015/0016, M2) — real ARC codegen against a fixed
  arena; see the M2 section above.
- **`Call`** (ADR-0018, M2) — a plain LLVM `call`/`call void`, no vtable/dispatch (direct calls only).
- **Destructor dispatch** (ADR-0022, M2) — `Alloc` writes a class's destructor address into `cls`;
  `Release` calls through it when non-null. Direct call through a statically-known function pointer,
  not a real multi-slot vtable (no dynamic dispatch exists in DCDart yet).
- **`MakeWeak`/`WeakLoad`/`DropWeak`** (ADR-0023, M2) — weak references with zombie-slot semantics;
  see the M2 section above.

Not implemented: float types, cycle-aware release (ORC, GAP-0017 item 4), elision (GAP-0017 item 2),
`unowned` (spec §3.3's other layer-1 variant), a real `ClassInfo` vtable for genuine runtime dispatch
(M5+, GAP-0003 retitled). Every unsupported case throws a specific `BackendError` naming what it hit.

## Verified, precisely

- `emitModule()` on the real `DCFunction` `dcc-lower` builds from `add.dart`:
  ```llvm
  define i64 @add(i64 %v0, i64 %v1) #0 {
  entry:
    %v2 = add i64 %v0, %v1
    ret i64 %v2
  }
  attributes #0 = { nounwind }
  ```
  Compiled via `dcc build --mode bare` (target `x86_64-unknown-none-elf`): the resulting `add.o`
  passes `verify-freestanding.sh`. Under WSL/Ubuntu, `core/tests/conformance/m0/run.sh` links it
  (freestanding, real Linux `_start` stub) and runs it: `add(2,3) == 5`. **Unqualified PASS.**
- Same pattern for `core/examples/m1-pointer/mmio.dart` (`inttoptr`/`store`/`load`) and
  `core/examples/m1-struct/header.dart` (packed field access via the same instructions, no new ones
  needed) — both report unqualified PASS, the struct one cross-checked byte-for-byte against an
  independent C reference struct.
- `core/examples/m1-result/result_demo.dart` (`MakeStruct`/`ExtractField`/`ICmp`/`CondBranch`/`phi`
  all in one real program) reports unqualified PASS — real struct-by-value return, read correctly by
  a real C caller, for all four test cases including both of `.propagate()`'s paths.

## The ABI question that got resolved along the way

While first verifying `Result<T,E>` return-by-value, a hand-built test (`makePair(111,222)` returning
raw LLVM `{i64,i64}`) got wrong values *when read back on this Windows dev host's native retarget*
(`x86_64-w64-windows-gnu` — Windows x64 needs `sret`-style hidden-pointer returns for structs over 8
bytes). Deliberately not guess-fixed at the time — that mismatch was against a verification proxy
(no Linux host was available yet — see `core/docs/known-gaps.md` GAP-0005), not against `@bare`'s
real target. Once WSL/Ubuntu became available, the identical test passed under real
`x86_64-linux-gnu`/SysV with **zero backend changes** — SysV classifies a `{i64,i64}` struct (two
plain-integer fields, ≤16 bytes) as a two-register return, exactly what was already emitted. Worth
remembering: a mismatch found via a cross-ABI verification proxy needs checking against the *real*
target before concluding the code is wrong — see `docs/known-gaps.md` GAP-0007 for the full story.
