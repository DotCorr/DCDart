// M3 prerequisite: GENERIC CLASSES, monomorphized
// (docs/decisions/0054-generic-classes.md, extending
// docs/decisions/0052-monomorphization.md; closes docs/known-gaps.md
// GAP-0040).
//
// ADR-0052 monomorphized generic FUNCTIONS. A generic function only needs
// its signature types resolved; a generic CLASS needs a per-instantiation
// field LAYOUT, a per-instantiation DESTRUCTOR, and therefore a
// per-instantiation ARC shape. That is what this target exists to prove,
// and the three instantiations below are chosen so that no two of them
// agree on any of the three:
//
//   Box<u64>   payload 8 bytes, scalar field, NO destructor
//   Box<u32>   payload 4 bytes, scalar field, NO destructor
//   Box<Node>  payload 8 bytes, HEAP field,   destructor Box$Node_dtor
//
// `Box<u64>` and `Box<Node>` are the pair that matters most: identical
// payload size, and an implementation that keyed layout on size rather than
// on the type argument would pass every value check while getting the ARC
// wrong -- `Box<Node>`'s field must be released when the box dies, and
// `Box<u64>`'s must not be touched at all. A destructor emitted for
// `Box<u64>` would release a u64 as if it were a pointer.
import '../../runtime/dc-core-bare/prelude.dart';

/// The template. `T` has no size, so `Box` itself has no layout, no
/// payload size, no destructor and no machine representation of any kind.
/// Nothing is emitted for it -- assert that in the symbol table, not here.
class Box<T> extends HeapObject {
  final T value;
  Box(this.value);

  /// An instance method on a generic class: one specialization per
  /// instantiation, not one shared body (`Box$u64_unwrap`, ...).
  T unwrap() => value;
}

/// A plain, non-generic HeapObject, used as a type ARGUMENT so that one
/// instantiation of `Box` genuinely holds an ARC'd reference.
class Node extends HeapObject {
  final u64 n;
  Node(this.n);
}

// ---------------------------------------------------------------------------
// Value-type instantiations. No destructor may exist for either of these.
// ---------------------------------------------------------------------------

@bare
u64 boxU64(u64 v) {
  final b = Box<u64>(v);
  return b.unwrap();
}

@bare
u32 boxU32(u32 v) {
  final b = Box<u32>(v);
  return b.unwrap();
}

/// Direct FIELD read through a generic receiver, rather than through a
/// method -- the field's offset and width come from the instantiation's
/// layout, so this is a different code path from `unwrap()` above.
@bare
u64 boxU64Field(u64 v) {
  final b = Box<u64>(v);
  return b.value;
}

@bare
u32 boxU32Field(u32 v) {
  final b = Box<u32>(v);
  return b.value;
}

// ---------------------------------------------------------------------------
// The reference-type instantiation. This one has a destructor, and dropping
// the box must cascade into releasing the Node it holds.
// ---------------------------------------------------------------------------

@bare
u64 boxNode(u64 v) {
  final n = Node(v);
  final b = Box<Node>(n);
  final got = b.unwrap();
  return got.n;
}

/// Two live instantiations of the same generic class in ONE function, so the
/// two layouts have to coexist rather than the last one winning.
@bare
u64 boxBoth(u64 a, u32 b) {
  final x = Box<u64>(a);
  final y = Box<u32>(b);
  return x.value + y.value.toU64();
}
