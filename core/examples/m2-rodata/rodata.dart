// M2 target for static read-only data (docs/decisions/0040-static-rodata.md).
//
// Shaped after the real consumer: oscortex_core needs to walk a table of
// physical-memory-map entries through a raw `Pointer<u64>`. So the table
// here is read the way a kernel reads one -- by address plus stride -- not
// by any list API, because there is no list API and there is no header in
// front of the data.
//
// The spelling is `final` with an explicitly `const` initializer, and both
// halves are load-bearing (see the ADR): `const` on the initializer makes
// the contents compile-time known; `final` on the field keeps the
// declaration's identity and keeps the NAME alive at use sites, since a
// `const` field's references are inlined by the frontend.
import '../../runtime/dc-core-bare/prelude.dart';

/// Base addresses, in the shape a Multiboot memory map would have.
@rodata
final List<u64> regionBase = const [
  u64(0x100000),
  u64(0x200000),
  u64(0x400000),
  u64(0x800000),
];

/// Lengths, parallel to `regionBase`.
@rodata
final List<u64> regionLength = const [
  u64(0x100000),
  u64(0x200000),
  u64(0x400000),
  u64(0x1000000),
];

/// A narrower table, to prove element width comes from the declared type.
@rodata
final List<u32> regionType = const [u32(1), u32(2), u32(1), u32(1)];

/// A u8 table -- the tightest stride, where any hidden header or padding
/// would show up immediately.
@rodata
final List<u8> flags = const [u8(0xDE), u8(0xAD), u8(0xBE), u8(0xEF)];

/// A table of ADDRESSES of the other tables — internal relocations, inside
/// the identity-preserving `final` form. Reachable because a `const`
/// initializer, which cannot REFERENCE a `final` field, can still contain a
/// const string that NAMES one (ADR-0040).
@rodata
final List<Ref> tableDirectory = const [
  Ref('regionBase'),
  Ref('regionLength'),
  Ref('regionType'),
];

/// A RECORD -- the shape a type descriptor wants, mixing a relocation with
/// an integer. Not expressible as an array at any width, because an LLVM
/// array is homogeneous (GAP-0031).
class RegionDesc {
  final Ref bases;
  final u32 count;
  final Ref lengths;
  const RegionDesc(this.bases, this.count, this.lengths);
}

@rodata
final RegionDesc regionDesc =
    const RegionDesc(Ref('regionBase'), u32(4), Ref('regionLength'));

const int _u64Stride = 8;
const int _u32Stride = 4;
const int _u8Stride = 1;
const int _regionCount = 4;

@bare
u64 baseAt(u64 i) {
  final p = Pointer<u64>.fromAddress(
    Rodata.addressOf(regionBase) + i * u64(_u64Stride),
  );
  return p.value;
}

@bare
u64 lengthAt(u64 i) {
  final p = Pointer<u64>.fromAddress(
    Rodata.addressOf(regionLength) + i * u64(_u64Stride),
  );
  return p.value;
}

@bare
u32 typeAt(u64 i) {
  final p = Pointer<u32>.fromAddress(
    Rodata.addressOf(regionType) + i * u64(_u32Stride),
  );
  return p.value;
}

@bare
u8 flagAt(u64 i) {
  final p = Pointer<u8>.fromAddress(
    Rodata.addressOf(flags) + i * u64(_u8Stride),
  );
  return p.value;
}

/// Sums every region length -- a real loop over static data, which is what
/// a physical memory manager actually does with this table.
@bare
u64 totalUsable() {
  var i = u64(0);
  var total = u64(0);
  while (i < u64(_regionCount)) {
    if (typeAt(i) == u32(1)) {
      total = total + lengthAt(i);
    }
    i = i + u64(1);
  }
  return total;
}

/// Proves two DISTINCT tables have DISTINCT addresses. `regionBase` and
/// `regionLength` share their first element by value; if the compiler ever
/// merged byte-identical globals, or if the frontend canonicalized these
/// two declarations together, this would return 0.
@bare
u64 tablesAreDistinct() {
  if (Rodata.addressOf(regionBase) == Rodata.addressOf(regionLength)) {
    return u64(0);
  }
  return u64(1);
}

/// Reads the directory's Nth entry -- a pointer-sized word the LINKER filled
/// in with another table's address -- and dereferences it. Proves the
/// relocation resolved to the right symbol, not merely that a word is there.
@bare
u64 viaDirectory(u64 tableIndex, u64 elementIndex) {
  final slot = Pointer<u64>.fromAddress(
    Rodata.addressOf(tableDirectory) + tableIndex * u64(_u64Stride),
  );
  final target = Pointer<u64>.fromAddress(
    slot.value + elementIndex * u64(_u64Stride),
  );
  return target.value;
}

/// Reads a word of the descriptor record. Word 0 is the relocated pointer to
/// `regionBase`, word 1 packs the u32 count with its padding, word 2 is the
/// relocated pointer to `regionLength` -- natural C layout for
/// `{ptr, u32, ptr}`.
@bare
u64 descWord(u64 i) {
  final p = Pointer<u64>.fromAddress(
    Rodata.addressOf(regionDesc) + i * u64(_u64Stride),
  );
  return p.value;
}

/// Follows the descriptor's FIRST relocated pointer and reads through it,
/// proving the relocation resolved to `regionBase` rather than merely being
/// a non-zero word.
@bare
u64 viaDescriptor(u64 elementIndex) {
  final slot = Pointer<u64>.fromAddress(Rodata.addressOf(regionDesc));
  final target = Pointer<u64>.fromAddress(
    slot.value + elementIndex * u64(_u64Stride),
  );
  return target.value;
}
