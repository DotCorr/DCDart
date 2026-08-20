// FFI-header conformance target (docs/decisions/0034-c-header-emission.md).
//
// The point of this target is NOT that DCDart emits C-ABI object files --
// that has been true since M0 (core/backend/m0-target.md §1: no dso_local,
// no custom calling convention), and examples/demo-collatz already links
// against a hand-written `extern uint64_t collatzSteps(uint64_t);`. The
// point is that the caller no longer has to hand-write that line. A
// hand-written prototype that disagrees with the real ABI is not a compile
// error, it is silent corruption at the boundary; `--emit-header` derives
// the declarations from the same DC-IR the object file is emitted from, so
// the two cannot drift.
//
// This file therefore deliberately spans a RANGE of ABI shapes rather than
// the easy uint64_t-in/uint64_t-out case, because a generator that only
// ever gets exercised on one shape proves nothing about the others:
//
//   * u64 in / u64 out          -> uint64_t          (the register-width case)
//   * u32 / u16 / u8 in and out -> uint32_t/16_t/8_t (proves the width table
//                                  in c_header.dart's DCInt branch is really
//                                  keyed off IntWidth, not hardcoded to 64)
//   * Result returned BY VALUE  -> a C struct returned by value, the shape
//                                  most likely to be got wrong by hand: it
//                                  is two registers on both SysV-x86-64 and
//                                  AAPCS64, and a caller who guessed at
//                                  `uint64_t` instead would read back
//                                  garbage with no diagnostic anywhere
//                                  (see docs/known-gaps.md GAP-0007, where
//                                  exactly this ABI question had to be
//                                  settled empirically).
//   * zero arguments            -> must be declared `f(void)`, not `f()`.
//                                  In C, `f()` means "unspecified argument
//                                  list" and type-checks a call with ANY
//                                  arguments -- so an empty list would hand
//                                  the caller back the same silent-mismatch
//                                  hole this feature exists to close.
//
// Companion harness: examples/ffi-header/main.c includes ONLY the generated
// header and declares no `extern` of its own; the conformance script is
// tests/conformance/ffi-header/run.sh.
import '../../runtime/dc-core-bare/prelude.dart';

/// u64 in, u64 out -- the register-width baseline. Header must say
/// `uint64_t ffiAddU64(uint64_t a0, uint64_t a1);`.
@bare
u64 ffiAddU64(u64 a, u64 b) => a + b;

/// Two u64 params and a u64 return, but doing enough work (multiply,
/// divide, remainder) that a wrong-width prototype would be visible in the
/// result rather than accidentally agreeing on small values.
@bare
u64 ffiMixU64(u64 a, u64 b) => a * b + a ~/ b + a % b;

/// u32 in / u32 out. Header must say uint32_t, not uint64_t: on AAPCS64 a
/// u32 return leaves the upper 32 bits of x0 unspecified, so a caller who
/// declared this uint64_t could read nonzero garbage in the high half.
@bare
u32 ffiAddU32(u32 a, u32 b) => a + b;

/// u16 in / u16 out -- proves IntWidth.w16 -> uint16_t.
@bare
u16 ffiMaskU16(u16 a, u16 b) => (a & b) | (a ^ b);

/// u8 in / u8 out -- proves IntWidth.w8 -> uint8_t.
///
/// NARROW-RETURN CAVEAT, stated here rather than hidden in the harness: the
/// backend keeps u8/u16 values in 32-bit registers and does NOT truncate to
/// the declared width on return (disassembly of this very function on
/// macos-arm64: `lsl w8, w0, w8` then `ret`, with no `and w0, w0, #0xff`).
/// So a shift that overflows 8 bits returns a register whose upper bits are
/// set, while the generated -- and correct -- `uint8_t` prototype tells the
/// caller the callee already extended it, which is what both AAPCS64/Apple
/// arm64 and SysV x86-64 require of a narrow return. main.c therefore
/// exercises this only with shift amounts whose mathematical result fits in
/// 8 bits. That is a real backend defect, NOT a header-emission one (the
/// header's uint8_t is the honest spelling; the object file is the side
/// that is wrong), and it is out of this unit's editable scope -- fixing it
/// means touching core/backend's shared lowering. Reported, not papered
/// over: the harness does not assert the buggy value as if it were correct.
@bare
u8 ffiShiftU8(u8 a, u8 shift) => a << shift;

/// Mixed widths in one signature, so the generator has to map each
/// parameter independently rather than reusing the return type's spelling.
@bare
u32 ffiWidenU8ToU32(u8 low, u32 high) => high + u32(0);

/// Result returned BY VALUE (ADR-0014: `{tag: u64, payload: u64}`, tag 0 =
/// Ok, tag 1 = Err). This is the struct-ABI case. `> u64(0)` picks the Ok
/// branch; both branches return, so nothing falls through.
@bare
Result ffiCheckPositive(u64 value) {
  if (value > u64(0)) {
    return Result.ok(value);
  }
  return Result.err(u64(999));
}

/// Same struct-return shape, but reached through `.propagate()` (the named
/// stand-in for `?`, docs/escalations/0001-question-mark-syntax.md). The Ok
/// path continues with the unwrapped payload; the Err path returns the
/// whole Result straight out of this function, so the C caller sees the
/// error tag propagated across the ABI boundary unchanged.
@bare
Result ffiDoubleChecked(u64 value) {
  final unwrapped = ffiCheckPositive(value).propagate();
  return Result.ok(unwrapped + unwrapped);
}

/// Guaranteed-Err propagation, so the harness can check the Err path of
/// `.propagate()` independently of the branch in ffiCheckPositive.
@bare
Result ffiAlwaysErr(u64 code) {
  final unwrapped = Result.err(code).propagate();
  return Result.ok(unwrapped);
}

/// ZERO arguments. The header must declare this `uint64_t ffiConstant(void);`
/// -- an empty `()` in C is a pre-C23 "unspecified arguments" declaration
/// that would silently accept `ffiConstant(1, 2, 3)`.
@bare
u64 ffiConstant() => u64(2718281828);

/// A second zero-argument function at a narrower width, so `(void)` is
/// proven to be a property of the emitter's empty-parameter path and not an
/// accident of this one declaration's return type.
///
/// 127 and not, say, 200, for the narrow-return reason spelled out on
/// ffiShiftU8 above -- and here it bites even without any arithmetic. A u8
/// literal is materialized as a SIGN-extended i8 in a 32-bit register
/// (`u8(200)` compiles to `mov w0, #-0x38` on macos-arm64, i.e. 0xFFFFFFC8)
/// and is returned without being narrowed, so a C caller reading the
/// generated -- and correct -- `uint8_t` prototype gets 0xFFFFFFC8 back
/// instead of 200. Any u8 >= 0x80 or u16 >= 0x8000 originating inside
/// DCDart hits this. Backend defect, not a header defect; out of this
/// unit's editable scope; reported rather than asserted-as-correct.
@bare
u8 ffiConstantU8() => u8(127);
