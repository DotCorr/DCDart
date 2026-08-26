# dcc-lower — Kernel IR → DC-IR

Maps to `DCDART_SPEC.md` §1's `dcc-lower` stage. **Implemented and working, fully verified** for all
fifteen conformance targets — M0's `add`, M1's `Pointer<u32>` MMIO round-trip/`@packed` struct/
`Result<T,E>`/`.propagate()`, and M2's thirteen ARC/elision/recursion/mutability/control-flow/port-io
slices (ADR-0016 through ADR-0029 — real heap objects, alias retain, function calls, heap-typed signatures,
heap-typed fields, `@owned` parameters, destructor cascade, weak references, redundant-pair elision,
verified recursion, scalar reassignment, real `while`-loop control flow). Every one reports an
unqualified PASS under WSL/Ubuntu — not a stub, not "probably works." **GAP-0017's Retain-insertion
item (incl. `weak`), its elision item (pass 3), GAP-0003's destructor-cascade item, its
mutable-scalar-locals item, AND its scalar-loop item are now resolved**: every ownership-transfer,
object-death, and weak-reference shape spec §3.1/§3.2/§3.3-layer-1 describes has real, verified
codegen, and the first elision pass demonstrably fires (`dc-objdump --arc`, ADR-0024). **ADR-0026:** a
self-recursive `@bare` call needed ZERO new lowering logic — `_lowerBareCall`'s existing design
(ADR-0018) never distinguished "a different function" from "the function currently being lowered."
`u64` gained `operator -` (`ISub` already had real backend codegen since M0; only the source-level
operator and its `u64|-` recognition were missing) so a natural countdown recursion could be written at
all. **ADR-0027:** `x = <expr>;` for same-width scalar locals — found and fixed a real SSA-dominance
bug along the way (`_values`, the variable-binding table, lacked the per-`if`-branch snapshot/restore
`_heapLocals`/`_weakLocals` already had, so a reassignment inside a branch leaked into a sibling branch
or the fallthrough continuation — a genuine `clang`/LLVM "does not dominate all uses" failure, not a
hypothetical). **ADR-0028:** `while (cond) { body }` — needed zero new DC-IR instructions (a loop
header is just an ordinary block-parameter merge point, same mechanism `if`/`else` already uses, just
with real args for the first time); the real work was `_lowerWhile`'s loop-carried-variable analysis.
Found and fixed a real BACKEND bug (`core/backend`'s own README covers it) that predates this session
entirely — latent since M0's overflow-trapping arithmetic, invisible until a loop's back edge became
the first `phi`-bearing branch to follow a block containing arithmetic.

**M2 addition (ADR-0025):** `lowerToDCModule` now runs `elideRedundantRetainReleasePairs`
(`package:dc_elide`, a separate small package — see its own README/ADR for why: `dcc_lower`'s
vendored-`kernel` path dependency can't coexist with `package:test` in one pubspec, so the pass and
its tests live where they can be tested) on every function — user-lowered and synthesized destructors
alike — right before the module is returned. Spec §3.2 pass 3 (redundant-pair removal), deliberately
conservative: single-block only, invalidated by any `Call`/`MakeWeak`/`WeakLoad`/`DropWeak` in
between. Fires on `examples/m2-alias/alias.dart` (verified via `dc-objdump --arc`: `retain=1
release=2` → `retain=0 release=1`); correctly does NOT fire across a `Call` (`examples/m2-owned/
owned.dart`, unchanged) or a weak op (`examples/m2-weak/weak.dart`, unchanged).

**M2 addition (ADR-0016):** `class X extends HeapObject { ... }` — real stored Dart fields (not the
getter-pair approximation `@packed`/`Struct` use), a real generative constructor lowered via its
`FieldInitializer`s (only the `ThisClass(this.field)` shorthand pattern), `Alloc` on construction, a
naive (correct, non-elided) `Release` inserted before every `return` for each heap local not
identical to the returned value — scoped correctly per `if`/`else` branch (verified: a return in one
branch never double-releases a local from a sibling branch).

**M2 addition (ADR-0017):** `final b2 = b;` where `b` is `HeapObject`-typed — recognized as aliasing
(the initializer is a bare `VariableGet` of an existing heap-typed local), emits a `Retain`, and
tracks the release list by `VariableDeclaration` identity rather than `DCValue` identity so `b` and
`b2` (which share one DCValue — dc-ir has no copy instruction) are released independently instead of
double-releasing the same object. See `core/docs/known-gaps.md` GAP-0017 for what M2's Retain
insertion does NOT yet cover: heap references as function parameters, heap references stored inside
another heap object's field, and returning a heap pointer itself out of a function (only local
aliasing and "construct, use, drop" are proven).

**M2 addition (ADR-0018):** `siblingFn(args...)` where `siblingFn` is another `@bare`-annotated
top-level function in the same library — `_lowerBareCall`, checked last among `StaticInvocation`
shapes (after every prelude-member case, so a real prelude member can never be shadowed). Reuses
`_lowerType` against the *callee's* signature to lower its declared param/return types on demand — no
separate pre-pass building a signature table, since Kernel IR already fully resolves
`StaticInvocation.target` regardless of source order. A void-returning callee can't be called as an
expression yet, only as a statement, which isn't wired up either (no target has needed it).

**M2 addition (ADR-0019):** `_lowerType` now also recognizes a `HeapObject` subclass in
parameter/return position (via the same `heapLayouts.extendsHeapObject` check ADR-0016 already used
for constructor/field-access recognition), mapping to `DCHeapPointer(DCVoid())` — the same
placeholder-pointee value fresh construction already produces. This is what makes `class X extends
HeapObject` usable as a function's parameter or declared return type, not just a local variable's
inferred type. Parameters are borrowed by construction (they're bound directly in `lower()`, never
through the `VariableDeclaration` path `_heapLocals` tracking uses, so nothing extra was needed to
make them un-tracked); a heap-typed return value transfers ownership out exactly as a plain `return b;`
already did.

**M2 addition (ADR-0020):** `_lowerFieldType` (a SEPARATE helper from `_lowerType` above — this one
lowers a class's OWN field types, used by both `_StructLayouts` and `_HeapLayouts`) now also recognizes
a `HeapObject` subclass, but ONLY when called from `_HeapLayouts.layoutFor` (passes `heapLayouts:
this`) — `_StructLayouts.layoutFor` (`@packed`/`Struct`) never does, since a raw-memory, non-ARC'd
`@packed` struct has no meaningful way to hold a heap reference. Embedding a heap-typed field during
construction emits a `Retain` (the value always comes from a borrowed constructor parameter). This is
also where the `_lowerStatement` alias-retain check from ADR-0017 got generalized into a shared
`_isFreshHeapOwnership` helper — a borrowed field read (`final c = holder.inner;`) needed the exact
same "retain unless this is a known fresh-ownership source" treatment aliasing did.

**M2 addition (ADR-0021):** `@owned` on a `HeapObject`-typed parameter (spec §3.2 item 2's consuming
counterpart to ADR-0019's borrowed default) — since Kernel represents parameters as
`VariableDeclaration`s, an `@owned` parameter is simply added to `_heapLocals` during binding in
`lower()`, reusing every bit of the existing release machinery with no new tracking structure. The
caller side (`_lowerBareCall`) retains the argument via the same `_isFreshHeapOwnership` check ADR-0020
introduced, applied a third time. This is what finally makes a *genuinely unbounded* leak-free
alloc-then-free cycle possible across a function boundary — see `examples/m2-owned/owned.dart`.
`docs/known-gaps.md` GAP-0017's Retain-insertion item is resolved as of this addition; what's left
(elision, `weak`/`unowned`, cycles) is correctly later-milestone scope, not undone M2 work.

**M2 addition (ADR-0022):** a destructor cascade for `HeapObject`s holding other `HeapObject`s.
`_StructField` gained `heapFieldClass` (the CONCRETE class a heap-typed field points to — `_lowerType`/
`_lowerFieldType` only ever produce the `DCHeapPointer(DCVoid())` placeholder, GAP-0003, so this
tracks what the DCType alone can't say). `_HeapLayouts.destructorNameFor(cls)` (cached) decides
whether a class needs a destructor at all (only if it has ≥1 heap-typed field). `_lowerHeapConstruction`
now passes this name to `Alloc` — the ONE place a heap object's class is always known for certain.
`lowerToDCModule` synthesizes one destructor `DCFunction` per class that needs one (`_buildDestructor`
— never sourced from user code, no `_BareFunctionLowerer` machinery needed, just a straight-line
`PtrOffset`+`Load`+`Release` per heap-typed field). Cascading to a field's OWN destructor needs no
recursive logic here at all — releasing a field emits a plain `Release`, and the backend's now-uniform
`Release` codegen (docs/decisions/0022) checks that field's own `cls` at runtime, correctly populated
back when IT was `Alloc`'d. **Direct destructor call, not a real `ClassInfo` vtable** — no dynamic
dispatch exists anywhere in DCDart yet, so a heap object's concrete class is always statically known;
see the ADR for why a full vtable would be premature complexity right now.

**M2 addition (ADR-0023):** `Weak<T>` (spec §3.3 layer 1). `Weak<Box>.fromStrong(target)` (a
`ConstructorInvocation`, checked among the others in `_lowerExpression`) → `MakeWeak`. `weakRef.value`
(an `InstanceGet`, checked FIRST among InstanceGet shapes since `value` is also `Pointer<T>`'s own
getter name — distinguished by `enclosingClass.name == 'Weak'` + the prelude URI) → `WeakLoad`.
`_isFreshHeapOwnership` (the shared helper ADR-0017/0020/0021 already built) now ALSO recognizes a
`Weak<T>.value` read as a fresh-ownership source — `WeakLoad`'s own codegen already retains when the
target is alive, so treating this `InstanceGet` as "needs another retain" (the default for
`InstanceGet`) would double-retain. A new `_weakLocals` list mirrors `_heapLocals` exactly (same
`VariableDeclaration`-identity tracking, same `if`/`else` branch snapshot/truncate, same `@owned`
parameter convention, same except-by-declaration return logic — `_lowerReturn` now calls
`_releaseWeakLocals` alongside `_releaseHeapLocals` with the SAME `exceptDecl`), released via
`DropWeak` instead of `Release`. Weak-to-weak aliasing (`final w2 = w1;`) is explicitly unsupported —
`MakeWeak` only accepts a `DCHeapPointer` source, so this throws a clear `DccLowerError` rather than
silently under-counting.

**M2 addition (ADR-0027):** `x = <expr>;` (Kernel's `VariableSet`, recognized in `_lowerStatement`'s
`ExpressionStatement` branch) for a scalar (`u8`/`u32`/`u64`) local — looks up the variable's current
`DCValue` in `_values`, lowers the RHS, checks same-width (no implicit widening, same rule as
arithmetic), and rebinds `_values[variable]`. Heap/weak-typed reassignment is rejected with an error
pointing at `known-gaps.md` (needs an ownership policy this project hasn't decided — release the old
value? require it already null?). **`_lowerIf` now snapshots and restores `_values` around each
branch** (`Map.from(_values)` before, `_values..clear()..addAll(snapshot)` after), mirroring the
pre-existing `_heapLocals`/`_weakLocals` pattern exactly — added because reassignment, unlike plain
reads, mutates an existing binding in place, and without scoping that mutation leaked across branches.

**M2 addition (ADR-0028):** `while (cond) { body }` — `_lowerWhile`. A pure Kernel-AST pre-scan
(`_collectLoopCarriedCandidates`) finds every `VariableSet` target reachable in the body (recursing
into `Block`/`IfStatement`, throwing on a nested loop), filtered to only variables already tracked in
`_values` before the loop starts (a fresh loop-body-local variable is naturally excluded — it isn't in
`_values` yet at scan time). Those become the loop header block's params; the header is entered both
by an initial `Branch` (current values) and, if the body doesn't return on every path, a back-`Branch`
from wherever the body's lowering left off (reusing `_lowerBranchBody`, so a nested `if` inside the
body composes for free). After the body closes, `_values` for loop-carried variables is restored to
the header's own params — the exit block is only reachable via the header's false edge, never through
the body, so what's live there is the header's phi params, not whatever the body last computed (same
restore-after-branch reasoning ADR-0027 established for `_lowerIf`, specialized to a loop header).
Heap/weak locals inside the body are explicitly rejected (checked via `_heapLocals`/`_weakLocals`
length before/after) — the naive release policy has no policy for a back edge that isn't a `return`.

## File map

| File | Contents |
|---|---|
| `lib/kernel_frontend.dart` | Shells to `dart compile kernel` to get real Kernel IR (`.dill`) for a `.dart` source file, via a synthetic driver — never modifies the source |
| `lib/lower.dart` | `_BareFunctionLowerer`: a real block builder (`_startBlock`/`_finishBlock`/`_addInstr`, tracking whether a block is open) walking a `Procedure`'s statements — locals, property get/set, `if`, return — via the vendored `package:kernel`, building a (possibly multi-block) `DCFunction` |

## The frontend strategy — why `dart compile kernel`, not the vendored `pkg/front_end` API

See `core/docs/decisions/0008-m0-frontend-strategy.md` for the full reasoning. Short version: real
DCDart syntax (`@bare`, `u64`) doesn't need a modified compiler frontend at all — Dart's **extension
types** let `core/runtime/dc-core-bare/prelude.dart` define `u64` and `bare` as ordinary library
declarations that real, unmodified `pkg/front_end` (invoked via the installed SDK's stable
`dart compile kernel` CLI) already understands correctly. `kernel_frontend.dart` writes a temp driver
file (`import '<source>'; void main() {}` — a bare unused import is enough to retain the source
library's members in the emitted Kernel IR, confirmed empirically) and shells out.

The vendored `core/frontend/vendor/dart-sdk/pkg/front_end` (ADR-0005/0007) is **not** used by this
code. It's kept vendored and pub-resolvable for when this approach genuinely runs out — real builtin
syntax needing no import, trapping-arithmetic-as-a-type-property, anything an extension type/
annotation can't express. That's a front_end fork for real; not needed yet.

## What `lower.dart` recognizes — exactly, not approximately

Empirically verified against real Kernel IR (see ADR-0008 for the introspection that produced these,
re-derivable by rerunning it):

- `@bare`: a `ConstantExpression` annotation on the `Procedure` wrapping an `InstanceConstant` whose
  `classNode.name == '_Bare'` and whose `classNode.enclosingLibrary.importUri` equals the prelude's
  URI (checked by URI, not name, so an unrelated user type can never be misread as DCDart's).
- `u64` parameter/return types: `DartType is ExtensionType` with
  `extensionTypeDeclaration.name == 'u64'` from the prelude's URI.
- `a + b`: `FunctionNode.body is ReturnStatement` (not wrapped in a `Block`) whose `.expression is
  StaticInvocation` targeting `u64|+` (`isExtensionTypeMember == true`, same prelude URI), with two
  `VariableGet` arguments naming the function's parameters.
- (M1, ADR-0010) `final x = Pointer<u32>.fromAddress(addr);`: a `VariableDeclaration` whose
  `.initializer is ConstructorInvocation` targeting `Pointer.fromAddress`, same prelude URI, with the
  generic type argument (`arguments.types`) read to determine the pointee `DCType`.
- (M1) `p.value = x;` / `p.value`: `InstanceSet`/`InstanceGet` targeting a member named `value` whose
  `enclosingClass.name == 'Pointer'`, same prelude URI.
- (M1, ADR-0011) `@packed class X extends Struct { ... }`: a class-level `_Packed` annotation plus a
  supertype chain reaching the prelude's `Struct`. Field getters/setters are read back via
  `Class.procedures` (declaration order, verified empirically to be preserved) to compute packed byte
  offsets — see `_StructLayouts` in `lib/lower.dart`. `instance.field` reuses the exact same
  `ConstInt`+`IAdd`+`IntToPtr`+`Load`/`Store` sequence `Pointer<T>.value` produces; no new DC-IR
  instruction was needed.
- (M1, ADR-0014) `if (cond) { ... } [else { ... }]`: real `IfStatement` lowering — every written
  branch must terminate (`return`); an `if` without `else` leaves the false path open as the
  fallthrough continuation for subsequent statements (no phi/merge-from-source support — see
  `core/docs/known-gaps.md` GAP-0007). `cond` is recognized via `u64|<` (a `StaticInvocation`, same
  shape as `u64|+`) assigning `DCBool` directly — never via Kernel's own inferred `bool` type, which
  is an unbound platform reference under `--no-link-platform` and crashes on inspection (verified).
- (M1, ADR-0014) `Result.ok(x)`/`Result.err(x)`: `StaticInvocation`s with `target.isFactory == true`,
  `target.enclosingClass?.name == 'Result'`, same prelude URI → `MakeStruct`.
- (M1, ADR-0014) `result.propagate()`: an `InstanceInvocation` targeting a member named `propagate`
  whose `enclosingClass.name == 'Result'` → `ExtractField` (tag, payload) + `ICmp` + `CondBranch`,
  checking the enclosing function's own declared return type actually is `Result` (unlike real `?`,
  Dart's checker doesn't enforce this for a plain method call — dcc-lower does instead).
- `u64(1)` (a sized-int literal): `StaticInvocation` targeting `u64|constructor#`, with a single
  `IntLiteral` argument — only literal arguments are handled (no int→u64 conversion instruction
  exists, and DCDart has no implicit conversions anyway per spec §4.1).
- (M2, ADR-0016) `HeapClass(args...)` where `class HeapClass extends HeapObject`: a
  `ConstructorInvocation` (target name `""` for the default constructor) whose class transitively
  extends the prelude's `HeapObject` marker → `Alloc` + one `PtrOffset`+`Store` per
  `Constructor.initializers` entry (`FieldInitializer`s only, `SuperInitializer` skipped; only the
  `ThisClass(this.field)` shorthand — a `FieldInitializer.value` that's a direct `VariableGet` of a
  constructor parameter — is handled). `heapInstance.field` is an `InstanceGet` on a `HeapObject`
  subclass → `PtrOffset`+`Load`, reading `Class.fields`' declaration order for the offset.
- (M2, ADR-0017) `final b2 = b;` where `b` is `HeapObject`-typed: a `VariableDeclaration` whose
  `.initializer is VariableGet` referencing another already-tracked heap-typed local → emits `Retain`
  on the shared `DCValue` and tracks `b2` as its own release-scoped entry (by `VariableDeclaration`
  identity, not `DCValue` identity — see the ADR for why the distinction matters here specifically).
- (M2, ADR-0018) `siblingFn(args...)`: a `StaticInvocation` whose `target` is a `Procedure` carrying
  the same `_Bare` marker annotation `lowerToDCModule` itself uses to decide what to lower → `Call`,
  with the callee's declared param/return types re-lowered on demand via `_lowerType`.
- (M2, ADR-0019) `HeapClass param` / `HeapClass functionName(...)`: an `InterfaceType` whose
  `classNode` transitively extends the prelude's `HeapObject` marker (checked in `_lowerType`, the
  same `heapLayouts.extendsHeapObject` used elsewhere) → `DCHeapPointer(DCVoid())`. Makes a
  `HeapObject` subclass usable as a function's parameter or declared return type.
- (M2, ADR-0020) `class Y extends HeapObject { final HeapClass field; ... }`: the identical
  `extendsHeapObject` check, now inside `_lowerFieldType` (a class's OWN field types — a different
  helper from `_lowerType` above), gated to only fire when called with `heapLayouts:` non-null (i.e.
  only from `_HeapLayouts.layoutFor`, never from `_StructLayouts.layoutFor`). Constructing `Y` with
  such a field emits a `Retain` on the embedded value.
- (M2, ADR-0021) `@owned` on a `HeapObject`-typed parameter: a marker annotation
  (`_hasMarkerAnnotation(param.annotations, '_Owned', preludeUri)`, same pattern as `@bare`/`@packed`)
  checked during parameter binding in `lower()` → the parameter (itself a `VariableDeclaration` in
  Kernel IR) is added to `_heapLocals`, reusing the existing release machinery unchanged. The caller
  side (`_lowerBareCall`) retains the argument unless it's a fresh-ownership source.
- (M2, ADR-0023) `Weak<Box>.fromStrong(target)`: a `ConstructorInvocation` on `Weak`, same prelude URI
  → `MakeWeak`. `weakRef.value`: an `InstanceGet` targeting `value` on `Weak` (checked before
  `Pointer<T>.value` and every `HeapObject`/`Struct` field-read case, since the member name `value`
  alone is ambiguous across all of them) → `WeakLoad`. `Weak<T>` in parameter/return position:
  `_lowerType` recognizes it the same way it recognizes `HeapObject` subclasses, mapping to
  `DCWeakPointer(DCVoid())`.
- (M2, ADR-0027) `x = <expr>;` where `x` is a scalar (`u8`/`u32`/`u64`) local: Kernel's `VariableSet`,
  recognized inside `_lowerStatement`'s `ExpressionStatement` handling → rebinds `_values[x]` to the
  lowered RHS after a same-width check. Heap/weak-typed reassignment throws (no ownership policy
  decided yet).
- (M2, ADR-0029) `Port.outb(port, value)` / `Port.inb(port)`: plain static-method calls on `Port`,
  recognized directly (not extension-type members, not factory constructors) → `PortOut`/`PortIn`.
  `outb` is void-returning — recognized in `_lowerStatement`'s `ExpressionStatement` handling as a
  bare statement, the first void-returning call this project has needed to lower that way. `u8(1)` /
  `u16(1)` / `u32(1)` literal construction (previously only `u64(1)` was recognized) generalized
  alongside this, since a UART init sequence needs literal byte/port values constantly.
- (M2, ADR-0028) `while (cond) { body }`: Kernel's `WhileStatement` → a block-parameter loop header
  (entry `Branch` + conditional back-`Branch`), loop-carried scalar locals found by a pre-scan of the
  body for `VariableSet` targets already tracked before the loop starts. `for`/`do-while`,
  `break`/`continue`, nested loops, and heap/weak locals inside the body all throw explicitly.

- (M2, ADR-0057) NON-CAPTURING local functions, in both Kernel spellings: `u64 dbl(u64 v) => v + v;`
  inside a body is a `FunctionDeclaration` statement called through `LocalFunctionInvocation`;
  `final f = (u64 v) => ...;` is a `VariableDeclaration` with a `FunctionExpression` initializer,
  called through `FunctionInvocation` on a `VariableGet`. Neither emits an instruction at the
  declaration: the body is HOISTED to its own top-level `DCFunction` named `enclosing$local`
  (`twiceSum$dbl`, qualified by the EMITTED name of the enclosing body so a local inside
  `Box.doubled` becomes `Box_doubled$g`), queued in the same drain loop as ADR-0052's
  specializations, and every call site lowers to an ordinary direct `Call`. Because the callee is
  statically known, `argOwnership` is exact and elision is unaffected — `tests/conformance/closure/`
  asserts the ARC counts are identical to writing the same callee at top level.

  A `_ClosureScan` over the function's own body (deliberately not descending into nested functions,
  each of which is scanned when it is itself hoisted) separates VALUE references from CALL
  references: a free value reference — or `this` — is a real capture and is **rejected**; a free call
  reference naming another hoisted local function is not, which is what makes self-recursion and
  sibling calls work. **Rejected, each with a diagnostic naming the reason:** any capture
  (escalation 0002/0008 — needs an environment, needs a heap), a function used as a value or a
  function type in any signature (GAP-0052 — DC-IR has no function-pointer type and no indirect
  call), a function expression anywhere but a local's initializer, a local function called as a bare
  statement, and generic/named-parameter/`async` local functions.

Anything else — a different operator, a non-`u8`/`u32`/`u64`/`Result` type, a second `Pointer<T>`
instantiation, natural-alignment (non-packed) struct layout, merging control flow back together after
an `if`, a CAPTURING closure or a function value — throws `DccLowerError` naming exactly what it hit and why it's unsupported, rather than
silently mishandling it. Extend this file when a real conformance target actually needs more, per
this project's own convention (see `core/dc-ir/instructions.dart`'s identical discipline) — not
speculatively.

## Known simplification

`core/dcc/lib/pipeline.dart` locates the prelude relative to `dcc.dart`'s own file location on disk
(`Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart')`), not via a real `dc:`-scheme
library resolver. This means `dcc` currently only works run from inside this exact checkout layout.
Flagged in `pipeline.dart`'s own doc comment — a real toolchain needs proper library resolution,
which is front_end-fork territory (ADR-0008's deferred alternative).
