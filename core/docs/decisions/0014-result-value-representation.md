# ADR-0014: Result<T,E> as a by-value tagged struct, not a heap object

**Status:** decided, implemented, and fully verified end to end (real `dcc build` → real freestanding
link → real run, under WSL/Ubuntu, all correct) — M1's third and final exit-criterion clause is done

## Context

`DCDART_SPEC.md` §5 shows `Result<T,E>` as a `sealed class` hierarchy (`Ok`/`Err` subclasses) — real
heap allocation in general. `@bare` has no allocator/ARC machinery built yet (M2), and forcing
`Result` — used for routine error handling, potentially on hot paths — through a heap allocation this
project can't even build yet would be a strange dependency to introduce for M1's exit criterion.

## Decision

Represent `Result<u64, u64>` as a `{tag: u64, payload: u64}` **value** (tag 0 = Ok, 1 = Err) — no heap
allocation, no ARC. `core/dc-ir`'s `DCStruct` (already existed, previously only used descriptively by
ADR-0011's pointer-backed struct pattern, which never actually constructs a `DCStruct` *value*) is
reused for this — its `(name, fields)` shape and structural equality are exactly what a by-value
tagged aggregate needs too, and nothing about `DCStruct` itself says "this is memory-layout-only."
Documented explicitly in `types.dart`: `DCStruct` is used two ways (pointer-backed layout descriptor,
or genuine by-value aggregate), determined by which instructions a consumer applies to it, not by
anything on the type.

Two new `core/dc-ir` instructions: `MakeStruct` (construct a struct value from field values, in
declared order) and `ExtractField` (take one field back out of a struct value) — deliberately
distinct from `Load`/`Store`/`IntToPtr` (which dereference pointers); these never touch memory.
`core/backend` lowers `MakeStruct` to a chain of LLVM `insertvalue` starting from `undef`, and
`ExtractField` to `extractvalue`.

`core/runtime/dc-core-bare/prelude.dart` gained `Result` (factory constructors `.ok`/`.err`, and
`.propagate()` — the named-method approximation for `?`, per `escalations/0001`) and `u64 operator <`
(needed for a real `if` condition to build a meaningful Ok/Err-producing test — the exact Kernel IR
shapes for `IfStatement` and the `u64|<` synthesized member were verified empirically the same way
every other prelude addition was).

**Verified in isolation** (same discipline as ADR-0012/0013): a hand-built `DCFunction` constructing
a `{tag,payload}` value via `MakeStruct`, then reading each field back via `ExtractField` (never
crossing the C boundary as a struct — see Consequences), compiled, linked, ran correctly for 4 cases,
confirmed still freestanding.

## Consequences — the ABI question this decision surfaced, and its resolution

Trying to verify the *complete* path — a `@bare` function whose own return type is the `Result`
struct, called from C — surfaced a real question: a hand-built test (`makePair(111, 222)` returning a
raw LLVM `{i64,i64}`, read back via an equivalent C struct) got wrong values *on this dev host's
Windows-native retarget* (`x86_64-w64-windows-gnu` — Windows x64 uses a hidden-pointer `sret`
convention for structs over 8 bytes). Deliberately not guess-fixed at the time — that mismatch was
against a verification proxy (GAP-0005's native-retarget workaround for not having a Linux host), not
against `@bare`'s actual target.

Once WSL/Ubuntu became available (GAP-0005 resolved), the identical `makePair` test was re-run under
real `x86_64-linux-gnu` (SysV): **correct, no `core/backend` change needed.** SysV classifies a
`{i64,i64}` struct (two plain-integer fields, ≤16 bytes) as a two-register return — exactly what
`core/backend` already emitted. The Windows mismatch was real but irrelevant to DCDart, which was
never targeting Windows.

`core/dcc-lower`'s `IfStatement`/`Result`/`.propagate()` lowering is fully verified end to end:
`core/examples/m1-result/result_demo.dart` builds via real `dcc build --mode bare`, passes
`verify-freestanding.sh`, links (freestanding, real Linux `_start` stub) and runs correctly —
`core/tests/conformance/m1-result/run.sh` reports an unqualified PASS. All three M1 exit-criterion
clauses (`docs/known-gaps.md` GAP-0007) are now resolved. This is genuinely done, not "structurally
verified pending runtime confirmation."
