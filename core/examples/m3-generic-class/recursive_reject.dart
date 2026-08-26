// NEGATIVE fixture for ADR-0054's instantiation bound. This file is MEANT
// NOT TO COMPILE; the conformance harness asserts the refusal.
//
// GAP-0040 recorded that recursion through a type parameter -- `f<T>` calling
// `f<Something<T>>` -- would queue specializations forever, and recorded it
// rather than guarding it because generic classes did not exist to build the
// infinite type with. They do now, and this is that program: every call to
// `deep` instantiates `Box` one level deeper, so the set of specializations
// it needs is infinite. Monomorphization has no finite answer, and the only
// correct behaviours are to reject it or to hang. It must reject it.
import '../../runtime/dc-core-bare/prelude.dart';

class Box<T> extends HeapObject {
  final T value;
  Box(this.value);
}

@bare
u64 deep<T>(Box<T> b) => deep<Box<T>>(Box<Box<T>>(b));

@bare
u64 start(u64 v) => deep<u64>(Box<u64>(v));
