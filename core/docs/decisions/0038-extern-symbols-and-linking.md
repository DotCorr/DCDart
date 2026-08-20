# ADR-0038: `@extern` — calling external C-ABI symbols, and linking against other object files

**Status:** decided, implemented, AND VERIFIED — `core/tests/conformance/ffi-extern/run.sh` reports
an unqualified PASS on macOS/arm64: real `dcc build`, real undefined symbols with real relocations,
`verify-freestanding.sh` passing on the declared set and still FAILING on an undeclared one, a real
freestanding multi-object ELF link, real native execution of three linked objects, and real calls
into libc (`ffs`/`toupper`/`putchar`) with the byte stream `putchar` produced checked on stdout.

**One part of this ADR changes the meaning of `CLAUDE.md` rule 1 — the project's stated spine — and
was therefore escalated before being built, not after.** `docs/escalations/0003-extern-c-calls-vs-
freestanding.md` was reached independently by two agent sessions and then **decided by the project
owner on 2026-08-20: option 2**, the explicit `@extern` annotation plus a mechanically checked
per-object manifest. Rule 1 now reads "zero undefined symbols *except ones the source explicitly
declared*, checked mechanically."

**Provenance, stated precisely because it matters here:** that decision came from the project owner
and reached this ADR *relayed* through another agent session working in this tree. Neither this
session nor its coordinator witnessed it firsthand. It is recorded as the owner's decision, on that
date, relayed — not as anything this session or its coordinator decided, and not as a firsthand
account. The implementation remains reversible (see "Consequences").

## Context

This is the inbound half of `DCDART_SPEC.md` §9 — *"C ABI is the native ABI… `extern` declarations
bind directly"* — and it is the item `docs/known-gaps.md` GAP-0019 describes as:

> Extern-to-external-symbol FFI — DCDart code calling a symbol not defined in its own Kernel IR
> compilation unit… `dcc` today only ever emits one self-contained relocatable object per compilation
> unit; resolving an external symbol by name is a new architectural concept it doesn't have.

ADR-0034 solved the *outbound* direction (C calls DCDart, declarations generated rather than
hand-written), and its own header says plainly that this direction "is a different, unsolved
problem". ADR-0029 deferred it explicitly when adding `Port.outb`/`Port.inb` rather than general FFI.

`oscortex_core` is the real motivating consumer: its boot stub currently only calls *into* `@bare`
DCDart from assembly, never the reverse, because the reverse did not exist. Interrupt entry stubs,
hand-written assembly helpers and any C driver code it links against all need this direction.

### The rule-1 collision, which is why an escalation exists

`CLAUDE.md` rule 1: every `@bare` object must have zero undefined symbols outside the allowlist, and
"this check is the project's spine." **An external symbol IS an undefined symbol — that is what
calling one means.** So the feature and the rule are in direct tension, and CLAUDE.md's escalation
section covers exactly this ("any new `@bare` runtime symbol", "anything where the honest fix is
'change the language'"). Escalation 0003 lays out the three options and recommends the one built here.

## Options

### 1. Where does "this symbol is external" live in the source?

| | |
|---|---|
| **(a) `@extern` + `external`** — CHOSEN | Dart's `external` keyword already means "declared here, defined elsewhere"; front_end enforces the missing body and Kernel IR records `Procedure.isExternal`. Pure lowering, no Kernel node (rule 2). The annotation on top makes the declaration set explicit and greppable, which the manifest depends on. |
| (b) A recognized class of statics, like `Port` (ADR-0029) | Works only for a fixed, compiler-known symbol list. Users cannot declare their own symbols, which is the entire point. |
| (c) `external` alone, no annotation | Would work mechanically, but the fact that makes a symbol permitted-undefined would then be a Kernel flag invisible in the source's annotation set — the opposite of what a spine check that reads "declared in source" needs. |

### 2. Does DC-IR need a `CallExtern` instruction? — NO

This was the question worth arguing, and the answer is no. At the call site there is **nothing to
distinguish**: a call to an external C-ABI symbol and a call to a sibling `@bare` function emit the
identical machine instruction, pass arguments identically, and obey the same optimizer rules. Every
existing pass that treats `Call` as an opaque barrier (`dc-elide`, ADR-0025/0031) is *already* correct
for an extern call, for free, and would need a second, parallel case if a sibling instruction existed
— a second case that could drift.

What genuinely differs is **module-level**: whether the symbol gets an LLVM `define` or a `declare`.
So the distinction lives there, as `DCModule.externFunctions: List<DCExternFunction>`, and `Call` is
untouched. A `DCExternFunction` is a signature with no blocks; it is deliberately not a `DCFunction`
with an empty block list, because "no blocks" violates `DCFunction`'s own invariant and every pass
walking `module.functions` would have to learn to skip it.

### 3. Where does the permitted-undefined-symbol set live?

| | |
|---|---|
| **A sidecar manifest, `<output>.o.externs`** — CHOSEN | Generated by `dcc` from the same DC-IR the object comes from. Readable by the existing checker with `grep`, no new tool dependency, works identically for ELF and Mach-O. |
| A section inside the object (`.dcdart.externs`) | Cannot drift from the object and cannot be forged separately — genuinely better on trust. Rejected as premature: it needs `llvm-objcopy`/`llvm-readelf` (the checker today needs only `llvm-nm`, and this machine's toolchain exposes only `llvm-nm`), and the section syntax differs between ELF and Mach-O. Recorded here so ratification can ask for it. |
| Extend `tools/bare-symbol-allowlist.txt` | Rejected outright. The allowlist is a single global list owned by E4 and the checker's own error text says not to add to it. It also cannot express "this symbol is permitted *in this object*, because *this source file* declared it". |

### 4. A `dcc link` subcommand? — NO, argued rather than built

`dcc` emits ordinary C-ABI relocatable objects. `clang`, `ld`, `lld` and `x86_64-elf-ld` already link
them, and the conformance harness proves it with all four object files in one command. A `dcc link`
would be a wrapper that adds no capability, hides the real linker's diagnostics (which are far better
than anything a wrapper would synthesize), and immediately acquires an obligation to model linker
scripts, `--gc-sections`, and per-target flag differences. `oscortex_core` needs a *linker script*,
which is a real linker's job, not `dcc`'s. If a future need appears — most plausibly "link a DCDart
object against the DCDart runtime without the user knowing its path" — that is the time to build it.

### 5. `@linkName` and `@section`? — NOT BUILT

`@linkName` matters only when the C symbol name is not a legal Dart identifier. Every symbol this
conformance target needs (`dcx_*`, `ffs`, `toupper`, `putchar`) is. `@section` is a property of a
*defined* symbol, which is the outbound direction, not this one. Both are spec §6 table entries;
building them now would be exactly the speculative table-filling ADR-0029 refused. Recorded in
GAP-0019.

## Decision

### Source

```dart
@extern
external u64 dcx_add(u64 a, u64 b);

@bare
u64 addThroughC(u64 a, u64 b) => dcx_add(a, b);
```

Both markers are required, and `dcc-lower` rejects each without the other, by name. It also rejects:
`@extern` together with `@bare` (a symbol is imported or exported, never both); a `@bare external`
declaration (points at `@extern`); a duplicate declaration; named/optional parameters and generics
(C has none); and a declared extern whose name collides with a `@bare` function defined in the same
unit (the link would silently prefer the local definition).

**Signature types: `u8`/`u16`/`u32`/`u64`/`Result`/`void` only.** An ARC-managed `HeapObject` or
`Weak<T>` in an extern signature is **rejected**, because it raises an ownership question — does the
callee consume, borrow, or retain? — that nothing in this project has decided. `@owned` (ADR-0021)
answers it for DCDart-to-DCDart calls precisely because both sides are compiled here; neither half of
that machinery exists for C. Picking a convention silently would be a memory-model decision made by
an implementation unit, which rule 4 forbids. Note this is **not** symmetric with `c_header.dart`,
which does map a `DCHeapPointer` — to an opaque `DCHeapRef` that C is told never to dereference. That
direction is safe because DCDart still owns the object; inbound, C would be the one receiving
something it might store or free.

### Backend

One `declare <ret> @name(<paramtypes>)` per extern, before the `define`s. Verified as necessary, not
assumed: `call i64 @c_add(...)` with no `declare` is rejected by clang outright (*"use of undefined
value '@c_add'"*), tested standalone before wiring anything in.

**No `#0` (`nounwind`) on a `declare`**, unlike every `define` this backend emits. On a `define` that
attribute is a claim about code we compiled; on a `declare` it would be a claim about somebody else's
object file, and a wrong one would mislead the optimizer rather than merely slow the program.

### The freestanding check — the ratified rule-1 narrowing

`dcc` writes `<output>.o.externs` after a successful build, and **deletes a stale one** when a build
declares no externs (a leftover manifest would permit symbols the current object never declared —
that deletion is a correctness requirement, not tidiness).

`scripts/verify-freestanding.sh` permits exactly those names in addition to the allowlist, prints them
on every pass (`FREESTANDING: pass  foo.o  (7 declared extern(s): …)`), and notes a manifest entry
that no undefined symbol matches. **Nothing else is weakened**: an undefined symbol with no manifest
entry is still fatal, an object with no manifest behaves exactly as before, and `dc_alloc`/`dc_throw`/
`Dart_*` can never appear in a manifest because only source-level declarations go in it.

### The two conditions attached to the ratified option

Both came from the other session as its own recommendation rather than from the owner's decision, so
both are answered here explicitly rather than quietly dropped.

**Condition 1 — the checker must PRINT the declared externs even on success. BUILT.** A check whose
job is now "distinguish declared from undeclared" is much weaker if the declared set is invisible;
silence must not be the success signal for the thing that was just started being permitted. The pass
line reads `FREESTANDING: pass  foo.o  (7 declared extern(s): dcx_add dcx_answer …)`, and the
conformance harness FAILS if that text is missing — so this cannot silently regress. The checker also
prints a note for a manifest entry that matches no undefined symbol (a stale entry), which permits
nothing but is worth seeing.

**Condition 2 — reject `@extern` inside an `@interrupt` function. SPECIFIED, NOT ENFORCED.** This is
load-bearing for a stronger reason than consistency with the no-allocation rule: a call out of an
interrupt handler has unbounded stack depth, unknown blocking behaviour and unknown reentrancy, none
of which the compiler can see through a `declare`. The rule, in full, so whoever builds `@interrupt`
inherits it rather than re-deriving it:

> A call to an `@extern` symbol, direct or transitive through another `@bare` function, is a
> compile-time error inside a function annotated `@interrupt`. Transitively, because the hazard is
> the call reaching foreign code at all, not the syntactic position of the call site — which means
> enforcing it needs a call-graph walk over the module's `Call` instructions, not a local check.

**None of it is enforced today, and this ADR does not claim otherwise: `@interrupt` does not exist in
DCDart at all.** There is no annotation, no lowering, and no checker for it — `known-gaps.md`
GAP-0019 has listed it as "not yet built at all" since ADR-0029, and `oscortex_core`'s own gap file
records that its M1 interrupt handlers are correct by inspection only for exactly this reason. A
check keyed off an annotation nothing can write would be dead code that looks like a guarantee. The
rule is recorded in GAP-0019 against `@interrupt`'s own entry, so it is a prerequisite of that work
rather than a forgotten condition of this one.

### One gap closed on the way: a void call as a statement

`Port.outb` (ADR-0029) was the only void-returning call any source could make, via a hardcoded case.
`void` is the most common return type in C, so the general path was finally worth building:
`_lowerCallTo(..., allowVoid: true)`, reached from `ExpressionStatement`, for both `@bare` siblings
and `@extern` symbols. This makes `Call(dest: null)` — which the backend has supported since ADR-0018
but nothing could reach — actually reachable, and the conformance target executes it.

A **non-void** call as a bare statement is still refused, deliberately: discarding a `HeapObject`
return leaks under the naive release policy (ADR-0016 releases only values bound to a tracked local),
and one rule ("bind the result") is better than two.

## Verification — what each leg proves that the others cannot

`core/examples/ffi-extern/` + `core/tests/conformance/ffi-extern/run.sh`:

| Step | Proves |
|---|---|
| 1 | `dcc` emits exactly 7 real undefined symbols and a manifest naming exactly them. The expected list is spelled out in the harness, not read back from the manifest — a check that reads its answer from the thing under test proves nothing. |
| 2 | `verify-freestanding.sh` PASSES the object and reports what it honored. |
| 3 | **The spine test.** Same object, manifest removed → the same check must FAIL. This is the difference between "rule 1 with a declared exception" and "rule 1 abandoned", asserted mechanically on every run. |
| 4 | Real freestanding multi-object ELF link (`-nostdlib`, no libc): entry stub + `main.o` + `c_side.o` + dcc's object, then zero undefined symbols in the LINKED image. This is oscortex_core's configuration. |
| 5 | Real native 3-object link with plain `clang` and **real execution**, exit 0 across all nine check groups. |
| 6 | Real **libc** — `ffs`/`toupper`/`putchar`, symbols nobody in this project wrote, compiled years ago against a published ABI. Exit code AND the bytes `putchar` left on stdout are both checked, so a constant-folded return value cannot pass. |

The nine check groups in `main.c` cover: u64 in/out; a zero-argument extern; u32 and u8 widths
(exhaustively over their ranges); mixed widths in one signature; the void extern with a side effect
read back from C; an extern call inside a `while` loop (200 values against `n(n+1)/2`); a `Result`
struct returned **by value from C** and propagated through `.propagate()`, both Ok and Err paths; and
DCDart calling DCDart calling C.

Negative controls were run by hand before trusting any of it: linking without `c_side.o` fails with
unresolved `dcx_*`; a deliberately wrong expected value in `main.c` makes the binary exit non-zero in
both the native and the freestanding configurations.

### Freestanding execution on this machine

Step 4 links the freestanding x86-64 image for real on macOS via `x86_64-elf-ld` (Apple's `ld` cannot
link ELF) and verifies every relocation resolved, but cannot *execute* an x86-64 Linux binary on
arm64 — the same class of limitation as ADR-0029's, handled the same way: the harness says so
explicitly rather than skipping quietly, and step 5 executes the identical DCDart source natively. It
also runs the freestanding image for real when a `qemu-x86_64` or a Linux/x86-64 host is available.

Out of band, the freestanding image WAS executed under `qemu-x86_64` (exit 0), and so were all 17
pre-existing freestanding conformance targets, relinked the same way — `m0-seam` exits 5 as its
criterion requires, the other 16 exit 0. Zero regressions.

## Consequences

- GAP-0019's extern-FFI item is **resolved**. General inline `asm`, `@naked`, `@interrupt`
  enforcement, `@linkName` and `@section` remain open there — this ADR builds one item, not the table.
- `@interrupt` must reject `@extern`, transitively, when it is built. Specified above in full;
  **unenforced**, because `@interrupt` does not exist. Recorded in GAP-0019 against `@interrupt`'s own
  item so it is a prerequisite of that work, not a footnote to this one.
- A new gap: extern signatures cannot carry `Pointer<T>`, because `_lowerSignatureType` does not map
  `Pointer<T>` in parameter or return position at all — a pre-existing limit this ADR did not widen,
  but one that most real C APIs (`strlen`, `memcpy`, `write`) need. GAP-0025.
- A new gap: no signed sized-integer types, so a C `int` parameter is declared `u32`. ABI-correct on
  both SysV-AMD64 and AAPCS64 (same register, same width) but interpretation-incorrect for negative
  values. GAP-0026.
- `scripts/verify-freestanding.sh`'s meaning changed. That change is **ratified** (owner's decision,
  2026-08-20, relayed) and is stated in the script's own header, in `pipeline.dart`, in the prelude,
  in the harness, in `known-gaps.md` and in escalation 0003 — all six agree on the same wording.
- **Reversible**, deliberately: deleting `_writeExternManifest` from `dcc/lib/pipeline.dart` and the
  `$obj.externs` lookup from `scripts/verify-freestanding.sh` restores the previous check exactly, and
  the only thing that stops working is the extern feature itself. That property is worth keeping while
  the first real consumer (`oscortex_core`) is still finding out what it needs.
