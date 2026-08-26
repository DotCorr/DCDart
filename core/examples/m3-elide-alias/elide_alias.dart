// GAP-0054 / ADR-0063: elision pass 3 could delete a retain/release pair
// across a `Release` of an ALIASING value, producing a use-after-free
// through `dcc build` at -O2.
//
// This file is the reproduction, kept as a permanent regression target.
// `tests/conformance/elide-alias/run.sh` builds it and asserts both the
// ARC counts and the returned values.
//
// WHY THIS BUG WAS INVISIBLE, which is the reason it is worth a target of
// its own rather than a line in an existing one:
//
//   * `dc_heap_live` reads ZERO across it. Cancelling a retain/release
//     pair is refcount-NEUTRAL -- the object is freed exactly once, just
//     far too early. Every leak test in the repo is blind to it, and the
//     leak test is the check M2 and M3 lean on hardest.
//   * The refcounts all balance. There is no double free to trap on.
//   * It needs -O2 and a recycled allocation to become a WRONG VALUE
//     rather than a stale-but-plausible one.
//
// So the only thing that catches it is asserting the value, on a program
// shaped to make the freed slot get reused before it is read.
import '../../runtime/dc-core-bare/prelude.dart';

class Node extends HeapObject {
  final u64 n;
  Node(this.n);
}

/// A cell with a MUTABLE, NON-NULLABLE heap field. Both properties matter,
/// and the nullable counterpart below shows why.
class Cell extends HeapObject {
  Node next;
  Cell(this.next);
}

class NCell extends HeapObject {
  Node? next;
  NCell(this.next);
}

// ---------------------------------------------------------------------------
// THE MISCOMPILATION. Returns 110. Before ADR-0063 it returned 198.
// ---------------------------------------------------------------------------

/// Walk the refcount of the `v`-Node, which is the whole story:
///
/// ```
///   var n = Node(v);        alloc            -> 1   (the local owns it)
///   final c = Cell(n);      field store      -> 2
///   n = Node(u64(0));       ADR-0048: releases the old local -> 1
///                                              c.next is now the SOLE owner
///   final got = c.next;     ADR-0017 alias retain -> 2
///   c.next = Node(u64(1));  ADR-0048: releases the old field value -> 1
///   final other = ...       (see below)
///   return got.n;           reads through `got`
///   <function exit>         _releaseHeapLocals releases `got` -> 0, freed
/// ```
///
/// Pass 3 saw `Retain got ... Release got` with no release OF `got` in
/// between, and deleted both. But `Release` of the old FIELD value and
/// `Retain got` name the same runtime object under two different
/// DCValues, so with the pair gone the count reads 1 -> 0 at
/// `c.next = Node(u64(1))`: the object is freed while `got` still points
/// at it, and `got.n` two lines later is a read of freed memory.
///
/// `Node(u64(198))` exists to make that read OBSERVABLE. It allocates
/// after the premature free, takes the just-freed slot off the free list,
/// and writes 198 over the payload -- so the bug reports itself as a
/// wrong number instead of a stale right one.
@bare
u64 aliasBug(u64 v) {
  var n = Node(v);
  final c = Cell(n);
  n = Node(u64(0));
  final got = c.next;
  c.next = Node(u64(1));
  final other = Node(u64(198));
  return got.n;
}

/// The SAME program with a nullable field, which did NOT reproduce -- and
/// the reason is worth recording next to the reason the original one was
/// safe for so long, because it is the same kind of accident.
///
/// A nullable heap field cannot be dereferenced without a null test, and
/// that test is a `CondBranch`: it ends the basic block. Pass 3 is
/// single-block by construction, so the retain and its matching release
/// land in different blocks and the pair was never a candidate at all.
///
/// Nothing about nullability made this safe. A control-flow edge happened
/// to sit between the retain and the release. Take the edge away -- which
/// is exactly what making the field non-nullable does -- and the pair
/// becomes elidable again.
@bare
u64 aliasBugNullable(u64 v) {
  var n = Node(v);
  final c = NCell(n);
  n = Node(u64(0));
  final got = c.next;
  c.next = Node(u64(1));
  final other = Node(u64(198));
  if (got == null) {
    return u64(0);
  }
  return got.n;
}

// ---------------------------------------------------------------------------
// POSITIVE CONTROL. Pass 3 must still fire.
//
// The fix's failure mode is not a wrong answer, it is a silent no-op:
// invalidate too eagerly and every pair survives, every correctness test
// still passes, and every benchmark quietly gets slower. This is
// `examples/m2-alias`'s canonical shape -- a local alias whose retain
// reaches its OWN release with no release of anything else in between --
// and the conformance target asserts its retain count is ZERO. A fix that
// worked by turning pass 3 off fails here.
// ---------------------------------------------------------------------------

@bare
u64 stillElided(u64 v) {
  final b = Node(v);
  final b2 = b;
  return b2.n;
}

// ---------------------------------------------------------------------------
// NEGATIVE CONTROL for the OTHER direction, and the one that is easy to
// mistake for over-conservatism.
//
// `c` is a `Cell`, so `Release c` runs `Cell_dtor`, and `Cell_dtor`
// releases `c.next` -- the very object `got` aliases. The pair here is
// therefore NOT safe to cancel, and it is the exact shape GAP-0054 was
// first noticed in (`boxNode`, in `examples/m3-generic-class`). It was
// safe there only because the field read is lowered before
// `_releaseHeapLocals` emits anything, so the freed object was never read
// again. This target asserts the pair SURVIVES, so that the safety stops
// depending on that ordering.
//
// NOTE the `final n = ...` local, which is load-bearing for the LEAK check
// rather than for the elision. Writing it as `Cell(Node(v))` -- passing a
// freshly-allocated temporary straight into a borrowed constructor
// parameter -- leaks exactly one object per call, on this commit and on
// every commit before it. That is GAP-0065, it is nothing to do with
// elision (it reproduces identically with pass 3 disabled), and binding
// the local keeps it out of this target so that a failure here means what
// the target says it means.
// ---------------------------------------------------------------------------

@bare
u64 releaseThroughDestructor(u64 v) {
  final n = Node(v);
  final c = Cell(n);
  final got = c.next;
  return got.n;
}
