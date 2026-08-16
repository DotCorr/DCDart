// M1 exit criterion (ROADMAP.md), second clause: "defines a @packed struct
// matching a known C layout (verified byte-for-byte against a C
// reference)." See DCDART_SPEC.md §6's `PageTableEntry` example for the
// target shape (`@packed final class ... extends Struct`).
import '../../runtime/dc-core-bare/prelude.dart';

@packed
class Header extends Struct {
  const Header.fromAddress(u64 address) : super.fromAddress(address);

  // Getter/setter PAIRS, not stored fields -- see prelude.dart's header for
  // why (bodies are never executed; dcc-lower reads declaration order +
  // return type to compute @packed byte offsets). Field order here (a, b)
  // is the ABI: a at offset 0 (u8, 1 byte), b at offset 1 (u32, 4 bytes) --
  // no padding, matching main.c's `#pragma pack(1)` C reference exactly.
  u8 get a => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  set a(u8 v) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  u32 get b => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  set b(u32 v) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
}

@bare
void writeHeader(u64 address, u8 aVal, u32 bVal) {
  final h = Header.fromAddress(address);
  h.a = aVal;
  h.b = bVal;
}

@bare
u32 readHeaderB(u64 address) {
  final h = Header.fromAddress(address);
  return h.b;
}
