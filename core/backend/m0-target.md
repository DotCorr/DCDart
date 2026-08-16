# M0 backend target: `add.dart` → freestanding `add.o`

Scope: exactly the M0 exit criterion (`ROADMAP.md`), nothing past it.

```dart
@bare
u64 add(u64 a, u64 b) => a + b;
```

Source: `core/examples/m0-seam/add.dart`. Test harness: `core/examples/m0-seam/main.c`.
Exit: `dcc build --mode bare add.dart -o add.o` produces an object file where
`llvm-nm -u add.o` prints nothing, and `main.c` linked against it returns 5.

This doc is the missing "DC-IR → LLVM IR → object file" stage for that one function.
**Not covered:** general struct layout, ARC codegen, generics, anything past M0. `u64` is
a value type — two registers in, one register out, no heap object, so ARC does not enter
this picture at all (not "elided," genuinely inapplicable: there is no `DCObject` header
to retain or release).

No toolchain is installed in this dev environment (`core/docs/known-gaps.md` GAP-0001).
Everything below is designed to be followed mechanically once one exists, but none of it
has been run. Treat exact flag behavior (marked below) as "best available reasoning,"
not "verified."

---

## 1. The LLVM IR

```llvm
; add.ll — DC-IR lowering of core/examples/m0-seam/add.dart
;
; u64 -> i64. DCDart's u64 is unsigned but LLVM's `add` instruction is sign-agnostic
; (two's complement wraps the same way regardless); signedness only matters for
; instructions that branch on it (icmp, sdiv/udiv, etc.), none of which appear here.

target triple = "x86_64-unknown-none-elf"

define i64 @add(i64 %a, i64 %b) #0 {
entry:
  %sum = add i64 %a, %b
  ret i64 %sum
}

attributes #0 = { nounwind }
```

Notes on specific choices:

- **No `target datalayout` line hand-written here.** It's illustrative-only if included by
  hand; the real `dcc-lower` should get it from
  `TargetMachine::createDataLayout()` for whatever triple it's targeting, not a hardcoded
  string that silently rots across LLVM version bumps. `llc` fills in the default layout
  for `-mtriple=x86_64-unknown-none-elf` if the `.ll` omits it.
- **`add i64`, not an overflow-checked intrinsic.** `DCDART_SPEC.md` §4.1 and `CLAUDE.md`
  both say integer arithmetic traps on overflow by default — but sized integers and their
  trap semantics are explicitly **M1** scope (`ROADMAP.md`: "M1 — The type model: Sized
  integers..."), not M0. M0's job is only to prove the Kernel IR → object file seam holds
  at all. Baking overflow-trap codegen in now would be designing the general backend,
  which this doc is explicitly scoped away from. See §5 for the forward note on how that
  should look when M1 picks it up (short version: `llvm.uadd.with.overflow.i64` +
  `llvm.trap()`, both of which lower to inline instructions with no external symbol —
  worth planning for now precisely because it stays freestanding for free).
- **`nounwind` on the function.** `@bare` cannot throw (spec §5: `try`/`catch`/`throw` are
  a parse error in `@bare`), so no DC-IR lowering of `@bare` code should ever produce an
  `invoke`/`landingpad`, which is what would need a personality routine. `nounwind` is a
  cheap, load-bearing assertion of that invariant at the LLVM IR level — it should be on
  every `@bare` function `dcc-lower` emits, not just this one. It also stops LLVM from
  generating call-site unwind bookkeeping around calls to `@add`... from other functions;
  irrelevant for this leaf function's own body but the right default to set once and never
  revisit per-function.
- **Calling convention: no `ccc`/explicit keyword needed.** LLVM's default IR calling
  convention *is* the C calling convention for the target (SysV AMD64 on
  `x86_64-*`, per spec §9: "Calling convention: SysV AMD64 / AAPCS64 depending on target").
  `i64 %a` → `RDI`, `i64 %b` → `RSI`, return value → `RAX`. This is exactly what
  `main.c`'s `extern uint64_t add(uint64_t a, uint64_t b)` expects from a plain C function
  — no `swiftcc`, no `fastcc`, no custom convention. Nothing to write here beyond leaving
  it unspecified.
- **No `dso_local`, no explicit linkage keyword.** `define` defaults to external linkage,
  default visibility — correct for a symbol that must be visible to the linker when
  `main.c` pulls it in. `llc` will infer `dso_local` itself once given
  `-relocation-model=static` (see §3); no need to assert it by hand in the `.ll`.

---

## 2. Symbol naming: unmangled, exactly `add`

**Decision: `@bare` top-level functions emit their DCDart identifier verbatim as the
object-file symbol. No mangling for M0, and none planned for `@bare` ever.**

Justification:

1. **The exit criterion requires it.** `main.c` declares
   `extern uint64_t add(uint64_t a, uint64_t b);` — plain C linkage, no `@export` or
   `extern "C"`-equivalent annotation appears anywhere in `add.dart`. If `@bare` functions
   mangled by default, M0 could not link without inventing an annotation the spec doesn't
   have yet. Unmangled-by-default is the only reading of the source that makes the exit
   criterion satisfiable as written.
2. **Spec §9 makes the C ABI the *native* ABI for `@bare`, not a translation target.**
   "`@bare` code is freestanding: no libc dependency... `nm` on a `@bare` object file shows
   only your symbols plus `dc_retain`/`dc_release`" — the spec's own description already
   assumes the DCDart source name *is* the symbol name. Kernel/driver code that needs to be
   called from C, from `asm` blocks (§6's `isrTimer` example), or from a linker script
   (entry points, ISR vectors) needs the name to be predictable and exact; a mangled name
   would break every one of those call sites for no compensating benefit at `@bare`'s
   scale.
3. **Precedent:** this matches how every other systems language treats freestanding/kernel
   code — C has no mangling at all, Rust requires `#[no_mangle] extern "C"` to opt *out* of
   its normal mangling for exactly this use case, Zig's `export fn` does this by default.
   DCDart's `@bare` is closer to "everything is implicitly the Rust
   `#[no_mangle] extern "C"` case" than to "mangle by default, opt out per function" —
   simpler, and it's the only option that needs zero new syntax to satisfy M0.
4. **Keep-it-simple-for-M0:** don't design a mangling scheme (module path + arity + type
   encoding, Itanium-style or otherwise) before there's a second function in the surface
   area that actually needs disambiguating. That's real design work with real tradeoffs
   (readability in `nm`/debuggers vs. collision safety) and it belongs with M1's type model
   work, scoped to `@hosted` code where overloading and generics actually exist. `@bare`
   top-level functions should stay unmangled permanently regardless of what M1 decides for
   `@hosted`, per point 2 above.

**Open question this decision does not resolve (flagged in §5, not decided here):** what
happens when two `@bare` functions in different libraries are both named e.g. `init`? Out
of scope for a one-function exit criterion; needs an answer before M1 has more than a
handful of `@bare` functions in flight.

---

## 3. Compile invocation

Two equivalent paths. Recommend the first for `dcc`'s actual implementation; both produce
the same `add.o`.

### 3a. `llc` directly (recommended)

```bash
llc -mtriple=x86_64-unknown-none-elf \
    -relocation-model=static \
    -filetype=obj \
    add.ll -o add.o
```

Why this is the right shape for `dcc` itself: the architecture diagram in
`DCDART_SPEC.md` §1 is `DC-IR → LLVM IR → object file` — there is no C source anywhere in
that pipeline. `dcc-lower` emits finished, already-lowered LLVM IR; going straight through
`llc` (or, in the real implementation, linking against LLVM's `TargetMachine` /
`LLVMTargetMachineEmitToFile` C++ API instead of shelling out to a binary at all) skips an
entire layer of Clang-driver flag interpretation that exists to handle *C-language source*
concerns (stack protector defaults, builtin recognition, freestanding library assumptions)
that a from-IR pipeline never needs to negotiate, because DC-IR never emits the patterns
those flags are guarding against in the first place. `-filetype=obj` goes IR → native
object via LLVM's integrated assembler; no external `as` invoked.

Flags:
- `-mtriple=x86_64-unknown-none-elf` — target triple. `unknown-none-elf` breaks down as
  vendor=`unknown` (no assumptions), OS=`none` (the load-bearing part: tells LLVM there is
  no hosted OS ABI, so it must not assume libc/libm exist as a lowering target — see §4),
  environment=`elf` (explicit object format, matches this being x86_64 not one of the
  triples where ELF is merely the assumed default). This is the same shape as Rust's
  `x86_64-unknown-none` bare-metal target, which has years of OS-dev mileage (Redox and
  most hobbyist x86_64 kernels use it or something isomorphic to it) as an existence proof
  that "OS=none" is sufficient to get genuinely freestanding codegen out of an LLVM-based
  toolchain.
- `-relocation-model=static` — no PIC. Kernel/freestanding code isn't a shared library;
  PIC buys GOT/PLT indirection for a use case (multiple loaded instances, ASLR-by-the-
  dynamic-linker) that doesn't apply here and that `dcc` doesn't want to have opinions
  about yet. Static relocation is also what lets `llc` infer `dso_local` on `@add` without
  being told.
- `-filetype=obj` — emit a native `.o`, not assembly text.

### 3b. `clang` consuming the `.ll` directly (equivalent, useful for manual verification)

```bash
clang --target=x86_64-unknown-none-elf \
      -ffreestanding -fno-builtin \
      -fno-stack-protector \
      -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables \
      -c add.ll -o add.o
```

Flag-by-flag, and an explicit caveat on which of these actually do anything for `.ll`
input specifically:

| Flag | Purpose | Applies to `.ll` input? |
|---|---|---|
| `--target=...` | Same as `-mtriple` above. | Yes — always consulted by the backend regardless of input kind. |
| `-c` | Stop after emitting the object file; **do not link.** This is the one flag in this table that is load-bearing no matter what: without it, `clang` tries to produce an executable, which means supplying CRT startup files and expecting a `main`/entry point — testing a different, wrong artifact. | Yes, always. |
| `-ffreestanding` | Tells Clang's C-language frontend not to assume a hosted standard library, so certain source patterns aren't opportunistically rewritten to libc calls. | **Unverified, likely no-op for `.ll` input.** Clang's driver treats `.ll`/`.bc` as already-IR and routes them straight to the LLVM backend, skipping the Sema/CodeGen phase these `-f*` frontend flags configure. Keeping it in the invocation costs nothing and documents intent; do not rely on it doing anything until confirmed against a real toolchain (GAP-0001). |
| `-fno-builtin` | Stops Clang from recognizing a hand-written pattern (e.g. a manual copy loop) as equivalent to a libc function and rewriting it into a call to that function. | Same caveat as above — a frontend-phase behavior, likely inert on `.ll`. Not triggered by this function's body regardless (a scalar `add` has no pattern to recognize). |
| `-fno-stack-protector` | Prevents Clang from requesting the stack-protector pass (canary prologue/epilogue, `__stack_chk_guard` read + `__stack_chk_fail` call on mismatch). | Frontend-phase flag; see above. The actual, tool-independent guarantee is that `dcc-lower` never sets the `ssp`/`sspstrong`/`sspreq` **IR-level function attribute** — that's what the backend's StackProtector pass keys off, and it works identically whether the IR came from Clang, `llc`, or hand-written text. |
| `-fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables` | Stop emission of `.eh_frame`/CFI unwind metadata and any implied personality-routine plumbing. | Frontend/driver-phase, mostly. The real guarantee is the same as `nounwind` in §1: DC-IR for `@bare` never emits `invoke`/`landingpad`, so there is no personality routine to reference regardless of these flags. |
| (not shown) `-nostdlib` | Suppresses default startup files and default libraries **at link time.** | N/A here — `-c` means no link happens in this invocation at all. Listed for completeness in case this step is ever collapsed into a single compile-and-link command; if that ever happens, this is the flag that matters, not `-ffreestanding`. |

Given the caveats in that table, prefer 3a for anything that needs to be *relied on*, and
treat 3b as a manual sanity-check path a human can run with `clang` alone (no `llc`
binary needed) once a toolchain exists.

### Verify

```bash
llvm-nm -u --format=posix add.o
```

Matches exactly what `core/scripts/verify-freestanding.sh` runs (`NM="${NM:-llvm-nm}"`,
same flags). Expected output for this `add.o`: **nothing.** No entries need to be added to
`tools/bare-symbol-allowlist.txt` to make this pass — `add` has no aggregates, no
divisions, no locals, nothing that could plausibly lower to a libcall. If M0 only passes
after adding something to the allowlist, that's a sign the IR in §1 wasn't actually
emitted (see §4).

### Link the test binary (separate step, not part of the freestanding check)

```bash
cc core/examples/m0-seam/main.c add.o -o add_test
./add_test; echo $?   # must print 5
```

This resolves the "or whatever the bare link line ends up being" hedge in
`core/examples/m0-seam/README.md`: **no special flags on this step.** `main.c` is an
ordinary hosted C program — it links normally against the host's libc/CRT, gets a normal
`_start`, and calls into `add.o` like any other externally-declared C function. `-nostdlib`
here would be wrong (it would remove the very `_start`/CRT that `main.c` needs) — the
freestanding requirement applies to `add.o` alone, verified *before* this link step, not to
the linked `add_test` binary as a whole.

**Open question, not resolved here (see §5):** this repo's actual dev environment is
Windows 11 (native object format PE/COFF), while `add.o` above targets
`x86_64-unknown-none-elf` (ELF). A native Windows `cc`/`link.exe` cannot link an ELF
object into a PE executable directly. `@bare`/kernel code is always going to be
tested under QEMU per `DCDART_SPEC.md` (`dc-test --qemu`) anyway, so the likely resolution
is "M0 verification happens inside Linux/WSL, full stop, native Windows host toolchain
is never in this loop" — but that should be an explicit decision, not an implicit one
discovered when someone finally runs this.

---

## 4. What would make `nm -u` NOT print nothing, and how this design avoids each

Concrete failure modes for a naive translation of this exact function, in rough order of
how likely a first attempt is to hit them:

1. **Stack protector canary → `__stack_chk_fail`, `__stack_chk_guard`.**
   Triggered by the LLVM IR-level `ssp`/`sspstrong`/`sspreq` function attribute, which the
   backend's StackProtector pass reads regardless of which frontend produced the IR.
   `add`'s body has no local buffer/array for any real stack-protector heuristic to flag,
   so this specific function is unlikely to trip it even with the attribute set — but
   that's a property of this function, not a guarantee. **Avoidance:** `dcc-lower` must
   never emit `ssp*` attributes on `@bare` functions, full stop, not "only when it looks
   necessary." No amount of `-fno-stack-protector` on a `clang` invocation substitutes for
   this if `dcc-lower` ever hand-authors or round-trips IR that already carries the
   attribute.
2. **Overflow-trap codegen calling into an unimplemented runtime helper.**
   The spec's "arithmetic traps by default" rule (§4.1) is easy to get wrong in exactly the
   way that breaks freestanding: lowering `a + b` to a call like `dc_panic("overflow")`
   or `abort()`/`__assert_fail` pulls in a symbol that doesn't exist yet (and even once it
   does, `dc_panic` printing a message needs formatting + probably a serial/console write,
   which is a lot of runtime for M0). **Avoidance (forward note for M1, not built here —
   see §5):** lower the trap to `llvm.uadd.with.overflow.i64` (branches on the overflow
   bit) + `llvm.trap()` on the taken branch. Both are LLVM intrinsics that the x86_64
   backend lowers to inline instructions (`add`+`seto`/`jo`, and `ud2` respectively) —
   never to a call against an external symbol. `declare`-ing an `llvm.*` intrinsic in a
   `.ll` file does not produce an `nm -u` entry any more than `declare void
   @llvm.memcpy...` does; the backend recognizes the name pattern and never emits a
   relocation against it. This M0 doc uses plain `add i64` (§1) specifically to stay out of
   this scope, but the failure mode is real enough to write down now.
3. **Soft-integer / libm libcalls from widening or non-native-width math.**
   Not triggered here (`i64 + i64` is native machine width on x86_64, one `add`
   instruction) — but the pattern to watch for once `dcc-lower` handles `i128`/`u128`
   intermediate results (e.g. a checked multiply) or floating point: those can lower to
   compiler-rt calls like `__multi3`, `__udivti3`, `__addsf3`, `__floatsidf`. These aren't
   runtime creep in the same sense as `dc_alloc`/`dc_throw` — they're pure,
   OS-independent math routines — so the right home for them is compiler-rt statically
   linked in, with their names added to `tools/bare-symbol-allowlist.txt` once genuinely
   needed. Not needed for `add`; flagged for whoever hits it first.
4. **`memcpy`/`memset`/`memmove` from aggregate copies.**
   Not triggered here — `u64` is a scalar in a register, there's no aggregate to copy.
   General rule for later: `llvm.memcpy.*`/`llvm.memset.*` intrinsics lower to inline
   move/store instructions only when the size is small and statically known; larger or
   variable-size ones become real calls to `memcpy`/`memset`, which is exactly why
   `tools/bare-symbol-allowlist.txt` already has those four names pre-commented as the
   first candidates to uncomment "once codegen exists." `add` never reaches this path.
5. **Exception/unwind personality routine (`__gxx_personality_v0`, `_Unwind_Resume`).**
   Only occurs if DC-IR emits `invoke`/`landingpad`, which only happens if a `throw`
   reaches `@bare` lowering. Spec §5 makes `throw` a **parse error** in `@bare`, so this
   should be caught upstream of codegen entirely, before DC-IR exists. `nounwind` on every
   `@bare` function (§1) is the defense-in-depth backstop, not the primary guarantee — the
   primary guarantee is the frontend rejecting the `throw` in the first place.
6. **Collapsing compile-and-link into one command.**
   Not a codegen bug but a process one: running `clang add.ll -o add` (no `-c`) instead of
   `clang -c add.ll -o add.o` produces a *linked executable*, which will pull in a default
   CRT/entry point and libc, silently resolving anything undefined — `nm -u` on that final
   binary would show nothing (it's fully linked!) while proving nothing about whether
   `add.o` itself was freestanding. Always run the freestanding check against the
   intermediate `.o`, never against a linked binary that happens to include it. This is
   why `verify-freestanding.sh`'s usage line takes `.o` files explicitly, not a linked
   target — worth keeping in mind since it's an easy step to fold together by accident.

---

## 5. Open questions (not decided here, flagged for whoever picks them up)

- **`@bare` name-collision policy.** What happens when two `@bare` functions in different
  libraries share a name? Unmangled-by-default (§2) makes this a real linker error someday.
  Not needed for M0's one-function surface; needs an answer before M1 has more than a
  handful of `@bare` functions in flight. Candidate options: (a) convention-only, same as C
  kernels today; (b) require `@export` explicitly for anything crossing a library boundary
  unmangled, and give everything else internal-by-default `@bare` linkage. Not mine to
  decide — flagging per `CLAUDE.md`'s escalation rule ("anything where the honest fix is
  change the language").
- **Host OS for running the M0 check.** This repo's dev environment is Windows 11; the
  target triple here is `x86_64-unknown-none-elf` (ELF). Native Windows linking of that
  `.o` is not something this doc resolves (§3, end). Given `@bare`/kernel code is always
  QEMU-tested per spec, the likely answer is "verify inside Linux/WSL," but that should be
  said out loud once, not discovered implicitly.
- **`clang`-on-`.ll` frontend-flag behavior (§3b table).** Several flags in that table are
  marked "likely no-op for `.ll` input" based on general Clang driver architecture
  (`.ll`/`.bc` route straight to the backend, skipping Sema/CodeGen), not on having run it.
  Cheap to confirm the first hour a toolchain exists; until then, treat 3a (`llc` directly)
  as the invocation actually being relied on.
- **Datalayout string.** §1 deliberately doesn't hand-write one. If `dcc`'s real
  implementation ends up needing a literal string constant somewhere (rather than querying
  `TargetMachine::createDataLayout()` at runtime), get it from a live `llc`/`clang`
  invocation for the exact LLVM version pinned by the project, not from this doc.
