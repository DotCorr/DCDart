// M2 target for MUTABLE STATIC STORAGE (docs/decisions/0051-mutable-statics.md).
//
// The third subsystem oscortex_core built could read a disk and had nowhere
// to put what it read; the same was true of its memory map and its PCI scan.
// This is the storage those need.
//
// `@bss` is restricted to raw zero-initialized bytes on purpose, and the
// restriction is what makes it decidable at all: a global holding an
// ARC-managed reference would be an ARC root, needing retain/release
// semantics, a lifetime and thread-safety -- DCDART_SPEC.md §3 questions that
// CLAUDE.md rule 4 freezes. Bytes raise none of them.
import '../../runtime/dc-core-bare/prelude.dart';

@bss final Bss tickCounter = const Bss(bytes: 8);
@bss final Bss idt = const Bss(bytes: 4096, align: 4096);
@bss final Bss frameBitmap = const Bss(bytes: 4096);

/// State that PERSISTS across calls -- the property nothing else in DCDart
/// has. Zero-initialized, so the first bump yields 1.
@bare
u64 bumpTicks() {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
  p.value = p.value + u64(1);
  return p.value;
}

@bare
u64 writeAndReadBitmap(u64 index, u64 value) {
  final p = Pointer<u64>.fromAddress(Bss.addressOf(frameBitmap) + index * u64(8));
  p.value = value;
  return p.value;
}
