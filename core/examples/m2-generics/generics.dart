// M2 target for MONOMORPHIZED GENERICS (docs/decisions/0052-monomorphization.md).
//
// DCDART_SPEC.md §4.2 specifies monomorphization, and this implements it: a
// generic function is a TEMPLATE with no machine representation -- `T` has no
// size -- so nothing is emitted for it. One specialization per distinct type
// argument is emitted instead, discovered from call sites.
//
// `firstOfSecond` is the case worth a target: a generic calling ANOTHER
// generic, where the inner call's type argument is itself the outer's type
// parameter. That needs the substitution to thread through a call site rather
// than only being consulted at the top of a function.
import '../../runtime/dc-core-bare/prelude.dart';

@bare T pick<T>(T a, T b) => a;
@bare T second<T>(T a, T b) => b;

/// A generic calling ANOTHER generic -- the case that needs the substitution
/// to thread through a call site.
@bare T firstOfSecond<T>(T a, T b) => pick<T>(second<T>(a, b), a);

@bare u64 u64Pick(u64 a, u64 b) => pick<u64>(a, b);
@bare u32 u32Pick(u32 a, u32 b) => pick<u32>(a, b);
@bare u8  u8Pick(u8 a, u8 b) => pick<u8>(a, b);
@bare u64 chained(u64 a, u64 b) => firstOfSecond<u64>(a, b);
