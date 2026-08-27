# ADR-0065: Floating point (f32/f64) — IEEE-754, no traps, saturating truncation

**Status:** decided and implemented, verified (`tests/conformance/float-arith/`,
`tests/conformance/float-pointer/`)

**Numbered 0065**, not 0061: 0061/0062 are absent from this directory but the spec already cites
ADR-0064 (§3.5 ownership qualifiers), so 0061–0064 are treated as claimed by in-flight work rather
than reused.

## Context

Spec §4.1 has listed `f32 f64` in the sized-type set since M0 — one line, no semantics — and
`DCFloat` has existed as a type node just as long (types.dart split it from `DCInt` precisely
because float arithmetic has no overflow-trap or wrapping story). Everything downstream refused it:
no float instructions in DC-IR (an explicit scope cut), `_llvmType` threw on `DCFloat`, the prelude
had no `f32`/`f64`, and ADR-0036 closed with "No floating point, and no `/` operator, remain
deliberate."

What changed is a consumer: **project NEON needs float ML kernels** — matmul/softmax/layernorm over
`Pointer<f32>` buffers — and the owner authorized the language change in-session on **2026-08-27**
(`docs/escalations/0012-floating-point-authorization.md`; §4.1 changes are on CLAUDE.md's
escalation list, so this did not get decided by an agent alone). This supersedes **the float half of
ADR-0036 only**: integers still have no `/` — `~/` remains the only integer division, with its
zero-divisor trap — and every argument ADR-0036 made about `/` lying to Dart readers *on integers*
stands. On a float, `/` means to a Dart reader exactly what it does, so the objection dissolves
rather than being overridden.

## Decisions

**1. Semantics: IEEE-754 binary32/binary64, and arithmetic NEVER traps.** Overflow rounds to ±inf,
`0.0/0.0` is NaN, NaN propagates, ordered comparisons are false against NaN and `!=` is true
(`une`) — all of which is simultaneously the IEEE rule, upstream Dart's `double` behavior, and what
one hardware instruction does. There are no wrapping variants (`&+`) because there is nothing for
them to vary from. This asymmetry with the integers is the reason `DCFloat` was a separate node from
day one, and it is now load-bearing in the instruction set too: `FAdd`/`FSub`/`FMul`/`FDiv` carry no
`Overflow` field, and `FDiv` has no zero-divisor guard (`fdiv x, 0.0` is a defined result, not LLVM
poison — the entire reason `IDiv`'s compare-and-trap exists does not apply).

**2. Prelude surface mirrors the u\* pattern.** `f32`/`f64` extension types over `double` (Dart has
no 32-bit float; the backing type never executes anyway) with `+ - * /`, `< <= > >= == !=`, unary
minus, and six conversions: `f32.toF64()` (fpext, exact), `f64.toF32()` (fptrunc, round to nearest
even), `u32.toF32()`/`u64.toF64()` (uitofp, round to nearest even — only observable above 2^24/2^53
respectively), and `f32.toU32trunc()`/`f64.toU64trunc()` (below). `==`/`!=` go through the same
`EqualsCall` route as the sized ints (extension types cannot declare `operator ==`), lowered to
`fcmp oeq`/`fcmp une`. Only the two "natural" int↔float pairings exist, not the 4×2 matrix — same
build-what's-needed discipline as every prelude member.

**3. Float→int truncation SATURATES (`llvm.fptoui.sat`), rather than trapping or being UB.** The
options were: (a) plain `fptoui` — poison on out-of-range/NaN, i.e. silent UB the optimizer may
exploit, strictly worse than either alternative; (b) an explicit range-check-and-trap, `IDiv`-style
— a compare and branch on every conversion, and a trap on a *conversion* is a harsher contract than
the "you said the word narrow" one `.toU8()` already set; (c) the saturating intrinsic —
deterministic (clamp to the destination's range, NaN→0), branchless, and recognized-by-name inline
codegen on both registry architectures, so no rule-1 symbol leak. **Option (c).** `IConvert`'s "the
explicit call is the safety mechanism" reasoning covers discarded fraction bits, not poison. The
spelling `toU64trunc` keeps the rounding mode (toward zero) visible at the call site; a future
`.toU64round()` is a different operation, not a replacement.

**4. f32 literal story: `f32(1.5)`, one rounding, at emission.** A literal is the double value the
CFE hands over (`DoubleLiteral`, or `DoubleConstant` for a named const; an *integer* literal in
that position — `f64(2)` — is already a `DoubleLiteral` by the time lowering sees it, verified
empirically). `ConstFloat` stores the double; the backend computes the exact IEEE bit pattern —
including the single round-to-nearest-even for an f32 dest — and emits it as `bitcast iN <bits>`,
not a decimal or hex-float literal. LLVM's textual float constants have parsing/rounding rules of
their own (a `float` constant must be the double exactly representable in float); emitting bits
sidesteps that entire class of double-rounding bug and gives `f32(0.1)` the same guarantee as C's
`0.1f`. There is no bare-`1.5`-literal-in-float-context inference: like `u64(1)`, the constructor
IS the literal syntax at this stage of the frontend (ADR-0008's minimal surface).

**5. DC-IR: a parallel instruction family, not a float mode on the integer one.**
`ConstFloat`/`FAdd`/`FSub`/`FMul`/`FDiv`/`FNeg`/`FCmp`/`FConvert`, following the existing shapes
(dest/lhs/rhs `DCValue`s, sealed hierarchy, predicate enum named after LLVM's own condition codes).
`FNeg` is a real instruction because `fneg` differs from `0.0 - x` on IEEE zeros and NaN payloads.
`FConvert` is ONE instruction fully determined by its two types (fpext/fptrunc/uitofp/fptoui.sat),
`IConvert`'s exact argument; signed endpoints are rejected at emission the way signed `IDiv` is
(GAP-0024's forward-looking refusal). The sealed hierarchy did its job again: `dc-elide`'s
`referencedValueIds` was the one other exhaustive switch, found by the analyzer, not by hand.

**6. Backend: hardware float only, no fast-math.** `DCFloat` → `float`/`double`; every op is one
instruction (SSE2 is baseline on x86-64, NEON on aarch64 — no `-mno-sse`/soft-float flags anywhere
in `compile.dart`, so `fadd` never becomes `__addsf3`, which `verify-freestanding.sh` would catch as
an undefined symbol). Plain `fadd`, never `fadd fast`: reassociation would make results drift as the
optimizer evolves; a workload that wants fast-math should someday ask for it explicitly. Loads and
stores through `Pointer<f32>`/`Pointer<f64>` reuse the existing Load/Store instructions unchanged —
the width falls out of the pointee type via `_llvmType`, at LLVM's natural 4/8-byte ABI alignment.

**7. Lowering: floats join `DCInt` as reassignable scalars.** Straight-line reassignment
(ADR-0027), if/else merges (ADR-0032) and loop-carried variables (ADR-0028) all accept `DCFloat` —
a float accumulator (`sum = sum + a[i] * b[i]`) is the defining loop-carried value of the consuming
workload. No ownership questions arise; a float is bits, like an int.

## Deliberately NOT in scope

- **Transcendentals** (exp/log/sqrt/pow). Each is a potential libcall — a rule-1 violation in
  `@bare` — and softmax et al. will get them later via explicit `@extern` C math or polynomial
  kernels. Adding `sqrt` "because LLVM has an intrinsic" is how a runtime dependency sneaks in.
- **SIMD.** -O2 may auto-vectorize the dot loop; that is the optimizer's business, not a surface.
- **`Pointer<T>` in `@bare` function signatures** (pre-existing, now more visible: buffers are
  passed as u64 addresses, the repo's established idiom), **float `@rodata` tables**, **f32/f64 in
  `Result`**, and **bare `1.5` literal inference**. All recorded in GAP-0063.

## Consequences

- The dot product — fill `Pointer<f32>` buffers from `Heap.allocate`, multiply-accumulate, free —
  compiles, runs bit-exactly against C's own f32 accumulation up to n=4096, leaks nothing, and the
  bare-x86_64 object stays freestanding. That is the M4/NEON kernel shape, minimally.
- Every float result in both harnesses is compared by **bit pattern** (memcmp), not tolerance: both
  sides run the same IEEE ops in the same order, so anything less than equality is a rounding-mode,
  double-rounding, or width bug. This is the float analogue of m2-arith's exact-value discipline.
- ADR-0036's trap-on-`~/`-by-zero and the absence of integer `/` are unchanged. `IShr`'s "every
  sized type is unsigned" note now has a float sibling: `FConvert` reads signedness the same way
  and refuses the signed paths by name.
- `c_header.dart`'s `DCFloat` case (written for exhaustiveness, previously unreachable) became live:
  f32/f64 cross the C ABI as `float`/`double`, passed in vector registers per SysV/AAPCS64.
