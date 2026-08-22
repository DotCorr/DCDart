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

## GAP-0032 — `dcc` never passes an optimization flag, so every DCDart program ships `-O0` code

**Domain:** backend / dcc
**Status:** RESOLVED (2026-08-21) — `dcc` compiles at `-O2` (ADR-0042). Landed only after ADR-0041
made `Pointer<T>` access volatile; doing it in the other order would have silently deleted MMIO
accesses while every test went green. M3's measurement is now meaningful, and should be read with
GAP-0034 in mind.

`backend/lib/compile.dart` invokes `clang` with `-ffreestanding -fno-builtin -fno-stack-protector
-fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -c`. There is no `-O` anywhere, so
LLVM runs at `-O0`: no register allocation to speak of, no constant folding, no strength reduction, no
CSE, no unrolling.

Measured on a non-allocating loop (`sum ^= *(u32*)(base + i*4)` over `count` elements), all three
compiled for `x86_64-unknown-none-elf`:

| build | instructions | shape |
|---|---|---|
| DCDart as `dcc` ships it | 54 | every local spilled to stack; `mulq` for `i*4`; constant 0 materialized as `xor`+`add` |
| **the same DCDart IR at `-O2`** | **21** | values in registers; `xorl (%r9), %eax` direct memory operand; tight 8-instruction loop |
| C at `-O2` | 36 | longer only because it unrolled 4x |

**Why this entry matters more than its size, stated as sharply as it deserves.** M3 is the project's
hard gate — geometric mean ARC overhead ≤10% vs C — and `ROADMAP.md` says nothing downstream starts
until it is green. A benchmark run today would attribute the ENTIRE `-O0` penalty to ARC. It would not
merely produce a pessimistic number: it would **fail the gate**, and failing it triggers exactly the
response the roadmap prescribes — *"fix the optimizer, or accept and document a higher number, or
revisit the model."* The third option means changing the memory model. **The project would consider
revisiting ARC to fix a missing compiler flag.**

That is why this is a prerequisite rather than an optimization: it is not that the number would be
wrong, it is that a wrong number here has a standing procedure attached to it that damages the
language.

Visible in shipped kernel code, not only in synthetic loops — `oscortex_core`'s `uartPutc`, verified
by the kernel side from a real build:

```
b85: movb %al, 0x1(%rsp)      <- store to a stack slot
b89: movb 0x1(%rsp), %al      <- reload it immediately; a no-op pair
b8d: xorl %ecx, %ecx
b8f: addb $0x20, %cl          <- the constant 0x20, built in two instructions
b94: xorl %ecx, %ecx
b96: addb $0x1, %cl
b99: cmpb %cl, %al            <- instead of `cmpb $1, %al`
```

plus `xorl %eax,%eax; movw %ax,%dx; addw $0x3fd,%dx` to materialize a port number that is one `movw`.
None of that is an ARC artefact or a memory-model cost.

It also corrects a wrong conclusion that is easy to reach from reading the output: DCDart's emitted
code looks nothing like C's, so it is tempting to infer that ARC or some runtime is responsible. It is
not — the same IR through `-O2` is the same class of code as C. Verified separately: non-allocating
programs emit **zero** ARC instructions (`m2-port`, `m1-pointer`, `m2-bitwise`, `demo-stats`,
`m2-rodata` all report `alloc=0 retain=0 release=0`), and a `@bare` object has zero undefined symbols,
so there is no runtime to call into.

**Cost of the workaround:** nothing depends on `-O0`, so it is not load-bearing anywhere. But it is not
a one-line change, and the reasons are the interesting part:

- It makes the red zone genuinely reachable for the first time. ADR-0039 already handles it, and
  `tests/conformance/no-red-zone/`'s codegen half converts from a forward guard into a LIVE check —
  that harness has never actually been exercised, because `-O0` does not use the red zone anyway.
- It is the change most likely to expose latent UB in emitted IR that `-O0` hides, and by GAP-0027 the
  conformance suite structurally cannot see the bare-metal-only classes of that.

So the acceptance criterion should include `oscortex_core`, which is DCDart's only real `@bare` test
(GAP-0027). Its three harnesses assert byte-exact serial output from real hardware behaviour — 256 IDT
gates, PIT ticks with EOI, a real `#UD` survived. If the captures still match byte-for-byte at `-O2`,
that is strong evidence. If they do not, `-O0` was hiding something real, which is worth more than a
clean run. The kernel side has offered to run exactly that.

---

## GAP-0038 — Nullable heap references have no null SAFETY; a null dereference faults at runtime

**Domain:** dcc-lower (M2)
**Status:** OPEN — and it sits against `CLAUDE.md` rule 3 rather than merely being unimplemented

ADR-0049 made `null` expressible and made `Retain`/`Release` null-safe, so a null reference can be
stored, compared and passed around. It did **not** make dereferencing one safe: `cur.value` where
`cur` is null reads the object at address 0 and faults.

Dart's type system already carries the distinction — `Node` and `Node?` are different types, and
front_end enforces it before dcc-lower ever runs. **DCDart currently discards that information.**
`_lowerType` maps both to the same `DCHeapPointer`, so a program that would not compile as Dart is
accepted, and a program that Dart proved safe gets no benefit from the proof.

That matters more here than it would elsewhere. `CLAUDE.md` rule 3 says sound null safety is "our main
advantage over C and C++" and forbids `!` and `late` to preserve it. Accepting a null dereference is
the compiler failing to uphold the rule its own source is held to.

**Cost of the workaround:** the programmer checks `!= null` before every dereference, and nothing
verifies they did. The fix is to carry nullability on `DCHeapPointer` and reject a dereference of a
nullable value that has not been narrowed — which needs flow-sensitive narrowing (`if (x != null) {
x.f }` must know `x` is non-null inside the branch). Kernel already records the static type at each
node, so the information is available; nothing reads it yet.

---

## GAP-0037 — Every "not supported yet" refusal in `dcc-lower` deserves re-examination; at least one was already safe

**Domain:** dcc-lower (process, not a single defect)
**Status:** OPEN — one instance found and fixed (ADR-0044), the rest unaudited

ADR-0028 refused to lower nested `while` loops, with a comment explaining that recursing would
"silently scope the carried-variable analysis to the wrong loop". It read as considered, and it was
wrong: `_lowerWhile` already filtered candidates to variables present in `_values`, which is exactly
the scoping guarantee the comment wanted. Enabling nesting was one line, and every hard case —
an inner loop assigning an outer variable, triple nesting, an early return out of both — worked
immediately.

It sat for eleven ADRs and was found by `oscortex_core` hitting it twice in one milestone, not by
this repo.

**The generalizable part.** A crash gets investigated. A deliberate, well-commented refusal naming a
plausible hazard reads as a decision someone already made, and is therefore *less* likely to be
re-examined — the comment does the work of discouraging the next person. That is an unusual failure
mode: the better the comment, the longer the wrong refusal survives.

`dcc-lower` contains several more of these — `break`/`continue`, heap locals in loop bodies,
getters/setters on `HeapObject` (ADR-0043), heap-typed field stores (escalation 0006). Some are
genuinely unresolved design questions; at least one was not. They have never been audited as a group.

**How to run the audit, which is not the obvious way.** The `oscortex_core` side sharpened the
question and the improvement is real: ask **"what would have to be true for this refusal to be
correct, and is it?"** — NOT "is the stated hazard still real?". The second invites re-reading the
comment, which is the thing that misled everyone. The first forces reconstructing the argument from
the code, which is where the answer actually was.

**Fourth instance, and the sharpest (2026-08-21).** `_collectLoopCarriedCandidates` fell off its end
SILENTLY for unrecognized statements. `continue` wraps a loop body in a `LabeledStatement`, which it
did not know, so it collected nothing, the loop header got no phi parameters, and the emitted code
branched to itself — a hang with no diagnostic (ADR-0047). This is the worst version of the pattern
because the consequence of a missed shape is *wrong code* rather than a refusal: nothing downstream is
malformed, so nothing downstream can report it. The walker is now exhaustive and throws on anything
unlisted.

**Third instance, and it makes this a class (2026-08-21).** `u64(first - 1)` was rejected with "the
argument must be an integer literal or a compile-time integer constant" while being exactly that
(ADR-0046). The common thread across all three is now clear and is more useful than the individual
fixes: **each refusal was written as a SHAPE check — matching AST node types — while its message
described a SEMANTIC rule.** A shape check documented in semantic language drifts from its own
documentation the moment a new shape expresses the same meaning. Note ADR-0037 had already widened
this same check once, by adding a shape rather than by evaluating; widening a pattern-match is what
invited the identical bug a second time.

**First audit run, `break`/`continue` (2026-08-21).** Applying that question produced a better result
than a yes/no:

- `continue` is a branch to the loop header with the current loop-variable values, which is
  *byte-identical to the back edge `_lowerWhile` already emits*. Genuinely free.
- `break` is a branch to `exitBlockId` — and the finding is not "break is missing". It is that
  **`exitBlockId` carries an unstated single-predecessor assumption.** It is created with NO block
  parameters, and the exit restores values from the header's phi params. That is correct *only
  because* the exit is reachable through exactly one edge (the header's false branch). Add a `break`
  and a body that assigns a loop variable then breaks would read the pre-body value at the exit.

That precondition was nowhere in the code or the comments. So the refusal was right, for a reason
nobody had written down and which the stated reason did not mention.

**The invariant that audit exposed, recorded here because it is upheld everywhere and stated
nowhere:** *a DC-IR block needs parameters if and only if it has more than one predecessor.* Checked
against every block-creation site in `dcc-lower`:

| block | params? | predecessors |
|---|---|---|
| `thenBlockId`, `elseBlockId` | no | 1 (a `CondBranch` edge) |
| `bodyBlockId` | no | 1 (the header's true edge) |
| `errBlockId`, `okBlockId` (`Result.propagate`) | no | 1 each |
| `exitBlockId` | no | 1 today — **2+ the moment `break` exists** |
| `mergeBlockId` (if/else) | **yes** | 2 |
| `condBlockId` (loop header) | **yes** | 2 (entry + back edge) |

The rule holds in all six existing cases. `break` is the first thing that would break it, and it
would do so silently — the emitted IR is still well-formed, the values are just wrong.

**Cost of the workaround:** each refusal is individually honest, so nothing is hidden. The cost is
that downstream consumers discover which ones were merely untested, mid-way through building
something else. The remaining unaudited refusals: heap locals in loop bodies (ARC policy — genuinely
unresolved, belongs with escalation 0006), getters/setters on `HeapObject` (ADR-0043 — untested, not
unresolved), and heap-typed field stores (escalation 0006).

---

## GAP-0036 — Port I/O is optimization-safe by ACCIDENT, not by design (now tested)

**Domain:** dc-ir, backend (M2, downstream: `oscortex_core`)
**Status:** RESOLVED as a test gap (2026-08-21); the underlying accident remains

ADR-0041 made `Pointer<T>` load/store volatile. It does not apply to `Port.outb`/`Port.inb` at all —
those are `PortOut`/`PortIn`, a separate code path that lowers to LLVM `asm sideeffect` (ADR-0029).

So port I/O survives `-O2` because of a decision made months earlier, for an unrelated reason, by
someone not thinking about optimization. That is a real property with a real consequence:
`oscortex_core`'s UART output polls the 16550 Line Status Register in a loop through `Port.inb`, and if
that read were hoisted out of the loop the poll would spin forever on a stale value. **No wrong bytes,
no crash, no diagnostic — the machine just stops.** Raised by the kernel side, who own the code that
would hang.

Until now, `tests/conformance/volatile/` asserted nothing about `PortIn`/`PortOut` at any optimization
level. The property was load-bearing and untested.

**Resolution (test side).** `examples/m2-port-poll/` plus step 4 of `tests/conformance/volatile/`:
the emitted IR must contain `sideeffect`; a port read in a polling loop must remain loop-resident at
-O0/-O1/-O2/-O3/-Os, verified by locating the read's address and requiring a backward branch to target
at or before it; and three writes to the same port with different values must all survive, since each
is a distinct side effect the hardware observes in order.

**What is NOT resolved:** the safety is still incidental. Nothing in the design says "port I/O must be
`sideeffect`" — an ADR says it, and a test now pins it, but the two are connected only by this gap
entry. A future rework of port lowering that drops `sideeffect` would fail the test, which is the
point, but the *reason* it matters lives in prose rather than in the type system.

Honest limit of the test, recorded in the harness too: the IR-level assertion is the discriminator.
Stripping `sideeffect` from the emitted IR fails it. The codegen half did NOT trip on that same
stripped IR, because LLVM happened not to exploit the freedom — the read's result is used, so it was
kept anyway. The codegen check is a backstop against an optimizer that does exploit it, not a test of
the IR check.

---

## GAP-0035 — M3's benchmark suite cannot be WRITTEN in DCDart; the gate is unblocked but not reachable

**Domain:** language surface (M3)
**Status:** OPEN — and it is the honest statement of where the project actually is

ADR-0041 (volatile) and ADR-0042 (`-O2`) removed the two things that would have made an M3 measurement
*wrong*. They did not make it *possible*. `ROADMAP.md` names the suite:

> at minimum a JSON parser, a hashmap-heavy workload, a tree/graph traversal, a string-processing
> pass, and a closure-heavy functional workload

None of the five can be written today. Probed each prerequisite against the real compiler rather than
inferring from the gaps file:

| prerequisite | status | blocks |
|---|---|---|
| `null` / nullable heap refs | `unsupported expression NullLiteral` | trees, lists, anything optional |
| heap-typed field **store** | rejected (GAP-0020) | every mutable data structure |
| generics / monomorphization | `unsupported type TypeParameterType` (spec §4.2) | any container |
| closures | `unsupported expression FunctionExpression` | the functional workload |
| `String` | `unsupported expression StringLiteral` (spec §7) | JSON parser, string pass |
| instance methods | **RESOLVED 2026-08-21 (ADR-0043)** | — |
| `for` loops | `unsupported statement ForStatement` | cosmetic — `while` works |

Only `bool` locals passed. Instance methods have since been implemented (ADR-0043); the other six
remain.

**So M3 is not one unit away. It is most of the remaining language.** That is worth stating plainly
because "the gate is unblocked" reads as "the gate is next", and it is not — the benchmarks are
downstream of features nobody has built.

**The ordering point that matters most.** `CLAUDE.md` rule 4 freezes the memory model *after* M3. The
heap-typed-field-store ownership policy (GAP-0020: does a store release the old value? retain the new
one? take over an existing reference?) is precisely a memory-model decision — and it is a prerequisite
of the tree/graph benchmark, which is a prerequisite of M3, which is what freezes it. **It must
therefore be decided BEFORE M3, deliberately, rather than inherited from whatever the first
implementation happened to do.** Deciding it under benchmark pressure is the worst possible timing.

**Cheapest path to a REAL M3 number, if a partial gate is acceptable:** nullable heap references plus
heap-typed field stores are one coherent unit — both are the same "a field holds a heap reference"
question — and together they unlock the tree/graph traversal benchmark, which is the most
ARC-intensive of the five and therefore the most informative single number. That would give a measured
overhead on genuinely allocation-heavy code without strings, generics or closures. It would not be
`ROADMAP.md`'s stated suite and should not be reported as passing M3.

**Cost of the workaround:** there is no workaround. Any M3 number quoted today would be measured on
arithmetic loops and pointer walks, which allocate nothing, exercise no ARC, and would report an
overhead near zero — a meaningless pass.

---

## GAP-0034 — Every `Pointer<T>` access is volatile, including bulk memory walks that do not need it

**Domain:** runtime prelude, dcc-lower (M2/M3)
**Status:** OPEN — correctness-safe, performance cost

ADR-0041 makes `Pointer<T>.value` volatile because it is DCDart's MMIO mechanism. But it is also the
only way to read ordinary memory through a pointer, so `examples/demo-stats/` — walking a plain `u32`
array a C caller owns — now emits volatile loads it does not need. Volatile blocks vectorization, CSE
and hoisting, so a bulk walk loses the optimizations it would most benefit from.

Correctness is unaffected in both directions: volatile is strictly more conservative.

**Where the cost actually lands, which decides the fix.** It is not evenly spread, and this is worth
settling before M3 numbers arrive and the pressure is to fix it quickly:

- **`@bare` kernel code pays nothing.** Every `Pointer<T>` access `oscortex_core` makes genuinely IS
  MMIO — UART, PIC, PIT, IDT, VGA at 0xB8000, PS/2 at 0x60. Blanket volatile costs it nothing because
  it wanted volatile everywhere anyway.
- **Hosted bulk traversal pays all of it**, and that is precisely the benchmark shape: walking an array
  of scalars, which is what a JSON parser, a hashmap probe and a tree walk all reduce to.

So the fix is probably NOT "make volatile opt-in" — that reintroduces the unsafe default ADR-0041
rejected for good reason, and the failure mode is invisible. The better direction is **distinguishing
device memory from ordinary memory at the TYPE level**: a `Pointer<T>` for ordinary memory and a
distinct type (or a `@device` annotation on the pointer) for MMIO, with volatile following the type
rather than the operation. The kernel side has said it would happily annotate, because it already
knows exactly which of its pointers are device memory — the information exists in the programmer's head
and simply has nowhere to be written down today.

That also composes with GAP-0033 (no barriers): whatever type says "this is a device register" is the
natural place to hang ordering requirements later.

**Cost of the workaround:** measurable only under `-O` (which now exists, ADR-0042) and only on hosted
traversal. If M3 comes in over budget, check this before concluding anything about ARC.

---

## GAP-0033 — `volatile` prevents elision and reordering, but there are no memory BARRIERS

**Domain:** dc-ir, backend (M2, downstream: `oscortex_core`)
**Status:** OPEN

ADR-0041 emits LLVM `volatile`, which stops the optimizer deleting, duplicating or reordering an
access relative to other volatile accesses. That is what MMIO correctness needs on a single core.

It is NOT a memory-ordering model. `volatile` is not atomic, not a fence, and says nothing about
multi-core visibility or about ordering relative to non-volatile accesses. `DCDART_SPEC.md` §6 asks
for "explicit ordering", which means real barriers — `mfence`/`dmb`, acquire/release, or LLVM's
`fence` instruction. None exist.

**Cost of the workaround:** invisible today, because `oscortex_core` is single-core with interrupts as
the only concurrency, and interrupt entry/exit is a serializing event. It becomes real at the first SMP
bring-up or the first lock-free structure shared with a device, and at that point it is the kind of bug
that reproduces once a week and never under a debugger.

---

## GAP-0031 — `@rodata` emitted homogeneous ARRAYS only, so a type descriptor's STRUCT was inexpressible

**Domain:** dc-ir, backend, dcc-lower (M2)
**Status:** RESOLVED (2026-08-20) — `DCConstStruct`, a const class instance as the source form

ADR-0040 emits `[N x iW]` arrays and, via `Ref('name')`, `[N x ptr]` relocation arrays. An LLVM array
is **homogeneous**, so a mixed aggregate is not expressible. The shape a real type descriptor wants is
exactly a mixed one:

```
{ ptr name, i64 fieldCount, ptr fields }
```

That is a struct constant, and `DCConstant` has no struct node. Found by the emitter's own homogeneity
check rejecting a test that modelled a descriptor as an array — the check was right and the test was
wrong, which is the good direction for that to happen in.

So the current state is: a table of scalars works, a table of pointers works, and a **record** mixing
the two does not. Reflection descriptors need the third. This is the remaining gap between "static
data exists" and "descriptors can be built", and it is smaller than it looks — a `DCConstStruct`
node plus the `{...}` emission, with the same name-based relocation leaf already in place.

Note the interaction with GAP-0022: the C header emitter already orders structs by first appearance,
which is not guaranteed to be valid C definition order once structs can nest.

**Resolution.** `DCConstStruct` plus a const class instance as the source form:

```dart
class TypeDesc {
  final Ref name;
  final u32 fieldCount;
  final Ref fields;
  const TypeDesc(this.name, this.fieldCount, this.fields);
}

@rodata final TypeDesc pointDesc =
    const TypeDesc(Ref('nameBytes'), u32(2), Ref('fieldOffsets'));
```

Emits `{ ptr, i32, ptr } { ptr @nameBytes, i32 2, ptr @fieldOffsets }` — 24 bytes with natural C
layout (ptr, u32, 4 bytes padding, ptr) and two real relocations. Verified by dereferencing it: the
name pointer reaches its bytes, the fields pointer reaches its offsets.

Field WIDTHS come from the class's declared field types, not from the values — an `InstanceConstant`'s
field values are bare `IntConstant`s with every extension type erased, exactly as list elements are.
Field ORDER follows the class's declaration order rather than the constant's map order, because that
order IS the emitted layout. A bare `int` field is rejected for the same reason `List<int>` is.

Two things that were nearly wrong: the emitted text must be TYPE then VALUE (`{ ptr, i32 } { ... }`) —
omitting the leading type produces LLVM's unhelpful "expected '}' at end of struct" because it parses
the value as a type; and the struct is unpacked, so LLVM applies natural field alignment matching what
C would do for the same fields. A `@packed` equivalent would need `<{ }>` and has no source form yet.

**Cost of the workaround (historical):** parallel arrays, one per field, indexed in lockstep. They
express the same information at the cost of an index-correctness invariant nothing checks — precisely
what the struct now enforces.

---

## GAP-0030 — A `Store` into read-only static data is not prevented, and on the freestanding target it corrupts silently

**Domain:** dc-ir, backend (M2)
**Status:** OPEN

`DCPointer` carries no const-ness, `Store` accepts any `DCPointer`, and DC-IR has no verifier pass at
all. So nothing stops code from deriving a pointer via `Rodata.addressOf` (ADR-0040) and storing
through it.

**This is not a fault today, it is silent corruption.** `oscortex_core` maps a single RWE `PT_LOAD`
with 2 MiB pages and no per-section permissions, so a write into `.rodata` succeeds and nothing
anywhere notices. Confirmed from the kernel's own program headers, not assumed. On a system whose
premise is self-knowledge, and whose type descriptors will live in `.rodata`, the failure mode is a
corrupted descriptor — a program confidently reporting a false answer about itself — rather than a
crash. That is categorically worse than a fault and justifies more urgency than "unimplemented
checking" normally would.

**Cost of the workaround:** none available at the language level; the discipline is entirely on the
programmer. Two independent fixes, both real, neither in this unit: W^X page permissions on the kernel
side (theirs, and it must NOT be attempted as a link-script-only change — separate segments without
page-table enforcement look like protection while providing none), and const-ness on `DCPointer` plus
a DC-IR verifier on this side. The second is the general fix and is the first real argument for a
verifier pass, which DC-IR has never had.

---

## GAP-0051 — `Pointer<T>.elementAt(n)` does not exist, so every indexed read restates the element width by hand

**Domain:** runtime prelude, dcc-lower (M1/M2)
**Status:** OPEN — specified in `DCDART_SPEC.md` §6's required primitives, never built

Reading an element of a static table or any pointer-addressed array is written:

```dart
Pointer<u64>.fromAddress(Rodata.addressOf(memmap) + i * u64(8))
```

That `u64(8)` is the element width, already declared one line up in `List<u64>`, restated as a literal
at every call site with nothing checking the two agree. Change the declaration to `List<u32>` and
every call site silently computes wrong addresses — plausible garbage, not an error.

This is precisely the class of bug `c_header.dart` (ADR-0034) exists to eliminate for extern
prototypes: a hand-written restatement of something the compiler already knows, free to drift from its
source of truth, with no diagnostic.

`Pointer<T>.elementAt(n)` derives the stride from `T` in one place and fixes **every** pointer user,
not only `@rodata` ones — `oscortex_core`'s `multiboot.dart` and `interrupts.dart` both hand-compute
strides today for the same reason. Raised by the kernel side, who own the motivating code.

**Cost of the workaround:** the stride literal works and is what ADR-0040's examples use. It is a
stopgap, named as one here and in the ADR so whoever first changes an element type has a chance of
finding this.

---

## GAP-0029 — The extern manifest is trusted input; reserved runtime families are now unhonorable, but everything else is taken on faith

**Domain:** testing / build integrity (spine, `CLAUDE.md` rule 1)
**Status:** OPEN — the worst case is FIXED (`tests/conformance/spine-reserved/`), the trust model is not

ADR-0038 taught `scripts/verify-freestanding.sh` to permit symbols listed in `<objfile>.externs`. The
script reads that file from disk and permits exactly the names in it. Nothing verifies that the
manifest is the one `dcc` wrote, that it matches the source's `@extern` declarations, or that it is
not stale from an earlier build.

**The part that was actually dangerous, and is fixed.** The manifest could honor ANY name, including
`dc_alloc`, `dc_throw`, `dc_orc_*` and `Dart_*` — the four families whose own diagnostics say their
presence means *the compiler emitted them* ("This is a backend bug. Escalate to E2 immediately."). A
manifest listing `dc_alloc` produced `FREESTANDING: pass`. That contradicted both the script's own
header ("still a hard failure, always") and escalation 0003's ratified wording ("keeps catching
`dc_alloc`, `dc_throw`, `dc_orc_*` and `Dart_*` exactly as before"). Verified by hand, then fixed:
those families are now checked BEFORE the allowlist and the manifest, so neither can honor them, and
the diagnostic says so explicitly. Deliberately not configurable — a safety property with an escape
hatch is one that will be escaped.

The distinction that justifies the asymmetry: every other undefined symbol is a claim about SOMEONE
ELSE'S object file, which an author is entitled to make. The reserved families are claims about our
own runtime, which an author is not.

**What remains open.** For non-reserved names the manifest is still trusted input:

- A hand-written or hand-edited manifest permits whatever it lists. There is no signature, no
  checksum, and no cross-check against the source.
- A stale manifest from an earlier build lingers next to the object. The script reports unmatched
  entries as a note rather than a failure — correct, since an unmatched entry permits nothing — but a
  manifest that is stale in the *other* direction (still listing a symbol the source no longer
  declares, while the object still references it for a different reason) would be honored.
- Nothing checks that `<objfile>.externs` was produced by the same `dcc` invocation as `<objfile>`.

**Cost of the workaround:** low today, because the manifest is written by `dcc` immediately beside the
object it describes and nobody hand-edits one. It grows if manifests ever get committed, shipped, or
merged across repos — `oscortex_core` has already ported the manifest support, so the mechanism now
runs in two repos. The honest fix is for `dcc` to embed the declared set IN the object (a custom
section, or a symbol naming convention) so the manifest cannot be separated from what it describes.
That was considered out of scope for ADR-0038 and remains so, but it is the direction.

---

## GAP-0028 — `dcc` compiles ONE library per object file; `@bare` functions in imported libraries were silently dropped

**Domain:** dcc-lower (all milestones)
**Status:** OPEN — the silence is fixed, the limitation is not

`lowerToDCModule` lowers `targetLibrary.procedures` and nothing else, so a `@bare` function declared
in an imported library is never compiled into the object. Reported by `oscortex_core`, which hit it
splitting its kernel across files and worked around it with `part`/`part of`.

The limitation is defensible for now — one source file, one object file is a normal compiler
boundary. **The silence was not.** Before this fix there were two failure modes and both were bad:

- If nothing called the dropped function, the build SUCCEEDED. The symbol was simply absent from the
  object, and absent from `--emit-header`'s output too, so the C side found out at link time or not
  at all.
- If something did call it, `clang` failed with `use of undefined value '@helperDouble'` — an
  LLVM-level message that names neither DCDart, nor the import, nor what to do.

`dcc` now refuses to build, listing every dropped function with its library and naming the
`part`/`part of` workaround. This converts a trap into a diagnostic; it does not make multi-library
programs work.

**Cost of the workaround:** `part`/`part of` forces every `@bare` function of a program into one
library. That is a real ergonomic tax on any program large enough to want files — a kernel, for
instance — and `part` is a Dart feature with its own baggage (no per-file imports; the part file
cannot be analyzed alone). The real fix is compiling a library graph into one module, or emitting one
object per library and letting the linker resolve across them; the second interacts directly with
ADR-0038's extern manifest, since a cross-object DCDart call would look exactly like an undeclared
external symbol to `verify-freestanding.sh`.

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

## GAP-0027 — The conformance suite structurally cannot catch bare-metal-only codegen defects

**Domain:** testing (all milestones)
**Status:** OPEN — partially mitigated by `tests/conformance/no-red-zone/`

Every behavioural conformance harness links its `@bare` object into an **ordinary hosted process** and
runs it there (a hand-written `_start.S` plus the Linux/x86-64 syscall ABI, or plain libc for
`native-host`). That is a sound way to check what the code COMPUTES. It is no evidence at all about
properties that only differ in the environment `@bare` actually targets.

Made concrete by ADR-0039: `dcc` emitted red-zone-using code for freestanding targets, which is
correct in userland and silent memory corruption in a kernel once interrupts are enabled. The suite
was 21/21 green throughout, and could not have been otherwise — in a hosted process nothing ever
writes below RSP, so the defect has no observable behaviour there. It was found by a downstream OS
project disassembling its own kernel, not by this repo.

Other properties in the same blind spot, none currently checked: stack alignment at entry (ADR-0039's
closing note — the backend assumes SysV 16-byte alignment and documents it nowhere), `@interrupt`
calling convention once that exists, MMIO ordering and `@volatile` (GAP-0006), and anything about
behaviour with interrupts enabled at all.

Stated at its sharpest, in the words of the `oscortex_core` side that found the bug: **the kernel is
currently DCDart's only real `@bare` test, and that is a dependency in the wrong direction.** A
language project whose freestanding guarantees can only be validated by a downstream consumer has
outsourced its own acceptance criteria.

**2026-08-20: this is now three for three, and it is a property rather than a pattern.** Every
bare-metal-only defect found so far was found OUTSIDE this suite, and in each case the suite
structurally could not have found it:

| defect | how the suite missed it |
|---|---|
| red zone (ADR-0039) | `@bare` objects run inside hosted processes, where the red zone is legitimate |
| reserved symbols honorable by manifest (GAP-0029) | no test ever asked the checker to reject something |
| **`volatile` / MMIO elimination (GAP-0006)** | `m1-pointer` asserts the returned VALUE, which stays correct after the load is deleted |

**And "run the kernel harnesses as acceptance" is a stopgap, not the fix.** That is the obvious
response and it is not sufficient, proven today: `oscortex_core`'s byte-exact captures (433 and 544
bytes, the strongest evidence in either repo) would very likely **still have matched** with MMIO
read-backs eliminated, because the printed VALUES stay correct — it is the ACCESSES that disappear.
The kernel side offered those harnesses as the `-O` acceptance criterion in good faith and has since
confirmed they would have passed a compiler that had stopped talking to hardware.

So closing this gap requires a `dc-test --qemu` inside DCDart with targets that **observe the access
itself, not its result**: a QEMU device trace, a port-I/O count, an MMIO watchpoint — something that
fails when a read does not happen even though the value is right. Every harness in both repos today
checks what a program computed or printed. Nothing anywhere checks that the hardware was touched. That
is the actual hole, and it is wider than any single defect that has walked through it.

**Cost of the workaround:** a whole class of defect is invisible until a downstream consumer hits it,
which is the most expensive place to find it. `no-red-zone/` mitigates exactly one instance by
inspecting instructions instead of results — that shape (assert a property of the emitted code, not of
its output) is the general answer, and is worth reusing for the others. The real fix is the one
`DCDART_SPEC.md`'s own testing model already names and this repo has never had: `dc-test --qemu`,
booting `@bare` objects under full-system emulation with interrupts live and asserting over serial.
Until that exists, "the suite is green" and "this code is safe in a kernel" remain different claims.

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
  **Whoever builds it also owes escalation 0003's second condition, which ADR-0038 specified but
  could not enforce because `@interrupt` does not exist:**

  > A call to an `@extern` symbol, direct **or transitive** through another `@bare` function, is a
  > compile-time error inside a function annotated `@interrupt`.

  The hazard is reaching foreign code at all — unbounded stack depth, unknown blocking, unknown
  reentrancy, none of which the compiler can see through a `declare` — not the syntactic position of
  the call site, so enforcing it needs a call-graph walk over the module's `Call` instructions, not a
  local check. A check keyed off an annotation nothing can write today would be dead code that looks
  like a guarantee, which is why ADR-0038 wrote the rule down here instead of pretending to enforce
  it. `oscortex_core` records its own M1 interrupt handlers as correct-by-inspection for exactly this
  reason.
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

## GAP-0006 — `Pointer<T>` load/store carry no `@volatile` guarantee

**Domain:** dc-ir, backend (M1)
**Status:** RESOLVED (2026-08-20) for elision/reordering — `Pointer<T>` load/store are now volatile
(ADR-0041, `tests/conformance/volatile/`). Memory ORDERING (barriers, spec §6's "explicit ordering")
remains unimplemented and is tracked separately as GAP-0033.

**2026-08-20 — measured, and it is worse than "unimplemented".** `examples/m1-pointer/mmio.dart` is the
M1 exit criterion: write a memory-mapped register, read it back. Its emitted IR, compiled for
`x86_64-unknown-none-elf`:

```
-O0 (what dcc ships today)      -O2 (the same IR)
  movl %esi, (%rdi)   store       movl %esi, %eax     <- returns what it wrote
  movl (%rdi), %eax   load        movl %esi, (%rdi)
  retq                            retq                <- THE LOAD IS GONE
```

At `-O2` LLVM legally eliminates the read-back, because the load is not marked `volatile`. For a real
hardware register the read-back IS the operation — status bits change, write-only bits read
differently, devices acknowledge on read. And **`tests/conformance/m1-pointer/run.sh` still passes**,
because the returned value is correct; only the hardware semantics are destroyed. That is precisely
the failure class GAP-0027 describes: the suite links `@bare` objects into hosted processes where
nothing observes a missing MMIO read.

Marking the same two instructions `volatile` makes the `-O2` output **byte-identical to `-O0`**,
verified. So the fix is understood and narrow; it is the sequencing that matters.

**Consequence for ordering:** `-O` must NOT be enabled before this. Every `Pointer<T>.value` access in
`oscortex_core` — UART, PIC, PIT, IDT — is an MMIO or MMIO-like access whose load or store the
optimizer may drop or reorder. The kernel already knows about one instance and routed around it by
hand: its `tick_count` extern exists because a plain `Pointer<u64>` load in a wait loop is legally
hoistable, and at `-O` that hoist becomes real. There is no reason to think it is the only one; nothing
has ever optimized this code.

---

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
