# ADR-0071: Freestanding targets forbid FP/SIMD registers; `@bare` floating point is opt-in

**Status:** decided — implemented and verified (`4e1d571`)

## Context — the compiler put SSE in a kernel that never asked for it

`oscortex_core`'s kernel gained **275 `xmm` instructions with no source change**, between two builds
on the same day. Its `m11-proc` harness, which asserts zero SSE instructions, went from PASS to FAIL.
The only moving part was DCDart being edited in place for floating point (ADR-0065).

Reproduced minimally here before anything was changed — a 512-iteration `.bss` zeroing loop over
`u64`, containing no floating point anywhere, built for `bare-x86_64`:

```
   a:  0f 57 c0        xorps  %xmm0, %xmm0
  10:  0f 29 00        movaps %xmm0, (%rax)
  13:  0f 29 40 10     movaps %xmm0, 0x10(%rax)
```

**This is correctness, not performance.** A kernel that never touches XMM may defer saving FPU
state, and `oscortex_core` does exactly that — `procYield` saves it hundreds of instructions after
entry (ADR-0015 §2). That is sound *only* while the kernel never touches XMM. Once the compiler puts
SSE into `chanInit`/`elfInit`, a preempted process can have its FPU state corrupted by kernel code
that never asked for a floating-point register.

It is the same shape as ADR-0039's red zone, and the resemblance is the useful part: **an
optimization entirely legitimate in a hosted process and silently fatal in a kernel, fixed by a flag
derived from the target rather than passed by hand.** That is now twice. A third instance should be
expected rather than surprising, and the general form is *"the freestanding target is not a smaller
hosted target; it is a different contract."*

## Decision

**Freestanding targets pass `-mgeneral-regs-only`.** Derived from `DCTarget.isFreestanding`, exactly
as `-mno-red-zone` is derived from `forbidsRedZone`.

**`dcc build --allow-fp` opts out**, for a `@bare` program that genuinely wants floating point.

### Which flag, measured rather than reasoned

The first fix attempted here was `-fno-vectorize -fno-slp-vectorize`, on the theory that this was the
loop vectorizer. **That theory was wrong, and the measurement is why it was not shipped:**

| flag | `xmm` count |
|---|---|
| (baseline) | 9 |
| `-fno-vectorize -fno-slp-vectorize` | **5** — insufficient |
| `-mprefer-vector-width=0` | 9 — no effect at all |
| `-mgeneral-regs-only` | **0** |

Disabling the vectorizers leaves the `memset` that loop-idiom recognition forms, which is then
expanded with vector stores. Only forbidding the register class removes all of it.

### The cost, stated rather than buried

**On x86-64, using a float *means* using xmm.** So this makes `@bare` floating point unavailable by
default. That is the honest position rather than a limitation: a `@bare` program using FP has taken
on an FPU-state obligation its host kernel may not know about, and `--allow-fp` is where it says so
out loud.

### The default fails loudly, and at the right check

Without `--allow-fp`, a `@bare` float program compiles to **soft-float libcalls** — zero `xmm`, but
undefined `__adddf3`, `__divdf3`, `__eqdf2`. `verify-freestanding.sh` rejects those by name:

```
FREESTANDING: FAIL  f.o
  _adddf3  -> undefined, not allowlisted, and not declared @extern in the source.
```

So rule 1's spine catches it. **The allowlist is deliberately not grown to accommodate soft-float** —
that is precisely the "do NOT add to the allowlist to make this pass" its own header forbids, and the
allowlist is owned by E4 rather than by whoever is inconvenienced.

The float conformance targets encode both halves: one asserts the **refusal** (no `--allow-fp` →
soft-float object → the spine check must fail, and the test fails if that rejection ever stops
happening), and one asserts the opt-in build is freestanding-green. The first is the safety property
and is the one that would otherwise rot.

## Consequences

- **`@bare` float examples must pass `--allow-fp`.** Their hosted benchmark builds are unaffected;
  only freestanding is restricted.
- **`no-red-zone`'s sweep builds every example for `bare-x86_64`**, so a float example without the
  flag is reported there as a skip with a note rather than a pass. That is correct — it genuinely
  cannot be built for a target that forbids FP — but it means the skip count is now load-bearing
  information rather than noise.
- **This does not make `@bare` FP *safe*, only *deliberate*.** A program that passes `--allow-fp` and
  runs inside a kernel that defers FPU save is still wrong; the flag moves the decision from the
  optimizer to the author, which is all a compiler flag can do. The real fix is spec §6's
  `@interrupt`/FPU-state discipline, which is a language question rather than this ADR's.
- **A verification gap, stated rather than hidden:** the full conformance suite could not be run when
  this landed. `dc-elide/lib/elide.dart` did not compile — another session's in-flight edit,
  unrelated to and untouched by this change, taking 28 of 46 targets down with a single Dart type
  error. What *was* verified: the reproduction goes 3 `xmm` → 0, hosted builds are unaffected, the
  float example emits 77 `xmm` with the flag and soft-float libcalls without it, and the spine check
  rejects the latter. The suite must be re-run once that tree settles, and if this commit broke
  something the suite would have caught, that is on this commit.
