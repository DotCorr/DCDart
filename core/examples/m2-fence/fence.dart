// M2 target for MEMORY BARRIERS (docs/decisions/0056-memory-barriers.md,
// known-gaps GAP-0033). DCDART_SPEC.md §6 lists `fence(Ordering.acquire)` in
// its required-primitives table; nothing implemented it.
//
// ORDERING, NOT ATOMICITY. This file deliberately contains no `Atomic.*` call,
// and ADR-0055 (atomics) deliberately contains no fence: they are two
// mechanisms and conflating them is how a memory model gets designed badly.
// A fence constrains the ORDER in which other accesses become visible. It
// makes no single access indivisible, and an atomic RMW orders nothing beyond
// itself.
//
// WHAT THIS FILE CAN AND CANNOT DEMONSTRATE, stated up front because the
// honest limit is unusual. On x86-64, TSO already provides acquire and
// release ordering in hardware, so `fence acquire`, `fence release` and
// `fence acq_rel` emit NO INSTRUCTION AT ALL. They are not decorative: they
// constrain the COMPILER, which is free to reorder these stores and loads
// without them. So the discriminating assertion for those three lives at the
// LLVM IR level, exactly as ADR-0041/GAP-0036 settled for `volatile`. Only
// `Ordering.seqCst` reaches the machine, as `mfence`, and only that one is
// asserted in the disassembly.
import '../../runtime/dc-core-bare/prelude.dart';

@bss final Bss sharedData = const Bss(bytes: 8);
@bss final Bss readyFlag = const Bss(bytes: 4);

/// The producer half of the publish/consume pair every driver writes: fill a
/// buffer, then set the flag that says the buffer is filled. The release fence
/// is what forbids the flag store from being hoisted above the data store —
/// without it, a consumer can observe `ready == 1` and read stale data, and on
/// x86 that reordering comes from the COMPILER, not the CPU.
@bare
void publish(u64 value) {
  final data = Pointer<u64>.fromAddress(Bss.addressOf(sharedData));
  data.value = value;
  fence(Ordering.release);
  final flag = Pointer<u32>.fromAddress(Bss.addressOf(readyFlag));
  flag.value = u32(1);
}

/// The consumer half. The acquire fence forbids the data load from sinking
/// above the flag load.
@bare
u64 consume() {
  final flag = Pointer<u32>.fromAddress(Bss.addressOf(readyFlag));
  final ready = flag.value;
  fence(Ordering.acquire);
  final data = Pointer<u64>.fromAddress(Bss.addressOf(sharedData));
  if (ready == u32(0)) {
    return u64(0);
  }
  return data.value;
}

/// `acqRel` — one fence where a critical section both ends and begins, e.g.
/// handing a lock straight from one holder to the next.
@bare
u64 handoff(u64 value) {
  final data = Pointer<u64>.fromAddress(Bss.addressOf(sharedData));
  data.value = value;
  fence(Ordering.acqRel);
  return data.value;
}

/// `seqCst` — the only ordering that costs a real instruction on x86-64
/// (`mfence`). Needed for the one case TSO does NOT give you for free: a
/// store to one location followed by a load of a DIFFERENT location, which
/// x86 is permitted to reorder (StoreLoad). Dekker's algorithm and every
/// seqlock reader depends on this.
@bare
u64 storeThenLoadOther(u64 value) {
  final flag = Pointer<u32>.fromAddress(Bss.addressOf(readyFlag));
  flag.value = u32(1);
  fence(Ordering.seqCst);
  final data = Pointer<u64>.fromAddress(Bss.addressOf(sharedData));
  final seen = data.value;
  return seen + value;
}

/// `compilerOnly` — no instruction on ANY target, by construction. Forbids the
/// compiler from moving accesses across it and nothing else. This is the
/// correct and sufficient barrier for `oscortex_core` as it exists TODAY:
/// single core, interrupts as the only concurrency, and interrupt entry is
/// itself a serializing event. Reaching for `seqCst` there buys an `mfence`
/// that does nothing; reaching for nothing at all is a real bug.
///
/// It is NOT sufficient at the first second core, and the ADR says so where a
/// kernel author will read it.
@bare
u64 compilerBarrierOnly(u64 value) {
  final data = Pointer<u64>.fromAddress(Bss.addressOf(sharedData));
  data.value = value;
  fence(Ordering.compilerOnly);
  return data.value;
}
