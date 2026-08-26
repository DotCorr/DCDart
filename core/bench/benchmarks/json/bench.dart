// core/bench/benchmarks/json/bench.dart
//
// M3 benchmark 3 of 5: a JSON parser.
//
// Parses a generated document into a heap tree of typed nodes, walks it, and
// drops it. This is the benchmark that exercises the most of DCDart at once:
// heap objects with nullable heap fields, recursion, `Str` slices into the
// input, growable output, and a destructor cascade over a tree of mixed
// shapes.
//
// WHY THE PARSER DOES NOT COPY STRINGS. A JSON string value is stored as an
// OFFSET AND LENGTH into the input buffer, not as a copied string -- which is
// how fast parsers actually work, and which `Str` (ADR-0053) is shaped for:
// a borrowed slice, no allocation. Copying every string would make this
// benchmark measure `Heap.allocate` throughput a second time, which
// `string-pass` already measures deliberately and better.
//
// NODE SHAPE, and it is a compromise worth stating. There are no sum types,
// no unions and no variant records in DCDart, so a node carries a `kind` tag
// plus every field any kind might need. A C parser would use a union and a
// smaller node. The C baseline therefore uses a union -- comparing DCDart's
// tagged node against a C tagged node would import DCDart's limitation into
// the baseline and flatter DCDart, which is the failure ADR-0059 exists to
// prevent. The consequence is that DCDart allocates a LARGER node than C,
// and that is a real cost of the language today, correctly charged to it.
//
// GAP-0054 WATCH: `parseValue` returns a node it also holds in a local, which
// dc-sys-21's generic-classes agent identified as the get-then-mutate shape
// where ADR-0025's pass 3 can elide a pair across a `Release` of an aliasing
// value -- safe today only because `_releaseHeapLocals` runs after the return
// expression, which is a property of the lowering rather than of the pass. If
// this benchmark ever returns a wrong checksum or double-frees, that is the
// first place to look.
import '../../../runtime/dc-core-bare/prelude.dart';

// kind: 0 = number, 1 = string, 2 = array, 3 = object-member
class JNode extends HeapObject {
  u64 kind;
  u64 number;     // kind 0
  u64 strOffset;  // kind 1 -- a slice into the input, never copied
  u64 strLength;
  JNode? first;   // kind 2/3 -- first child
  JNode? next;    // sibling
  JNode(this.kind, this.number, this.strOffset, this.strLength, this.first,
        this.next);
}

class Parser extends HeapObject {
  u64 addr;
  u64 pos;
  u64 len;
  Parser(this.addr, this.pos, this.len);
}

@bare u8 peek(Parser p) {
  return Pointer<u8>.fromAddress(p.addr + p.pos).value;
}

@bare void skipWs(Parser p) {
  while (p.pos < p.len) {
    final c = peek(p).toU64();
    // Nested ifs rather than `c != 32 && c != 10 && c != 9`: LogicalExpression
    // (`&&`, `||`) is not lowered. The C side writes the condition normally.
    var ws = u64(0);
    if (c == u64(32)) { ws = u64(1); }
    if (c == u64(10)) { ws = u64(1); }
    if (c == u64(9)) { ws = u64(1); }
    if (ws == u64(0)) {
      return;
    }
    p.pos = p.pos + u64(1);
  }
}

@bare JNode parseNumber(Parser p) {
  var v = u64(0);
  while (p.pos < p.len) {
    final c = peek(p).toU64();
    // `||` is not lowered either -- see skipWs.
    if (c < u64(48)) {
      return JNode(u64(0), v, u64(0), u64(0), null, null);
    }
    if (c > u64(57)) {
      return JNode(u64(0), v, u64(0), u64(0), null, null);
    }
    v = (v * u64(10) + (c - u64(48))) % u64(1000000007);
    p.pos = p.pos + u64(1);
  }
  return JNode(u64(0), v, u64(0), u64(0), null, null);
}

/// A string value: recorded as offset+length into the input. No copy.
@bare JNode parseString(Parser p) {
  p.pos = p.pos + u64(1); // opening quote
  final start = p.pos;
  while (p.pos < p.len) {
    if (peek(p).toU64() == u64(34)) {
      final n = JNode(u64(1), u64(0), start, p.pos - start, null, null);
      p.pos = p.pos + u64(1); // closing quote
      return n;
    }
    p.pos = p.pos + u64(1);
  }
  return JNode(u64(1), u64(0), start, p.pos - start, null, null);
}

@bare JNode parseValue(Parser p) {
  skipWs(p);
  final c = peek(p).toU64();
  if (c == u64(34)) {
    return parseString(p);
  }
  if (c == u64(91)) {
    return parseArray(p);
  }
  return parseNumber(p);
}

/// `[` value (`,` value)* `]`, built as a linked list of children so the
/// node shape stays fixed and no growable array is needed.
@bare JNode parseArray(Parser p) {
  p.pos = p.pos + u64(1); // '['
  final arr = JNode(u64(2), u64(0), u64(0), u64(0), null, null);
  JNode? tail = null;
  while (p.pos < p.len) {
    skipWs(p);
    final c = peek(p).toU64();
    if (c == u64(93)) {
      p.pos = p.pos + u64(1);
      return arr;
    }
    if (c == u64(44)) {
      p.pos = p.pos + u64(1);
      continue;
    }
    final child = parseValue(p);
    final t = tail;
    if (t == null) {
      arr.first = child;
    } else {
      t.next = child;
    }
    tail = child;
  }
  return arr;
}

/// Walks the tree and folds every node into a checksum. Recursion plus
/// sibling iteration, so both the depth and the breadth of the tree are
/// visited by real traversal rather than by counting.
@bare u64 walk(JNode n) {
  var h = n.kind;
  h = (h * u64(31) + n.number) % u64(1000000007);
  h = (h * u64(31) + n.strLength) % u64(1000000007);
  final f = n.first;
  if (f != null) {
    h = (h + walk(f)) % u64(1000000007);
  }
  final s = n.next;
  if (s != null) {
    h = (h + walk(s)) % u64(1000000007);
  }
  return h;
}

/// Writes a nested JSON document into `addr`. Identical generator on both
/// sides, so neither gets its input for free.
@bare u64 genDoc(u64 addr, u64 cap) {
  var i = u64(0);
  var x = u64(7);
  Pointer<u8>.fromAddress(addr + i).value = u64(91).toU8(); // '['
  i = i + u64(1);
  var group = u64(0);
  while (group < u64(300)) {
    if (group != u64(0)) {
      Pointer<u8>.fromAddress(addr + i).value = u64(44).toU8();
      i = i + u64(1);
    }
    Pointer<u8>.fromAddress(addr + i).value = u64(91).toU8();
    i = i + u64(1);
    var k = u64(0);
    while (k < u64(6)) {
      if (k != u64(0)) {
        Pointer<u8>.fromAddress(addr + i).value = u64(44).toU8();
        i = i + u64(1);
      }
      x = (x * u64(1103515245) + u64(12345)) % u64(2147483648);
      if (x % u64(2) == u64(0)) {
        // a number
        var d = u64(0);
        while (d < u64(4)) {
          final digit = u64(48) + (x ~/ u64(10)) % u64(10);
          Pointer<u8>.fromAddress(addr + i).value = digit.toU8();
          i = i + u64(1);
          x = x ~/ u64(7) + u64(3);
          d = d + u64(1);
        }
      } else {
        // a short string
        Pointer<u8>.fromAddress(addr + i).value = u64(34).toU8();
        i = i + u64(1);
        var d = u64(0);
        while (d < u64(5)) {
          final ch = u64(97) + (x + d) % u64(26);
          Pointer<u8>.fromAddress(addr + i).value = ch.toU8();
          i = i + u64(1);
          d = d + u64(1);
        }
        Pointer<u8>.fromAddress(addr + i).value = u64(34).toU8();
        i = i + u64(1);
      }
      k = k + u64(1);
    }
    Pointer<u8>.fromAddress(addr + i).value = u64(93).toU8();
    i = i + u64(1);
    group = group + u64(1);
  }
  Pointer<u8>.fromAddress(addr + i).value = u64(93).toU8();
  i = i + u64(1);
  return i;
}

@bare u64 benchKernel(u64 rounds) {
  final cap = u64(65000);
  final doc = Heap.allocate(cap);
  final len = genDoc(doc.address, cap);

  var acc = u64(0);
  var r = u64(0);
  while (r < rounds) {
    final p = Parser(doc.address, u64(0), len);
    final root = parseValue(p);
    acc = (acc + walk(root)) % u64(1000000007);
    r = r + u64(1);
  }
  Heap.free(doc);
  return acc;
}
