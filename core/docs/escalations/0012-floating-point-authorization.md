# Escalation 0012: floating point (f32/f64) — owner-authorized §4.1 change, record of the decision

**Raised by:** project NEON needing float ML kernels (matmul/softmax/layernorm over `Pointer<f32>`
buffers) — the first real consumer of the `f32 f64` line spec §4.1 has carried since M0.
**Area:** spec §4.1 (integers/sized types) — on CLAUDE.md's escalation list ("any change to …
§4.1"), which is why this record exists even though the answer arrived before the work started.
**Blocking:** nothing. **Resolved:** the owner authorized the change in-session on **2026-08-27**,
before implementation began. This file records what was asked, the options weighed, and what was
actually built, so the authorization is greppable and not folklore.

## Why this needed authorization at all

CLAUDE.md's escalation policy names §4.1 by name. Implementing floats is not literally an *edit* to
§4.1's type list — `f32 f64` were already in it — but it decides everything §4.1 left unsaid about
them (trap behavior, conversion rules, whether `/` exists, NaN semantics), it half-supersedes an
ADR that said "no floating point … remain deliberate" (ADR-0036), and it adds the first non-integer
scalar to a compiler whose every arithmetic decision so far leaned on the integer model. That is
"change the language", not "change this code", so it was escalated rather than decided by an agent.

## Options considered

1. **Defer floats again; write NEON's kernels in C behind `@extern`.** Zero language risk, and the
   FFI already works (ADR-0038). Rejected: it makes DCDart a scripting layer over the exact code it
   exists to replace, the kernels are the M4-era workload, and every future float user would pay
   the same toll.
2. **f64 only** (Dart's native double; smallest surface). Rejected: ML buffers are f32 — half the
   memory bandwidth is the point — and an f64-only language would make `Pointer<f32>` unwritable,
   which is the actual requirement.
3. **Full float support: f32+f64 extension types, `+ - * /`, ordered comparisons, unary minus, the
   six natural conversions, `Pointer<f32>`/`Pointer<f64>` load/store — no transcendentals, no
   SIMD.** Chosen, with the semantics decisions recorded in ADR-0065 (IEEE-754, never traps,
   ordered/`une` comparisons, saturating float→int truncation, bit-exact constant emission,
   single-rounded f32 literals via `f32(x)`).

## What was authorized and what was implemented

The owner authorized option 3 on 2026-08-27. Implemented the same day, end to end in one unit of
work: prelude `f32`/`f64` + `u32.toF32()`/`u64.toF64()`; DC-IR `ConstFloat`/`FAdd`/`FSub`/`FMul`/
`FDiv`/`FNeg`/`FCmp`/`FConvert`; lowering (operators, literals, `==`/`!=`, float locals as
reassignable/loop-carried scalars, `Pointer<fN>` via the existing pointee mechanism); backend
codegen (hardware float only, `llvm.fptoui.sat` for truncation, bitcast-bits constants); C headers
(`float`/`double`); conformance targets `float-arith` and `float-pointer` plus examples
`m4-float-arith` and `m4-float-dot`; spec §4.1 float subsection; ADR-0065; GAP-0063 for the
deliberate leftovers (transcendentals, SIMD, `Pointer<T>` in signatures, float `@rodata`, bare
float literals).

Integer `/` remains absent and `~/` unchanged — ADR-0036's integer half was explicitly NOT part of
the authorization.

## Verification

Both new conformance targets pass on the dev host (bit-exact against C, NaN/inf/-0.0 IEEE checks,
saturation checks, per-element stride probes, `dc_heap_live` back to zero per call), both examples
build for `bare-x86_64` and pass `verify-freestanding.sh` (no soft-float/conversion libcalls), and
all 41 previously-passing targets still pass.
