// M2 target for ATOMIC READ-MODIFY-WRITE on mutable statics
// (docs/decisions/0055-atomics.md, known-gaps GAP-0039).
//
// ADR-0051 gave DCDart mutable global storage and `oscortex_core` consumed it
// immediately. It gave no atomicity guarantee at all: `p.value = p.value +
// u64(1)` on a `@bss` counter is a load, an add and a store, and any of the
// three can be interleaved. The live case is the PIT interrupt handler
// incrementing a tick counter that the shell reads.
//
// The reason this is dangerous rather than merely missing: on one core,
// interrupt entry and exit serialize the sequence, so the WRONG code works.
// It stays working right up to the first second core, and then fails as a
// lost tick — which reads as a scheduler bug, not a language bug.
//
// `plainBumpTicks` below is kept deliberately, as the NEGATIVE CONTROL. It is
// byte-for-byte the shape `examples/m2-bss/bss.dart` ships today. The
// conformance harness disassembles both functions out of the same object and
// requires a `lock` prefix in the atomic one and NO `lock` prefix in the plain
// one. Without that pairing the test would prove nothing: both return the same
// values on a single core, which is the entire problem.
import '../../runtime/dc-core-bare/prelude.dart';

@bss final Bss tickCounter = const Bss(bytes: 8);
@bss final Bss frameBitmap = const Bss(bytes: 4096);
@bss final Bss lockWord = const Bss(bytes: 4);
@bss final Bss counter32 = const Bss(bytes: 4);

/// NEGATIVE CONTROL — the non-atomic read-modify-write GAP-0039 is about.
/// Correct on one core by accident, lost-update on two. Must compile to a
/// plain load/add/store with no `lock` prefix; the harness asserts that.
@bare
u64 plainBumpTicks() {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  p.value = p.value + u64(1);
  return p.value;
}

/// The fix. One indivisible `lock xadd`. Returns the NEW value, so it is
/// directly substitutable for `plainBumpTicks` at the call site — the kernel's
/// tick counter wants "what is the count now", not "what was it before".
@bare
u64 atomicBumpTicks() {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  final old = Atomic.fetchAdd(p, u64(1));
  return old + u64(1);
}

/// `fetchAdd` returns the value as it was BEFORE the add, matching every other
/// fetch-and-op in the industry (C11, LLVM, x86 `xadd`). Exposed directly
/// rather than only through `atomicBumpTicks` because a caller that wants
/// "claim slot N" needs the old value, not the new one.
@bare
u64 atomicFetchAddTicks(u64 delta) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  return Atomic.fetchAdd(p, delta);
}

@bare
u64 atomicFetchSubTicks(u64 delta) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  return Atomic.fetchSub(p, delta);
}

/// Atomic load/store of the same location. Not redundant with an ordinary
/// `p.value` read: a seq_cst load may not be duplicated, invented, or torn,
/// and a seq_cst store on x86-64 lowers to `xchg`, which is a full barrier.
@bare
u64 atomicLoadTicks() {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  return Atomic.load(p);
}

@bare
void atomicStoreTicks(u64 value) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  Atomic.store(p, value);
}

/// Setting one bit of a free-frame bitmap. GAP-0039 names "a corrupted bitmap
/// entry" as the other failure mode, and it is `fetchOr`, not `fetchAdd`: two
/// cores claiming two different frames in the same word lose one of the two
/// updates under a plain read-modify-write.
@bare
u64 atomicSetBit(u64 wordIndex, u64 mask) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(frameBitmap) + wordIndex * u64(8));
  return Atomic.fetchOr(p, mask);
}

@bare
u64 atomicClearBit(u64 wordIndex, u64 mask) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(frameBitmap) + wordIndex * u64(8));
  return Atomic.fetchAnd(p, mask);
}

@bare
u64 atomicFlipBit(u64 wordIndex, u64 mask) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(frameBitmap) + wordIndex * u64(8));
  return Atomic.fetchXor(p, mask);
}

/// Test-and-set: the minimal correct spinlock acquire. `exchange` is what
/// makes a lock expressible at all without compare-exchange (GAP-0041) —
/// swap 1 in, and you hold the lock iff what came out was 0.
@bare
u32 tryAcquireLock() {
  final p = Pointer<u32>.fromAddress(Bss.addressOf(lockWord));
  return Atomic.exchange(p, u32(1));
}

@bare
void releaseLock() {
  final p = Pointer<u32>.fromAddress(Bss.addressOf(lockWord));
  Atomic.store(p, u32(0));
}

/// Width coverage. u32 and u64 take different LLVM types and different x86
/// mnemonic suffixes; nothing else in this file would catch a backend that
/// hardcoded i64.
@bare
u32 atomicBump32() {
  final p = Pointer<u32>.fromAddress(Bss.addressOf(counter32));
  final old = Atomic.fetchAdd(p, u32(1));
  return old + u32(1);
}
