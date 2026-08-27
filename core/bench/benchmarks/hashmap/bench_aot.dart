// core/bench/benchmarks/hashmap/bench_aot.dart
//
// The stock-Dart-AOT third data point (`dart compile exe`). This is ORDINARY
// Dart, not DCDart -- it does not import the prelude and it is not compiled
// by dcc. INFORMATIONAL ONLY; it never enters a gate number (see
// fib/bench_aot.dart for the full rationale, which applies unchanged).
//
// It mirrors bench.dart's ALGORITHM -- the same depth-10 bucket trie, the
// same chains, the same keys, operations and checksum -- rather than using
// Dart's built-in HashMap, for the same reason kernel.c walks the trie: a
// side doing a different amount of pointer chasing measures the data
// structure, not the runtime. What DIFFERS is memory management: upstream
// Dart's tracing GC against DCDart's ARC and C's malloc/free, which is
// exactly the comparison this column exists to inform.
//
// The one idiomatic substitution: the three fixed-size value shapes
// (VS/VM/VB, spelled as 3/12/31 u64 fields in DCDart because it has no array
// type, GAP-0061) become `List<int>.filled(3|12|31)`, which is how a Dart
// programmer writes "a value of that size". The checksum reads the first and
// last slot, identically.

class Entry {
  final int key;
  final List<int> val;
  Entry? next;
  Entry(this.key, this.val, this.next);
}

class Trie {
  Trie? c0;
  Trie? c1;
  Entry? head;
  Trie(this.c0, this.c1, this.head);
}

int hashOf(int k) {
  final m = k % 1000003;
  final x = m * 2654435761;
  final h = (x >> 13) ^ (x >> 31);
  return h & 1023;
}

int kindOf(int s, int total) {
  final era = (s * 3) ~/ total;
  final q = s % 10;
  if (era == 0) return q < 7 ? 0 : (q < 9 ? 1 : 2);
  if (era == 1) return q < 4 ? 0 : (q < 8 ? 1 : 2);
  return q < 2 ? 0 : (q < 6 ? 1 : 2);
}

Trie buildTrie(int depth) {
  if (depth == 0) return Trie(null, null, null);
  return Trie(buildTrie(depth - 1), buildTrie(depth - 1), null);
}

int tinsert(Trie n, int level, int h, Entry e) {
  if (level == 0) {
    e.next = n.head;
    n.head = e;
    return 1;
  }
  final bit = (h >> (level - 1)) & 1;
  final c = bit == 0 ? n.c0 : n.c1;
  if (c != null) return tinsert(c, level - 1, h, e);
  return 0;
}

int valueSum(Entry e) => e.val.first + e.val.last;

int chainSum(Entry e, int key) {
  if (e.key == key) return valueSum(e);
  final nx = e.next;
  if (nx != null) return chainSum(nx, key);
  return 0;
}

int tlookup(Trie n, int level, int h, int key) {
  if (level == 0) {
    final hd = n.head;
    if (hd != null) return chainSum(hd, key);
    return 0;
  }
  final bit = (h >> (level - 1)) & 1;
  final c = bit == 0 ? n.c0 : n.c1;
  if (c != null) return tlookup(c, level - 1, h, key);
  return 0;
}

int unlinkFrom(Entry p, int key) {
  final c = p.next;
  if (c == null) return 0;
  if (c.key == key) {
    p.next = c.next;
    return c.key;
  }
  return unlinkFrom(c, key);
}

int unlinkHead(Trie n, int key) {
  final h0 = n.head;
  if (h0 == null) return 0;
  if (h0.key == key) {
    n.head = h0.next;
    return h0.key;
  }
  return unlinkFrom(h0, key);
}

int tremove(Trie n, int level, int h, int key) {
  if (level == 0) return unlinkHead(n, key);
  final bit = (h >> (level - 1)) & 1;
  final c = bit == 0 ? n.c0 : n.c1;
  if (c != null) return tremove(c, level - 1, h, key);
  return 0;
}

int mapInsert(Trie root, int key, int kind) {
  final v = key % 1000003;
  final size = kind == 0 ? 3 : (kind == 1 ? 12 : 31);
  final e = Entry(key, List<int>.filled(size, v), null);
  return tinsert(root, 10, hashOf(key), e);
}

int mapLookup(Trie root, int key) => tlookup(root, 10, hashOf(key), key);

int mapRemove(Trie root, int key) => tremove(root, 10, hashOf(key), key);

int benchKernel(int rounds) {
  final root = buildTrie(10);
  final total = rounds * 1024;
  var acc = 0;
  for (var s = 0; s < total; s++) {
    acc = (acc + mapInsert(root, s, kindOf(s, total))) % 1000000007;
    acc = (acc + mapLookup(root, s)) % 1000000007;
    if (1024 <= s) {
      acc = (acc + mapRemove(root, s - 1024)) % 1000000007;
    }
  }
  for (var d = total - 1024; d < total; d++) {
    acc = (acc + mapRemove(root, d)) % 1000000007;
  }
  return acc;
}

void main(List<String> args) {
  final arg = args.isNotEmpty ? int.parse(args[0]) : 600;
  final iters = args.length > 1 ? int.parse(args[1]) : 1;

  final warm = benchKernel(arg); // discarded
  final checksum = warm;

  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    final r = benchKernel(arg);
    sw.stop();
    if (r != checksum) {
      throw StateError('kernel is not deterministic');
    }
    print('SAMPLE_NS ${sw.elapsedMicroseconds * 1000}');
  }
  print('CHECKSUM $checksum');
  print('CLOCK Stopwatch');
}
