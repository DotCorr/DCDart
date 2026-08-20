// FFI-extern conformance target, part 2 of 2
// (docs/decisions/0038-extern-symbols-and-linking.md).
//
// Part 1 (`extern_calls.dart`) calls C that this project wrote. That proves
// the mechanism, but a companion `.c` written by the same person who wrote
// the DCDart side can agree with it by accident. This file calls REAL LIBC —
// symbols nobody in this project controls, compiled by someone else, years
// ago, against a published ABI. If the declaration, the relocation or the
// calling convention is wrong, there is nothing here to compensate for it.
//
// Built with `--target host` (ADR-0033) and linked with plain `clang` against
// the system libc — no `-nostdlib`, no entry stub. `--mode bare --target
// host` is a legitimate combination: it means "the bare language subset,
// emitted as a native object", NOT that spec §2's `@hosted` mode exists.
//
// This file deliberately does NOT link freestanding — it cannot, it needs
// libc. That is the point of keeping it separate from `extern_calls.dart`,
// which does, and which is the configuration oscortex_core needs.
//
// SIGNEDNESS, stated rather than glossed: every function below is `int`-typed
// in C, and DCDart has no signed sized-integer type yet (spec §4.1 lists
// `i8`..`i64` but the prelude implements only the unsigned half). `u32` and
// C's `int` are the same 32-bit register operand on both SysV-AMD64 and
// AAPCS64 — they differ only in how the VALUE is interpreted — so every call
// here is ABI-correct, and every value used is inside 0..2^31-1 where the two
// interpretations agree. A signed sized-int type is tracked in
// docs/known-gaps.md, not papered over here.
import '../../runtime/dc-core-bare/prelude.dart';

/// `int ffs(int)` — index of the least-significant set bit, 1-based, 0 for 0.
/// POSIX; present in glibc and in macOS's libSystem. Chosen because its
/// answers are exactly known and non-obvious: ffs(40) == 4, not 40.
@extern
external u32 ffs(u32 mask);

/// `int toupper(int)` — C89, everywhere. Chosen as a second, independent
/// libc symbol with a completely different implementation, so a single
/// misbehaving symbol cannot be mistaken for the mechanism working.
@extern
external u32 toupper(u32 c);

/// `int putchar(int)` — C89. Not a value check: an OBSERVABLE SIDE EFFECT
/// outside this process's memory. The harness captures stdout and compares
/// the bytes, so this proves the call really reached libc rather than being
/// constant-folded into a plausible-looking return value.
@extern
external u32 putchar(u32 c);

/// `ffs` through DCDart.
@bare
u32 lowestSetBit(u32 mask) => ffs(mask);

/// `toupper` through DCDart.
@bare
u32 upper(u32 c) => toupper(c);

/// Writes "DCDART\n" to stdout one byte at a time through real `putchar`,
/// then returns the number of bytes written. Each `putchar(...)` here is a
/// value-returning call bound to a local, since a discarded non-void result
/// is refused (ADR-0038: discarding could leak under the naive release
/// policy, so there is one rule rather than two).
@bare
u32 shout() {
  final a = putchar(u32(68)); // 'D'
  final b = putchar(u32(67)); // 'C'
  final c = putchar(u32(68)); // 'D'
  final d = putchar(u32(65)); // 'A'
  final e = putchar(u32(82)); // 'R'
  final f = putchar(u32(84)); // 'T'
  final g = putchar(u32(10)); // '\n'
  // Sum the echoed characters back: putchar returns the character written,
  // so this also checks the RETURN path of every one of those seven calls,
  // not just that they happened.
  return a + b + c + d + e + f + g;
}

/// A libc call inside a `while` loop, accumulating a real computed answer:
/// the sum of ffs(i) for i in 1..upTo.
@bare
u32 sumLowestSetBits(u32 upTo) {
  var i = u32(0);
  var total = u32(0);
  while (i < upTo) {
    i = i + u32(1);
    total = total + ffs(i);
  }
  return total;
}
