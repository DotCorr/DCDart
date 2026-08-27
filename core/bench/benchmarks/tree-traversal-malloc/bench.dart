// core/bench/benchmarks/tree-traversal/bench.dart
//
// M3 benchmark 3 of 5: a binary tree built, walked and dropped.
//
// This is the benchmark the arena made impossible (GAP-0050). A tree needs
// many objects ALIVE AT ONCE -- that is what distinguishes it from
// `arc-churn`, where one object is allocated and released per iteration and
// the heap never holds more than one. Under ADR-0015's 64-slot arena the
// deepest tree expressible had 63 nodes; this builds 2^14-1 = 16,383.
//
// WHY THIS SHAPE, since a benchmark's shape decides what it measures:
//
//   * BUILD-THEN-WALK-THEN-DROP, not build-and-drop-per-node. The whole tree
//     is live across the walk, so the allocator is exercised at its high-
//     water mark and every node's release happens through the destructor
//     cascade (ADR-0022) rather than one at a time in a loop.
//   * A RECURSIVE build and a RECURSIVE walk. This is the traversal M3 asks
//     for, and recursion is also where DCDart's ARC has to get the release
//     point right per frame -- the property `m2-recursion` tests for
//     correctness and this one prices.
//   * THE WALK RETURNS A CHECKSUM the C side computes identically. The
//     harness refuses to report a ratio if the two disagree, so a tree that
//     silently lost a subtree cannot produce a fast, wrong number.
//   * DEPTH IS FIXED and rounds are the parameter, so both sides allocate
//     exactly 2^14-1 nodes per round and neither can win by allocating less.
//
// WHY DEPTH 13 AND NOT DEEPER, since the first draft used 17 and TRAPPED. A
// `Node` is 24 bytes of fields, so with the 16-byte header it lands in the
// 64-byte size class, and a default 2 MiB region holds 2 MiB / 64 = 32,768
// blocks (ADR-0058). Depth 17 wants 262,143 nodes and dies of OOM -- a clean
// trap, correctly, but a dead benchmark.
//
// The heap is raisable with `--heap-region-bytes`, and this deliberately does
// NOT use it. A gate number should describe the configuration DCDart actually
// ships, not one tuned until the benchmark fits. Depth 13 is 16,383 nodes --
// 260x what ADR-0015's arena could hold, comfortably inside the default, and
// the same tree on both sides so neither is advantaged.
//
// The real finding stays on the record rather than being tuned away:
// **the default hosted heap holds 32,768 objects of this size per class.**
// That is a number anyone sizing a workload needs, and it is exactly the kind
// of thing that was invisible while the arena capped everything at 64.
//
// The C side does the natural C thing for this workload: a static arena
// pool, bump-allocated per node, dropped by resetting the cursor (rewritten
// 2026-08-27 -- the first baseline was malloc-per-node, which was 5x slower
// than natural C and made DCDart read as 2.2x faster than C; see kernel.c).
// That is what "overhead vs C" means -- a C programmer solving this does not
// refcount and does not free node-by-node, and the gap is DCDart's
// retain/release traffic plus the destructor cascade's per-node work, which
// is exactly what M3 is asking about.
import '../../../runtime/dc-core-bare/prelude.dart';

class Node extends HeapObject {
  u64 value;
  Node? left;
  Node? right;
  Node(this.value, this.left, this.right);
}

/// Builds a complete binary tree of [depth], numbering nodes as it goes.
/// Every node stays alive until the whole tree is dropped.
@bare Node build(u64 depth, u64 label) {
  if (depth == u64(0)) {
    return Node(label, null, null);
  }
  final l = build(depth - u64(1), label * u64(2));
  final r = build(depth - u64(1), label * u64(2) + u64(1));
  return Node(label, l, r);
}

/// Sums every node. The recurrence keeps intermediates well below 2^64 --
/// DCDart's arithmetic traps and the prelude has no wrapping operators to
/// opt out with, so an overflow here would abort the benchmark rather than
/// wrap like the C side.
@bare u64 walk(Node n) {
  var total = n.value % u64(1000003);
  final l = n.left;
  if (l != null) {
    total = total + walk(l);
  }
  final r = n.right;
  if (r != null) {
    total = total + walk(r);
  }
  return total % u64(1000000007);
}

/// Build a tree of `depth`, walk it, drop it. Repeated `rounds` times so the
/// measured region is long enough for the harness's 25 ms floor without
/// making a single tree so deep it measures the C stack.
@bare u64 benchKernel(u64 rounds) {
  var acc = u64(0);
  var i = u64(0);
  while (i < rounds) {
    final t = build(u64(13), u64(1));
    acc = (acc + walk(t)) % u64(1000000007);
    i = i + u64(1);
  }
  return acc;
}
