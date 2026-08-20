// FFI-extern conformance target, part 1 of 2
// (docs/decisions/0038-extern-symbols-and-linking.md).
//
// The INBOUND half of DCDART_SPEC.md §9: DCDart code calling a C-ABI symbol
// that is NOT defined in its own compilation unit. ADR-0034 solved the
// outbound half (C calls DCDart, via a generated header); this is the
// direction known-gaps.md GAP-0019 called "a new architectural concept dcc
// doesn't have at all today (it only ever emits one self-contained
// relocatable object per compilation unit)".
//
// Every `dcx_*` symbol below is defined in `c_side.c` and NOWHERE in this
// file. The object dcc emits therefore carries real undefined symbols with
// real relocations, and only becomes a program once the linker is handed
// `c_side.o` as well. That is the whole point: proving `dcc` output can be
// one object among several rather than a self-contained island.
//
// Deliberately paired with `libc_calls.dart`, which calls symbols nobody in
// this project wrote (real libc). This file is the one that also has to link
// FREESTANDING (`-nostdlib`, no libc at all), because that is what
// oscortex_core — the real downstream consumer — actually needs: calling a
// hand-written assembly or C helper from `@bare` DCDart with no runtime
// underneath.
//
// The `dcx_` prefix is not decoration: it keeps these names from colliding
// with anything in libc when the harness links the two together.
import '../../runtime/dc-core-bare/prelude.dart';

// ---------------------------------------------------------------------------
// Extern declarations. `@extern` + Dart's own `external` keyword; the Dart
// identifier IS the C symbol name (there is no @linkName -- nothing has
// needed a C name that isn't a legal Dart identifier, so it was not built).
// ---------------------------------------------------------------------------

/// Two u64 in, u64 out -- the register-width baseline case.
@extern
external u64 dcx_add(u64 a, u64 b);

/// ZERO arguments. Proves the empty-parameter path emits `declare i64
/// @dcx_answer()` and calls it correctly, rather than mismatching arity.
@extern
external u64 dcx_answer();

/// Narrower width, in and out. On AAPCS64 a u32 return leaves the upper 32
/// bits of x0 unspecified, so a backend that emitted `i64` here would read
/// back garbage in the high half with no diagnostic anywhere.
@extern
external u32 dcx_mix32(u32 a, u32 b);

/// u8 in / u8 out, the narrowest width.
@extern
external u8 dcx_clamp8(u8 value);

/// Mixed widths in one signature, so each parameter has to be mapped
/// independently rather than reusing the return type's spelling.
@extern
external u64 dcx_widen(u8 low, u32 mid, u64 high);

/// VOID return. This is the shape that made the statement-context call path
/// worth building at all (ADR-0018 recorded the gap; ADR-0029 punched a
/// single hardcoded hole in it for `Port.outb`): `void` is the single most
/// common return type in C, and a `Call` with a null `dest` had never been
/// reachable from source before this.
@extern
external void dcx_record(u64 value);

/// The by-value STRUCT case. `Result` is `{tag: u64, payload: u64}`
/// (ADR-0014), which is two registers on both SysV-AMD64 and AAPCS64. A
/// caller who guessed `uint64_t` here would read back garbage silently --
/// exactly the failure GAP-0007 had to settle empirically once already.
@extern
external Result dcx_checked(u64 value);

// ---------------------------------------------------------------------------
// @bare DCDart functions. These get real `define`s; the symbols above get
// real `declare`s.
// ---------------------------------------------------------------------------

/// The minimal case: a DCDart function whose entire body is a C call.
@bare
u64 addThroughC(u64 a, u64 b) => dcx_add(a, b);

/// Zero-argument extern, called from an expression position.
@bare
u64 answerThroughC() => dcx_answer();

/// u32 in / u32 out.
@bare
u32 mixThroughC(u32 a, u32 b) => dcx_mix32(a, b);

/// u8 in / u8 out.
@bare
u8 clampThroughC(u8 value) => dcx_clamp8(value);

/// Mixed-width arguments.
@bare
u64 widenThroughC(u8 low, u32 mid, u64 high) => dcx_widen(low, mid, high);

/// A void C call as a bare statement, followed by a value-returning one --
/// proving the two paths coexist in one body and that the void call's side
/// effect really happens (the harness reads the recorded value back).
@bare
u64 recordAndDouble(u64 value) {
  dcx_record(value);
  return dcx_add(value, value);
}

/// An extern call inside a real `while` loop (ADR-0028), so the call is not
/// merely straight-line: the loop-carried variable is threaded through a
/// block-parameter merge point and the C call sits inside the body.
/// `sumThroughC(n)` = 1 + 2 + ... + n.
@bare
u64 sumThroughC(u64 upTo) {
  var i = u64(0);
  var total = u64(0);
  while (i < upTo) {
    i = i + u64(1);
    total = dcx_add(total, i);
  }
  return total;
}

/// A `Result` produced BY C, propagated through DCDart's own `.propagate()`
/// (the named stand-in for `?`, escalations/0001). The Err path returns the
/// C-built error struct straight back out to the C caller unchanged; the Ok
/// path unwraps it and calls C again with the payload.
@bare
Result checkedThroughC(u64 value) {
  final unwrapped = dcx_checked(value).propagate();
  return Result.ok(dcx_add(unwrapped, unwrapped));
}

/// A DCDart function calling another DCDart function which calls C -- the
/// two call kinds composed, proving they lower through the same `Call`
/// instruction and compose with no extra plumbing.
@bare
u64 addThroughCTwice(u64 a, u64 b) => addThroughC(addThroughC(a, b), b);
