# ADR-0057: Non-capturing closures — hoist to a static function, call it directly

**Status:** decided and implemented, verified (`tests/conformance/closure/`)

**Scope, stated first because the name overstates it.** This lands *non-capturing* closures only. A
function expression or local function declaration that reads nothing from an enclosing scope is not
a closure at run time at all — it is a static function that happened to be written inside another
one. That is the entire feature. Capturing closures and closures-as-values are **not** landed and
are **not** deferred casually: they are
`docs/escalations/0008-closure-capture-and-indirect-call-elision.md`, still open.

**Why this did not need escalating.** `CLAUDE.md`'s escalate-only list covers spec §3 (memory
model), §4.1 (integers) and §7 (strings). This touches none of them:

- **No new ARC convention.** Capture is what would introduce one ("does a captured heap reference
  retain?"), and capture is rejected at compile time here, by name, with a diagnostic pointing at
  escalation 0008. The one ARC-adjacent change is that a call to a hoisted local function counts as
  a fresh-ownership source — which is ADR-0019's *existing* return-transfer convention applied to a
  second spelling of the same thing, not a new rule. Without it, `final b = mk(v);` would retain a
  reference nobody else holds and leak.
- **No new language surface.** Function expressions and local functions are ordinary Dart. Nothing
  was added to the prelude and no syntax was invented. Contrast escalation 0008 §2, where the
  capture convention drags in a `[weak self]`-shaped §4 addition.
- **No new `@bare` runtime symbol.** Hoisting emits ordinary `define`s. `FREESTANDING: pass` on all
  five targets tried, including `bare-x86_64`.
- **Rule 2 clean.** `FunctionExpression`, `FunctionDeclaration`, `FunctionInvocation` and
  `LocalFunctionInvocation` are all existing upstream Kernel nodes. Nothing was added to
  `pkg/kernel`.

## Context

GAP-0035 lists closures as one of the prerequisites M3's benchmark suite needs, and before this
change `dcc-lower` rejected them in two different places with two different messages
(`unsupported expression FunctionExpression`, `unsupported statement FunctionDeclaration`).

Reading that as "add a `FunctionExpression` case" is the mistake escalation 0008 exists to prevent.
Three things are missing under it, and only the first is a lowering. The second is a DC-IR
instruction that does not exist (GAP-0052); the third is an allocator that does not exist
(escalation 0002, open). **The subset that needs none of the three is worth landing on its own**,
and it is what this ADR is.

## Decision

A local function is **hoisted** to a top-level `DCFunction` and every call to it is an ordinary
direct `Call`. Both Kernel spellings are recognized:

| source | Kernel | call site |
|---|---|---|
| `u64 dbl(u64 v) => v + v;` inside a body | `FunctionDeclaration` statement | `LocalFunctionInvocation` |
| `final f = (u64 v) => v + u64(3);` | `VariableDeclaration` + `FunctionExpression` | `FunctionInvocation` on a `VariableGet` |

Four properties follow, and they are the reason this shape was chosen.

**1. Zero allocation.** There is no environment, so there is nothing to allocate. This is not "the
allocator question deferred" — the question does not arise. The subset is defined precisely by the
absence of the thing that would need a heap.

**2. Zero new DC-IR.** The callee is a symbol. `Call` already carries a symbol name. No
`IndirectCall`, no function-pointer type, no backend change of any kind — the whole feature is
`dcc-lower` plus tests.

**3. Elision is unaffected — measured, not assumed.** `Call.argOwnership` is computed from the
callee's `FunctionNode`, which is right there, so it is **exact**. `examples/m2-closure/` contains
`viaTopLevel`/`viaClosure`: the same program with the `@owned`-consuming callee at top level versus
inside the body. `dc-objdump --arc` reports them identical, and ADR-0031's call-consumed pass elides
the retain/release pair in both:

```
viaTopLevel:          alloc=1 retain=0 release=0
viaClosure:           alloc=1 retain=0 release=0
dropTop:              alloc=0 retain=0 release=1
viaClosure$dropLocal: alloc=0 retain=0 release=1
```

The harness asserts the *equality* and the *absolute* counts, so it cannot pass by comparing two
unelided programs. This is escalation 0008 §3's baseline: the numbers that will move when a closure
becomes a value and `argOwnership` stops being derivable.

**4. Naming: `enclosing$local`.** `twiceSum$dbl`, not `dbl`. `linkName` is emitted verbatim (spec
§9) with no mangling downstream, and `addThree` and `clampTo` both declare a local named `f`, so an
unqualified hoist would let one definition silently win. The qualifier is the **emitted** name of the
enclosing body, not its Dart name, so a local inside `Box.doubled` becomes `Box_doubled$g` and
cannot collide with one inside a top-level `doubled`; a local inside a specialization becomes
`pick$u64$f`. `$` is legal in a Dart identifier (ADR-0052's comment claiming otherwise is wrong), so
uniqueness rests on a claimed-name set seeded with every top-level procedure, which appends `$2`,
`$3`, … deterministically in lowering order rather than on an assumption about identifiers.

Hoisted bodies are drained from a queue in the **same loop** as ADR-0052's specializations, not a
second loop after it: a specialization's body may declare a local function and a local function's
body may call a generic, so two sequential loops would silently drop whatever the first kind
discovered last.

### What "non-capturing" means precisely, and what is rejected

A scan of the function's own body — deliberately **not** descending into nested functions, since each
is scanned in its own right when it is hoisted, and descending would report an inner function's
capture against the outer function's name — separates two kinds of free reference:

- **Value position** (`VariableGet`/`VariableSet`, or `this`): a free one is a real capture.
  **Rejected**, pointing at escalation 0002 and 0008.
- **Call position** (`LocalFunctionInvocation`, or `FunctionInvocation` on a plain `VariableGet`): a
  free one is **not** a capture when it names another hoisted local function, because the name
  resolves to a static symbol rather than to a value in a frame.

That second rule is what makes **self-recursion** (`factorial`'s `go`) and **sibling calls**
(`pipeline`'s `incTwice` calling `inc`) work with no environment. Self-recursion needs the name
registered *before* the scan runs, which is why the implementation reserves and registers first.

Everything else is rejected with a diagnostic that names which of the two open questions it hits:

| shape | diagnostic points at |
|---|---|
| reads an enclosing local, or `this` | escalation 0002 / 0008 — needs an environment, needs a heap |
| a local function used as a value (`final h = g;`) | GAP-0052 — no function-pointer type |
| a function type in any signature | GAP-0052, at the declaration rather than at a use site |
| a function expression anywhere but a local's initializer | GAP-0052 |
| a local function called as a bare statement | not implemented; bind the result |
| generic, named/optional params, `async`/`sync*` | plainly out of scope, said plainly |

The rejections are the load-bearing half of this ADR. Everything refused above is refused because
implementing it would decide something an implementation unit does not get to decide — not because
it is hard.

## Consequences

- **`ROADMAP.md`'s closure-heavy functional workload is still not writable.** A closure that cannot
  be passed to a function is not much of a closure. GAP-0035's closure row narrows; it does not
  close.
- **Hoisted symbols are externally visible and appear in `--emit-header` output**, with `$` in the
  identifier. That is pre-existing behaviour for compiler-synthesized symbols — ADR-0022's
  destructors (`BoxHolder_dtor`) and ADR-0052's specializations (`pick$u64`) already do it, and the
  `generics` harness already compiles such a header. It is now filed as **GAP-0053** rather than
  inherited silently, because this ADR adds a whole new population of internal symbols to the public
  ABI surface and DC-IR has no concept of internal linkage to fix it with.
- **A capture that is a compile error today may become legal later.** Nothing here forecloses any of
  escalation 0008's options; option 4 (stack environments for non-escaping closures) is a strict
  superset of what this does, and would replace the rejection with a lowering, not rewrite the
  hoisting.

### Superseded in part by ADR-0060 (2026-08-26)

Two of this ADR's rejections are gone, and one of its predictions was wrong.

- **"A local function used as a value" and "a function type in any signature" are no longer
  errors.** ADR-0060 added `DCFuncPtr`, `FuncRef` and `IndirectCall`, closing GAP-0052. The hoisting
  above is unchanged and is what a torn-off local function points AT — the two compose exactly as
  this ADR's last consequence predicted a superset would.
- **The capture rejection is unchanged**, and so is escalation 0008 §2. What changed in the capture
  scan is narrow: a sibling or own local function's name in **value** position is no longer counted
  as a capture, for exactly the reason it was already not one in **call** position — the name
  resolves to a static symbol, not to a slot in the enclosing frame.
- **Consequence 3's forecast did not hold.** It reads: "the numbers that will move when a closure
  becomes a value and `argOwnership` stops being derivable." They did not move; the four lines above
  are byte-identical after ADR-0060, and the indirect spelling of the same program joins them at
  `alloc=1 retain=0 release=0`. `argOwnership` did not stop being derivable — it stopped needing to
  be derived at the call site, because ADR-0060 carries it in the pointer's type from the tear-off,
  where the declaration is still in hand.

## Rejected alternative

**Lower capturing closures onto ADR-0015's arena now.** Fastest to a green test, and wrong: it
promotes a temporary that ADR-0015 explicitly labels non-authoritative into permanent
infrastructure, contradicts `CLAUDE.md`'s "no hidden global heap" for `@bare`, and answers
escalation 0002 and the capture convention by accident rather than by decision. Escalation 0008
option 2, recommended against there for the same reasons.

## Verification

- `tests/conformance/closure/run.sh`: **PASS**. Seven shapes (named local function with two call
  sites, function expression, block body with a branch inside, self-recursion, sibling call, and
  both ARC directions), symbol-table assertions that the hoist happened and is qualified, the
  `dc-objdump --arc` equality above, and 2000 leak-free heap cycles across the two ARC pairs — well
  past the arena's 64-slot capacity, so one leaked slot per call could not survive.
- `scripts/verify-freestanding.sh`: **FREESTANDING: pass** on `bare-x86_64`, `macos-arm64`,
  `linux-x86_64`, `windows-x86_64` and `host`.
- Full suite: **36 passed, 0 failed, 0 skipped** on Darwin/arm64 (was 35 before this target).
- `dart analyze core/dcc-lower/lib/lower.dart`: the same four pre-existing warnings as before the
  change, no new ones.
