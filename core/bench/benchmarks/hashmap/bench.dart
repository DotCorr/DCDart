// core/bench/benchmarks/hashmap/bench.dart
//
// M3 benchmark 2 of 5: a hash map under CHURN. THE GATE INPUT.
//
// This benchmark is one half of a deliberately-designed PAIR, and reading
// either half alone gets the wrong answer:
//
//   hashmap-burst   phase A   bulk insert, bulk lookup, bulk teardown
//   hashmap         phase B   the same work, interleaved   <-- this file
//
// Same map, same keys, same operation counts, same checksum. The ONLY
// difference is the ORDER the operations occur in. That is the whole design:
// if the two sides differ only in allocation pattern, then any gap between
// them IS allocation, and no argument is needed to establish it.
//
// WHY A PAIR AT ALL. `tree-traversal` landed the day before this and came out
// 2.3x FASTER than C -- 76.9 ms against 177.5 ms, same tree, matching
// checksums. That is not ARC being free. Every node the same size, allocated
// in a burst, freed at once is the best possible case for a bump-and-free-list
// allocator and close to the worst for `malloc`, and ADR-0058 named it in
// advance as "the single most likely thing to make an M3 number look better
// than a real allocator would". A hashmap written the obvious way has exactly
// that shape, only more so. Two of the gate's five inputs would then be
// measuring allocator strategy while the gate's own wording says ARC.
//
// So phase B holds the live set STEADY instead of building and razing it. One
// insert, one lookup, one delete per step, over a rolling window of 1024
// entries. Both allocators then run in recycling mode -- DCDart pops and
// pushes size-class free lists, `malloc` hits its small-block caches -- and
// phase A's structural advantage is gone. What is left is retain/release
// traffic, which is what the gate says it measures.
//
// PHASE A IS PUBLISHED AND IS EXCLUDED FROM EVERY GEOMETRIC MEAN
// (`BENCH_SUITE=diagnostic`, the treatment `arc-churn` already gets). This
// file carries `BENCH_ID=hashmap` into the gate. The gate takes the harsher
// of the two numbers and the flattering one is printed next to it.
//
// THE BUCKET INDEX IS A BINARY TRIE, NOT AN ARRAY, and that is not a design
// preference. DCDart cannot express an array of ARC-managed references at all
// (GAP-0061) -- see the `Trie` comment below. `kernel.c` implements the same
// trie so the two sides chase the same pointers; the cost of the workaround
// is measured separately by `index-tax/` rather than left as a caveat.
//
import '../../../runtime/dc-core-bare/prelude.dart';
// ---------------------------------------------------------------------------
// SHARED MAP IMPLEMENTATION -- byte-identical in `hashmap/` and
// `hashmap-burst/`. `verify-parity.sh` diffs the region between these two
// markers and fails if it ever drifts. The two phases exist to be compared
// with each other, so a divergence here would silently invalidate the
// comparison rather than break a build.
//
// It is duplicated rather than imported because `dcc` compiles ONE library
// per object file and `@bare` functions in imported libraries are dropped
// (GAP-0028).
// BEGIN-SHARED-MAP
// ---------------------------------------------------------------------------

/// The three value shapes. Their only job is to land in THREE DIFFERENT size
/// classes of ADR-0058's segregated heap, because a mix that stays inside one
/// class exercises nothing: 40, 48 and 56-byte values would all land in the
/// 64-byte class and the allocator would behave exactly as in the uniform
/// case.
///
///   VS  3 x u64 =  24 bytes payload + 16 header =  40 -> class  64
///   VM  12 x u64 =  96 bytes payload + 16 header = 112 -> class 128
///   VB  31 x u64 = 248 bytes payload + 16 header = 264 -> class 512
///
/// The field lists are spelled out one `u64` at a time because DCDart has no
/// array-typed field and no array type at all. That is ugly and it is the
/// truth about the language today; see `docs/known-gaps.md` GAP-0061.
class VS extends HeapObject {
  u64 a0;
  u64 a1;
  u64 a2;
  VS(this.a0, this.a1, this.a2);
}

class VM extends HeapObject {
  u64 a0;
  u64 a1;
  u64 a2;
  u64 a3;
  u64 a4;
  u64 a5;
  u64 a6;
  u64 a7;
  u64 a8;
  u64 a9;
  u64 a10;
  u64 a11;
  VM(this.a0, this.a1, this.a2, this.a3, this.a4, this.a5, this.a6, this.a7, this.a8, this.a9, this.a10, this.a11);
}

class VB extends HeapObject {
  u64 a0;
  u64 a1;
  u64 a2;
  u64 a3;
  u64 a4;
  u64 a5;
  u64 a6;
  u64 a7;
  u64 a8;
  u64 a9;
  u64 a10;
  u64 a11;
  u64 a12;
  u64 a13;
  u64 a14;
  u64 a15;
  u64 a16;
  u64 a17;
  u64 a18;
  u64 a19;
  u64 a20;
  u64 a21;
  u64 a22;
  u64 a23;
  u64 a24;
  u64 a25;
  u64 a26;
  u64 a27;
  u64 a28;
  u64 a29;
  u64 a30;
  VB(this.a0, this.a1, this.a2, this.a3, this.a4, this.a5, this.a6, this.a7, this.a8, this.a9, this.a10, this.a11, this.a12, this.a13, this.a14, this.a15, this.a16, this.a17, this.a18, this.a19, this.a20, this.a21, this.a22, this.a23, this.a24, this.a25, this.a26, this.a27, this.a28, this.a29, this.a30);
}

/// A map entry. `kind` says which of the three value fields is non-null --
/// DCDart has no sum type and no subtype polymorphism, so a heterogeneous
/// value is a tag plus one field per alternative.
///
/// 6 x 8 = 48 bytes payload + 16 header = 64 -> size class 64, the same class
/// as `VS` and `Trie`. That is deliberate and it is realistic: a real
/// allocator's small class holds several unrelated populations at once, and
/// it is the class whose 32,768-block ceiling this benchmark is sized
/// against.
class Entry extends HeapObject {
  u64 key;
  u64 kind;
  Entry? next;
  VS? vs;
  VM? vm;
  VB? vb;
  Entry(this.key, this.kind, this.next, this.vs, this.vm, this.vb);
}

/// One node of the bucket index. `c0`/`c1` are the two children of an
/// internal node; `head` is the bucket chain head at a leaf. One class serves
/// both so the descent needs no type test.
///
/// WHY A BINARY TRIE AND NOT A BUCKET ARRAY, which is what every C hash map
/// on earth uses and what `kernel.c` would use if it could:
///
///   DCDart cannot express an array of ARC-managed references. A managed
///   reference lives only in a field of a `HeapObject`; there is no array
///   type, and there is no way to turn a raw address back into a managed
///   reference, so `Heap.allocate` cannot back one either. O(1) indexed
///   access to managed objects is INEXPRESSIBLE (GAP-0061).
///
/// So the bucket table is a complete binary trie of depth 10 over the low
/// 10 bits of the hash: 1024 buckets, 2047 nodes, 127 KiB.
/// `kernel.c` implements THE SAME TRIE rather than an array, because a
/// baseline doing a different amount of pointer chasing measures the data
/// structure and not the language. The cost of that decision is measured
/// rather than argued: `index-tax/` times the identical C workload with a
/// real bucket array, and the ADR publishes the number.
class Trie extends HeapObject {
  Trie? c0;
  Trie? c1;
  Entry? head;
  Trie(this.c0, this.c1, this.head);
}

/// Bucket index for [k]. Multiplicative, with the middle bits folded, and
/// with NO operation that can overflow: `k % 1000003` is under 2^20 and
/// 2^20 * 2654435761 is under 2^52, so the multiply cannot trap. DCDart has
/// no wrapping `&*`, so an ordinary 64-bit hash mixer is not writable here --
/// every `*` in it would be a trap check on a value that is SUPPOSED to wrap.
@bare u64 hashOf(u64 k) {
  final m = k % u64(1000003);
  final x = m * u64(2654435761);
  final h = (x >> u64(13)) ^ (x >> u64(31));
  return h & u64(1023);
}

/// Which size class step [s] of [total] gets. THREE ERAS, so the size mix
/// SHIFTS over the run rather than staying stationary:
///
///   era 0 (first third)   70% VS  20% VM  10% VB
///   era 1 (second third)  40% VS  40% VM  20% VB
///   era 2 (last third)    20% VS  40% VM  40% VB
///
/// A stationary mix would let every class reach its high-water mark early and
/// stay there, which is the case ADR-0058's no-coalescing/no-cross-class-reuse
/// heap handles as well as any other. A SHIFTING mix is the case it handles
/// worst: a class whose population has receded still holds every block it
/// ever peaked at, so the heap holds the SUM of the per-class high-water
/// marks while `malloc` holds something closer to the maximum of the total.
/// That is the property phase B exists to expose, and `dc_heap_bump` measures
/// it directly -- a bump cursor never retreats, so its final value IS that
/// class's high-water mark.
@bare u64 kindOf(u64 s, u64 total) {
  final era = (s * u64(3)) ~/ total;
  final q = s % u64(10);
  if (era == u64(0)) {
    if (q < u64(7)) { return u64(0); }
    if (q < u64(9)) { return u64(1); }
    return u64(2);
  }
  if (era == u64(1)) {
    if (q < u64(4)) { return u64(0); }
    if (q < u64(8)) { return u64(1); }
    return u64(2);
  }
  if (q < u64(2)) { return u64(0); }
  if (q < u64(6)) { return u64(1); }
  return u64(2);
}

/// Builds the complete trie once per kernel call. 2047 allocations amortised
/// over millions of map operations, so it is not part of what is measured --
/// but it IS part of what is allocated, and it sits in the same size class as
/// every `Entry`.
@bare Trie buildTrie(u64 depth) {
  if (depth == u64(0)) {
    return Trie(null, null, null);
  }
  final a = buildTrie(depth - u64(1));
  final b = buildTrie(depth - u64(1));
  return Trie(a, b, null);
}

/// Descend `level` more bits of `h` and prepend `e` at the leaf.
///
/// RECURSIVE, not a loop, and that is an ARC decision rather than a style
/// one. A `HeapObject`-typed parameter is BORROWED by default (ADR-0019), so
/// descending by recursion emits no retain/release at all. Descending by
/// reassigning a heap-typed local -- `var n = root; ... n = c;` -- is a heap
/// reference assignment (ADR-0048) and emits a retain and a release PER
/// LEVEL, which would charge 10 ARC pairs per map operation to a bucket index
/// that C does not have. The measurement would then be dominated by the
/// workaround for GAP-0061. The recursive call is in tail position and both
/// sides are compiled by the same LLVM at -O2.
@bare u64 tinsert(Trie n, u64 level, u64 h, Entry e) {
  if (level == u64(0)) {
    e.next = n.head;
    n.head = e;
    return u64(1);
  }
  final bit = (h >> (level - u64(1))) & u64(1);
  if (bit == u64(0)) {
    final c = n.c0;
    if (c != null) {
      return tinsert(c, level - u64(1), h, e);
    }
    return u64(0);
  }
  final c = n.c1;
  if (c != null) {
    return tinsert(c, level - u64(1), h, e);
  }
  return u64(0);
}

/// Sum two words of the entry's value. Reads the FIRST and LAST field so a
/// large value is touched at both ends rather than only at its head, which is
/// what makes the size mix cost cache traffic and not just address space.
@bare u64 valueSum(Entry e) {
  final k = e.kind;
  if (k == u64(0)) {
    final v = e.vs;
    if (v != null) {
      return v.a0 + v.a2;
    }
    return u64(0);
  }
  if (k == u64(1)) {
    final v = e.vm;
    if (v != null) {
      return v.a0 + v.a11;
    }
    return u64(0);
  }
  final v = e.vb;
  if (v != null) {
    return v.a0 + v.a30;
  }
  return u64(0);
}

@bare u64 chainSum(Entry e, u64 key) {
  if (e.key == key) {
    return valueSum(e);
  }
  final nx = e.next;
  if (nx != null) {
    return chainSum(nx, key);
  }
  return u64(0);
}

@bare u64 tlookup(Trie n, u64 level, u64 h, u64 key) {
  if (level == u64(0)) {
    final hd = n.head;
    if (hd != null) {
      return chainSum(hd, key);
    }
    return u64(0);
  }
  final bit = (h >> (level - u64(1))) & u64(1);
  if (bit == u64(0)) {
    final c = n.c0;
    if (c != null) {
      return tlookup(c, level - u64(1), h, key);
    }
    return u64(0);
  }
  final c = n.c1;
  if (c != null) {
    return tlookup(c, level - u64(1), h, key);
  }
  return u64(0);
}

/// Unlink the entry whose key is [key] from the chain rooted after [p], and
/// RETURN THE KEY IT REMOVED so the caller can fold it into the checksum. A
/// remove that returns nothing cannot be checksummed, and a delete that
/// silently did nothing is precisely the bug a two-phase benchmark would hide.
///
/// *** THIS IS GAP-0054's CANONICAL SHAPE. *** `final c = p.next` retains an
/// aliasing value; `p.next = c.next` emits a mid-function `Release` of the
/// old field value, which IS `c`; and `c.key` is then read AFTER that release.
/// ADR-0025's elision pass 3 deletes a `retain(x) ... release(x)` pair when no
/// release OF X appears between them, and it reasons over DCValues, so a
/// release of a DIFFERENT value that names the same object does not stop it.
/// GAP-0054 names `map.get(k)` followed by a mutation of the map as the shape
/// that breaks it and says "it is exactly what M3's hashmap benchmark will
/// write." It is written here, deliberately and in its natural form, rather
/// than routed around. What the pass actually does with it is recorded in
/// `docs/decisions/0061-hashmap-benchmark-two-phases.md`.
@bare u64 unlinkFrom(Entry p, u64 key) {
  final c = p.next;
  if (c == null) {
    return u64(0);
  }
  if (c.key == key) {
    p.next = c.next;
    return c.key;
  }
  return unlinkFrom(c, key);
}

@bare u64 unlinkHead(Trie n, u64 key) {
  final h0 = n.head;
  if (h0 == null) {
    return u64(0);
  }
  if (h0.key == key) {
    n.head = h0.next;
    return h0.key;
  }
  return unlinkFrom(h0, key);
}

@bare u64 tremove(Trie n, u64 level, u64 h, u64 key) {
  if (level == u64(0)) {
    return unlinkHead(n, key);
  }
  final bit = (h >> (level - u64(1))) & u64(1);
  if (bit == u64(0)) {
    final c = n.c0;
    if (c != null) {
      return tremove(c, level - u64(1), h, key);
    }
    return u64(0);
  }
  final c = n.c1;
  if (c != null) {
    return tremove(c, level - u64(1), h, key);
  }
  return u64(0);
}

/// Insert `key` with a value of the size class `kind` names. NO duplicate
/// check: the workload never inserts a live key twice, so a scan would be
/// work neither side needs and would make insert's cost depend on chain
/// length, which is the one thing that differs between the two phases.
@bare u64 mapInsert(Trie root, u64 key, u64 kind) {
  final v = key % u64(1000003);
  if (kind == u64(0)) {
    final val = VS(v, v, v);
    final e = Entry(key, u64(0), null, val, null, null);
    return tinsert(root, u64(10), hashOf(key), e);
  }
  if (kind == u64(1)) {
    final val = VM(v, v, v, v, v, v, v, v, v, v, v, v);
    final e = Entry(key, u64(1), null, null, val, null);
    return tinsert(root, u64(10), hashOf(key), e);
  }
  final val = VB(v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v);
  final e = Entry(key, u64(2), null, null, null, val);
  return tinsert(root, u64(10), hashOf(key), e);
}

@bare u64 mapLookup(Trie root, u64 key) {
  return tlookup(root, u64(10), hashOf(key), key);
}

/// Removing the entry drops the last strong reference to it. NOTHING IN THIS
/// FILE FREES ANYTHING: the destructor cascade (ADR-0022) releases the entry,
/// which releases its value object, when the borrowed local holding it leaves
/// scope. `kernel.c` needs two explicit `free` calls at the same point. That
/// difference is what the gate is measuring.
@bare u64 mapRemove(Trie root, u64 key) {
  return tremove(root, u64(10), hashOf(key), key);
}

// ---------------------------------------------------------------------------
// END-SHARED-MAP
// ---------------------------------------------------------------------------

/// PHASE B -- CHURN. The same operations, on the same keys, in the same
/// count, producing the same checksum -- interleaved instead of batched.
///
/// At every step one entry is inserted, one is looked up, and one inserted
/// 1024 steps earlier is deleted. The live set therefore holds steady at 1024
/// entries, the same high-water mark phase A reaches, while both allocators
/// run in RECYCLING mode: DCDart pops and pushes size-class free lists,
/// `malloc` hits its small-block caches. Phase A's advantage -- bump
/// allocation against a `malloc` that has to do fragmentation-avoiding work
/// it will never be repaid for -- is neutralised, and what is left is ARC.
///
/// THE PARAMETERS WERE FIXED BEFORE THE FIRST TIMED RUN and are argued from
/// the workload, not from the ratio, in ADR-0061 §"Phase B's parameters":
///
///   window 1024 entries      a bounded cache at load factor 1.0 over 1024 buckets
///   1 delete per insert    steady state -- one eviction per admission
///   3 size classes         64 / 128 / 512, a mix that SHIFTS across the run
///
/// The last 1024 keys are drained after the loop so the delete count matches
/// phase A's exactly; without it phase B would perform 1024 fewer deletes and
/// "B is slower" would have a second explanation.
@bare u64 benchKernel(u64 rounds) {
  final root = buildTrie(u64(10));
  final total = rounds * u64(1024);
  var acc = u64(0);
  var s = u64(0);
  while (s < total) {
    acc = (acc + mapInsert(root, s, kindOf(s, total))) % u64(1000000007);
    acc = (acc + mapLookup(root, s)) % u64(1000000007);
    if (u64(1024) <= s) {
      acc = (acc + mapRemove(root, s - u64(1024))) % u64(1000000007);
    }
    s = s + u64(1);
  }
  var d = total - u64(1024);
  while (d < total) {
    acc = (acc + mapRemove(root, d)) % u64(1000000007);
    d = d + u64(1);
  }
  return acc;
}
