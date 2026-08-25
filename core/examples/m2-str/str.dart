// M2 target for STRING SLICES (docs/decisions/0053-string-slices.md).
//
// Spec §7's `Str`: a borrowed UTF-8 slice `{ptr, len}` by value, non-owning,
// with literals pointing into `.rodata`. No allocation, so it works in
// `@bare` before a heap exists -- which is the whole reason this type comes
// before spec §7's `String` and `StrBuf`, both of which need the allocator
// that spec §12's open decision 2 has not settled.
//
// `utf8Len` is the case worth having a target for: "héllo" is 6 BYTES and 5
// Dart UTF-16 code units. Spec §7 names that divergence the largest single
// source of semantic drift from upstream Dart, so it is asserted rather than
// described.
import '../../runtime/dc-core-bare/prelude.dart';

@bare u64 helloLen() => Str("hello").length;
@bare u64 emptyLen() => Str("").length;
/// "héllo" is 6 BYTES but 5 Dart code units -- the spec §7 divergence, tested.
@bare u64 utf8Len()  => Str("héllo").length;

/// Walks the bytes of a literal and sums them -- proves `address` reaches
/// real .rodata content, not just a plausible number.
@bare u64 sumBytes() {
  final s = Str("ABC");
  var total = u64(0);
  var i = u64(0);
  while (i < s.length) {
    final p = Pointer<u8>.fromAddress(s.address + i);
    total = total + p.value.toU64();
    i = i + u64(1);
  }
  return total;
}

/// Two identical literals must share one .rodata global (interning).
@bare u64 sameAddress() {
  final a = Str("shared");
  final b = Str("shared");
  if (a.address == b.address) { return u64(1); }
  return u64(0);
}
