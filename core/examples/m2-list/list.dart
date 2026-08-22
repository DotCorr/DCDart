// M2 target for MUTABLE DATA STRUCTURES (ADR-0048, ADR-0049).
//
// This is the first DCDart program that builds a data structure rather than
// computing over fixed inputs. It needed three things that did not exist:
//
//   - `null` and nullable heap references          (ADR-0049)
//   - storing a heap reference into a field        (ADR-0048)
//   - reassigning a heap-typed local in a loop     (ADR-0048)
//
// It is also the first program whose CORRECTNESS depends on the ARC policy
// being balanced rather than merely present: `head = Node(i, head)` transfers
// the old head into the new node's field while the local stops holding it.
// One retain too few leaks; one too many frees a live node.
import '../../runtime/dc-core-bare/prelude.dart';

class Node extends HeapObject {
  u64 value;
  Node? next;
  Node(this.value, this.next);
}

/// Builds a list of `n` nodes and walks it, summing values.
///
/// The build loop is the interesting half. Each iteration:
///   - `Node(i, head)` allocates (+1) and its field store retains `head`
///   - assigning to `head` releases the previous head, which the new node's
///     field is now holding
/// so every node ends with exactly one owner and the chain frees completely
/// when the head goes out of scope.
@bare
u64 buildAndSum(u64 n) {
  Node? head = null;
  var i = u64(0);
  while (i < n) {
    head = Node(i, head);
    i = i + u64(1);
  }
  var total = u64(0);
  var cur = head;
  while (cur != null) {
    total = total + cur.value;
    cur = cur.next;
  }
  return total;
}

/// Walks to the end and returns the last value -- proves `next` chains
/// correctly rather than every node pointing at the same place.
@bare
u64 lastValue(u64 n) {
  Node? head = null;
  var i = u64(0);
  while (i < n) {
    head = Node(i, head);
    i = i + u64(1);
  }
  var cur = head;
  var last = u64(999);
  while (cur != null) {
    last = cur.value;
    cur = cur.next;
  }
  return last;
}

/// Counts nodes, using `break` to stop early -- composes ADR-0047 with a
/// heap-typed loop-carried variable.
@bare
u64 countUpTo(u64 n, u64 limit) {
  Node? head = null;
  var i = u64(0);
  while (i < n) {
    head = Node(i, head);
    i = i + u64(1);
  }
  var count = u64(0);
  var cur = head;
  while (cur != null) {
    if (count >= limit) {
      break;
    }
    count = count + u64(1);
    cur = cur.next;
  }
  return count;
}
