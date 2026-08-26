# ADR-0060: Function pointers carry their ARC convention in their type, so an indirect call is not an elision barrier

**Status:** decided and implemented, verified (`tests/conformance/funcptr/`)

**Closes GAP-0052.** Answers `docs/escalations/0008` **§3 only**. §2 — the capture convention, and the
`[weak self]`-shaped language surface `CLAUDE.md`'s cycle rule needs to be enforceable — is
**untouched and still open**, deliberately: a capturing closure is not lowered by this change and is
still rejected with the same diagnostic ADR-0057 wrote.

## Context

ADR-0057 landed non-capturing closures by hoisting each local function to a top-level symbol and
calling it with an ordinary direct `Call`. It said plainly what it was not: "a closure that cannot be
passed to a function is not much of a closure." `ROADMAP.md`'s M3 benchmark suite names a
**closure-heavy functional workload**, and `map`/`filter`/`fold` are all *a function taking a
function*, which DC-IR could not express at all — `Call.targetName` is a `String`, there was no
function-pointer `DCType`, and no indirect-call instruction anywhere in `dc-ir/` or `backend/`.

The backend was in fact already emitting one real indirect call: ADR-0022's destructor dispatch loads
a pointer out of the object header's `cls` field and emits `call void %clsVal(ptr …)`, special-cased
inside `Release`'s expansion for one fixed signature. So the LLVM half was known-good. What was
missing was a DC-IR instruction, a type, and signature variance.

### The hard part, which is not the calling

`Call.argOwnership` exists so `dc-elide` can tell a **load-bearing** retain/release pair (the callee
borrows, so the caller's own reference must outlive the call) from a **redundant** one (the callee
consumes, so the pair cancels — ADR-0025's worked example, ADR-0031's pass). `dcc-lower` computes it
**from the known callee's declaration**.

Through a value there is no declaration. Escalation 0008 §3 put it exactly: ownership is "not
conservatively derivable — it is **not derivable at all**." Assuming "borrowed" is the safe
direction, and it makes **every indirect call site an elision barrier**: keep every pair, retain and
release across every closure invocation.

Spec §3.2 calls elision "the whole ballgame". M3's gate is a geometric mean of ≤10% vs C. So the
benchmark that most exercises closures would have been the one measuring unelided ARC, and — 0008's
words again — **"closures are slow in DCDart" would get frozen into the compat matrix as a fact about
the language when it is a fact about one missing analysis.**

## Decision

**Put the ownership in the function pointer's type.**

```dart
final class DCFuncParam { final DCType type; final bool owned; }
final class DCFuncPtr extends DCType {
  final List<DCFuncParam> params;
  final DCType returnType;
}
```

Three DC-IR additions, and the middle one is where the whole argument lives:

| | what it does |
|---|---|
| `DCFuncPtr` | the type of a function VALUE, recording per-parameter `@owned` |
| `FuncRef` | materializes a named function's address as a value of that type |
| `IndirectCall` | calls through such a value |

**`IndirectCall` has no `argOwnership` field.** It is a getter that reads
`(callee.type as DCFuncPtr).paramOwnership`. `Call` needs a field because its callee is a bare string
carrying no signature; here the callee is a typed operand and the type already says it, so storing a
second copy would only create something that can drift out of agreement with the pointer actually
being called. `dc-elide` therefore consumes exactly the same fact for both call forms.

### Why the type is the right carrier, in one line

A function pointer can only be created by `FuncRef`, and `FuncRef` is only ever emitted from a
**named function whose declaration is in hand** — a top-level `@bare` procedure (`StaticTearOff`) or
a hoisted local function (`VariableGet` of its declaration). At that one point the `@owned`
annotations are in plain sight, so the recorded convention is **derived, not assumed**. Every later
use — binding to a local, passing as an argument, returning — carries it, checked by ordinary
`DCType` equality, which `dcc-lower` already enforces everywhere with its no-implicit-widening rule.
The call site is then exactly as informed as a direct call site; it is simply informed by a different
carrier.

### No variance, and this is not conservatism

`DCFuncPtr.==` is exact in `owned` as well as in the parameter types. Neither coercion is safe:

- an **owned**-consuming pointer through a **borrowed**-typed slot: the caller keeps its own
  reference and releases it, and the callee releases too → **double release**;
- a **borrowed** pointer through an **owned**-typed slot: the caller retains before the call and
  nothing ever releases that retain → **leak**.

A subtype lattice over ARC conventions would be a memory-model change, which `CLAUDE.md` rule 4 does
not let an implementation unit make.

### Where the ownership cannot be written down, said plainly

A Dart *function type* carries no annotations — Kernel's `FunctionType.positionalParameters` is a
`List<DartType>`, and `@owned` lives on a `VariableDeclaration`, which a function type has none of.
So `_lowerType`'s `FunctionType` case can only produce the **all-borrowed** `DCFuncPtr`, and a
pointer to a consuming function therefore **cannot be passed to a parameter declared with an ordinary
Dart function type**. That is a real restriction, filed as **GAP-0057**, and it surfaces as a hard
type error with a diagnostic that says why and what to do instead — not as a silent coercion. It does
not affect the benchmark shape: `map`/`filter`/`fold` callbacks borrow.

### Backend: the existing special case became an instance, not a neighbour

`_emitCallText` is now the only place this backend writes an LLVM `call`. `Call` passes `@name`,
`IndirectCall` passes `%vN`, and **ADR-0022's destructor dispatch passes `%clsVal` through the same
helper** instead of the hand-written line it used to be. A second parallel way to emit an indirect
call is precisely the thing that later diverges (attributes, calling conventions, tail-call markers)
without anyone noticing.

`FuncRef` emits `%vN = bitcast ptr @f to ptr`. LLVM has no take-the-address instruction — a function
symbol *is* a `ptr` constant — but this emitter's single invariant is that a `ValueId` is always
`%vN`, and `instcombine` folds the bitcast away before any code is generated. `DCFuncPtr` is a plain
opaque `ptr` at the LLVM level: since LLVM 15 there is no distinct function-pointer type, and a
call's signature is written at the call site. DC-IR's type therefore carries strictly *more* than
LLVM's can — the ownership — which is consumed upstream, by `dc-elide`, and has no LLVM
representation to lose it in.

## Verification — the numbers, which are the point

`examples/m3-funcptr/funcptr.dart` contains the same program written four ways: an
`@owned`-consuming callee reached by a top-level name, by a hoisted local name, through a pointer to
the hoisted local, and through a pointer to the top-level one.

```
viaTopLevel:          alloc=1 retain=0 release=0     <- direct, ADR-0057's baseline
viaClosure:           alloc=1 retain=0 release=0     <- direct, hoisted local
viaFuncPtr:           alloc=1 retain=0 release=0     <- INDIRECT
viaTopFuncPtr:        alloc=1 retain=0 release=0     <- INDIRECT
borrowViaFuncPtr:     alloc=1 retain=1 release=2     <- INDIRECT, borrowed: pair SURVIVES
```

**The indirect call is not an elision barrier.** Escalation 0008 §3 predicted lines 3 and 4 would
come back as `retain=1 release=1`; they did not. The borrowed line is asserted at its own exact
counts in the same harness, because an elision pass that dropped *that* pair would make the first
four numbers look even better while introducing a use-after-free — "fewer retains" is not by itself
the property being checked.

**Escalation 0008 §6's own four lines are unmoved**, re-run on `examples/m2-closure` after this
change:

```
viaTopLevel:          alloc=1 retain=0 release=0
viaClosure:           alloc=1 retain=0 release=0
dropTop:              alloc=0 retain=0 release=1
viaClosure$dropLocal: alloc=0 retain=0 release=1
```

Other verification:

- `tests/conformance/funcptr/run.sh`: **PASS**. Freestanding spine check; an **indirect branch read
  out of the disassembly** of `dispatch` (a pointer chosen at run time and returned across a function
  boundary, so no optimizer can devirtualize it — an implementation that constant-folded every
  pointer would compute identical answers and prove nothing); the ARC assertions above; symbol-table
  assertions that a torn-off local function is a real qualified symbol; a DCDart higher-order
  function called **from C with a C function pointer**; and 2000 leak-free heap cycles with
  `dc_heap_live` (ADR-0058, `uint64_t`) checked back at zero after **every** call.
- `dc-elide`: **11 tests pass** (was 6). The three safety-critical direct-call tests are written out
  a second time against `IndirectCall` rather than parameterized — the claim is that the two forms
  are treated identically, and a shared helper running both would make a future divergence invisible
  by construction.
- `scripts/verify-freestanding.sh`: **FREESTANDING: pass**. A `FuncRef` names a symbol; if one were
  ever referenced without being defined, this is where it shows. Atomics still lower to instructions
  with no `__atomic_*` libcall — nothing here touches that.
- Full suite: **40 passed, 0 failed, 0 skipped** on Darwin/arm64 (was 39 before this target).
- `dart analyze`: the same four pre-existing warnings in `lower.dart`, no new ones, all packages
  clean.

## Consequences

- **The functional workload is writable.** It is the last of GAP-0035's rows that "got no closer"
  under ADR-0057.
- **Ownership is now part of a type**, which makes it a memory-model surface (`CLAUDE.md` rule 4).
  Deciding it before M3 rather than after is the point; a later change to how `DCFuncPtr` compares is
  a rule-4 escalation, not an implementation choice.
- **Capturing closures are still rejected**, unchanged. What did change in the capture scan is
  narrow: a sibling or own local function's name in **value** position is no longer a capture, for
  exactly the reason it was already not one in **call** position — the name resolves to a static
  symbol, not to a slot in the enclosing frame.
- **`@extern` C functions cannot be torn off** (GAP-0059). Their ARC convention is whatever the C
  author decided and nothing here can check it, so the `DCFuncPtr` would be an assertion rather than
  a derivation — the one thing this ADR is built to avoid.
- **The generated C header can spell a function pointer but not its ownership** (GAP-0058). C has no
  way to say `@owned` and no compiler that would enforce it.
- **A pre-existing leak was found while writing the example, not caused by it** (GAP-0060): a `void`
  `@bare` function whose body falls off the end without an explicit `return` never releases its
  `@owned` heap parameters. `consumeReturn(@owned Box b) { return; }` releases; `consumeEmpty(@owned
  Box b) {}` does not. It reproduces on `main` with an ordinary direct call and has nothing to do
  with function pointers.

## Rejected alternatives

**Make every indirect call an elision barrier** (assume borrowed). What escalation 0008 predicted
would happen, and the reason it is an escalation and not a gap. It is one line of code and it costs
the M3 measurement its meaning on one of five benchmarks. Rejected explicitly rather than by
omission, because it is what a unit under schedule pressure does.

**Carry `argOwnership` on `IndirectCall` as a field, filled in by dcc-lower from the tear-off it can
see.** Works for `final f = g; f(x);` and fails the moment the pointer crosses a function boundary,
which is the only shape that matters. Worse, it looks correct in exactly the cases anyone would test
first.

**Invent syntax for `@owned` inside a function type** (`u64 Function(@owned Box)`). This is a spec §4
language-surface addition and a §3 ARC-convention decision at once. It is the honest fix for
GAP-0057, and it is not an implementation unit's to make — the same reasoning ADR-0057 used to refuse
the capture convention.

**Represent a function pointer as `DCPointer(DCVoid())`.** No type for ownership to live in, which
gives back the whole problem, and it would let `Load`/`Store` be applied to code.
