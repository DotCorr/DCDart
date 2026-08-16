// M1 exit criterion (ROADMAP.md): "a @bare program reads and writes a
// memory-mapped register through Pointer<u32>." See DCDART_SPEC.md §6's
// `enableApic` example, which this mirrors in shape (construct a Pointer
// from a raw address, then load/store through `.value`).
import '../../runtime/dc-core-bare/prelude.dart';

@bare
u32 mmioRoundTrip(u64 address, u32 value) {
  final reg = Pointer<u32>.fromAddress(address);
  reg.value = value;
  return reg.value;
}
