// M2 comparison/equality-operator target (docs/decisions/0035-complete-
// integer-operators.md). Before that change the language had `<` on u64
// and NOTHING else: no `<=`/`>`/`>=` at any width, no comparison at all on
// u32/u16/u8, and no `==`/`!=` anywhere. This target covers the whole new
// surface.
//
// Like m2-bitwise (and unlike m2-port's privileged instructions), compares
// are ordinary unprivileged instructions, so this target is verified by
// real execution against exact expected values -- the strongest form this
// project's harnesses use.
//
// Two things make this target worth testing harder than m2-bitwise did:
//
//   1. SIGNEDNESS. `ICmpPredicate` carries both signed and unsigned
//      predicates (`ult` vs `slt`, ...). Every DCDart sized-int type today
//      is unsigned, so the unsigned ones are the correct choice -- and the
//      only inputs that can tell the two apart are the ones with the top
//      bit set. u64 max, u32 max, u16 max and u8 max all read as `-1`
//      under a signed predicate, so `0 < MAX` is the load-bearing case:
//      it is 1 unsigned and 0 signed. Every width's max is tested against
//      0 and against max-1 for exactly this reason.
//
//   2. `==` / `!=` DO NOT LOWER LIKE THE OTHERS. Dart forbids declaring
//      `operator ==` on an extension type, so unlike `<`/`<=`/`>`/`>=`
//      there is no `u64|==` prelude member for dcc-lower to match on, and
//      the front end does not emit a `StaticInvocation` for it. `a == b`
//      arrives as a Kernel `EqualsCall` node and `a != b` as an
//      `EqualsCall` under a `Not` -- a completely separate recognition
//      path from every other operator in the language. That is the
//      riskiest new code here, so equality is exercised at all four
//      widths, in `if` conditions, in `while` conditions, in both the
//      then- and else-branch positions, and inside a real algorithm.
//
// Predicates return the width under test as 1/0 rather than `bool` --
// `bool` is not a DCDart value type at the @bare ABI boundary, and 1/0
// lets main.c check an exact value instead of a truthiness.
import '../../runtime/dc-core-bare/prelude.dart';

// ---------------------------------------------------------------------------
// Ordering: the four operators at u64.
// ---------------------------------------------------------------------------

@bare
u64 ltU64(u64 a, u64 b) {
  if (a < b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 leU64(u64 a, u64 b) {
  if (a <= b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 gtU64(u64 a, u64 b) {
  if (a > b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 geU64(u64 a, u64 b) {
  if (a >= b) {
    return u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// Ordering at u32. Returns u32, not u64: the return type is part of what
// the width-parsing branch has to get right, so each width returns itself.
// ---------------------------------------------------------------------------

@bare
u32 ltU32(u32 a, u32 b) {
  if (a < b) {
    return u32(1);
  }
  return u32(0);
}

@bare
u32 leU32(u32 a, u32 b) {
  if (a <= b) {
    return u32(1);
  }
  return u32(0);
}

@bare
u32 gtU32(u32 a, u32 b) {
  if (a > b) {
    return u32(1);
  }
  return u32(0);
}

@bare
u32 geU32(u32 a, u32 b) {
  if (a >= b) {
    return u32(1);
  }
  return u32(0);
}

// ---------------------------------------------------------------------------
// Ordering at u16.
// ---------------------------------------------------------------------------

@bare
u16 ltU16(u16 a, u16 b) {
  if (a < b) {
    return u16(1);
  }
  return u16(0);
}

@bare
u16 leU16(u16 a, u16 b) {
  if (a <= b) {
    return u16(1);
  }
  return u16(0);
}

@bare
u16 gtU16(u16 a, u16 b) {
  if (a > b) {
    return u16(1);
  }
  return u16(0);
}

@bare
u16 geU16(u16 a, u16 b) {
  if (a >= b) {
    return u16(1);
  }
  return u16(0);
}

// ---------------------------------------------------------------------------
// Ordering at u8.
// ---------------------------------------------------------------------------

@bare
u8 ltU8(u8 a, u8 b) {
  if (a < b) {
    return u8(1);
  }
  return u8(0);
}

@bare
u8 leU8(u8 a, u8 b) {
  if (a <= b) {
    return u8(1);
  }
  return u8(0);
}

@bare
u8 gtU8(u8 a, u8 b) {
  if (a > b) {
    return u8(1);
  }
  return u8(0);
}

@bare
u8 geU8(u8 a, u8 b) {
  if (a >= b) {
    return u8(1);
  }
  return u8(0);
}

// ---------------------------------------------------------------------------
// Equality and inequality -- the EqualsCall path (see this file's header).
// All four widths, because the width is read off the operand type here in
// a different place than it is for the StaticInvocation operators.
// ---------------------------------------------------------------------------

@bare
u64 eqU64(u64 a, u64 b) {
  if (a == b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u64 neU64(u64 a, u64 b) {
  if (a != b) {
    return u64(1);
  }
  return u64(0);
}

@bare
u32 eqU32(u32 a, u32 b) {
  if (a == b) {
    return u32(1);
  }
  return u32(0);
}

@bare
u32 neU32(u32 a, u32 b) {
  if (a != b) {
    return u32(1);
  }
  return u32(0);
}

@bare
u16 eqU16(u16 a, u16 b) {
  if (a == b) {
    return u16(1);
  }
  return u16(0);
}

@bare
u16 neU16(u16 a, u16 b) {
  if (a != b) {
    return u16(1);
  }
  return u16(0);
}

@bare
u8 eqU8(u8 a, u8 b) {
  if (a == b) {
    return u8(1);
  }
  return u8(0);
}

@bare
u8 neU8(u8 a, u8 b) {
  if (a != b) {
    return u8(1);
  }
  return u8(0);
}

// ---------------------------------------------------------------------------
// Equality in positions other than "sole `if` condition, then-branch
// returns". A recognition path that only ever got tested in one syntactic
// position is a path that has only been half tested.
// ---------------------------------------------------------------------------

/// `==` with a real else-branch: BOTH arms must be reached, and the
/// distinctive 7/9 (rather than 1/0) makes a fall-through bug visible
/// instead of accidentally landing on the right answer.
@bare
u64 eqElseU64(u64 a, u64 b) {
  if (a == b) {
    return u64(7);
  } else {
    return u64(9);
  }
}

/// `!=` with a real else-branch. `!=` is an `EqualsCall` wrapped in a
/// `Not`, so its two arms are the INVERSE of eqElseU64's; a lowering that
/// dropped the `Not` would return 7 and 9 the other way round here while
/// leaving eqElseU64 above perfectly correct.
@bare
u64 neElseU64(u64 a, u64 b) {
  if (a != b) {
    return u64(7);
  } else {
    return u64(9);
  }
}

/// `!=` as a WHILE condition rather than an `if` condition. Counts up from
/// `start` until it hits `target`, returning the number of steps taken.
/// Loop conditions are re-evaluated at the top of every iteration, so a
/// lowering that computed the compare only once would spin forever here
/// rather than return a wrong answer.
@bare
u64 stepsUntilEqual(u64 start, u64 target) {
  var i = start;
  var steps = u64(0);
  while (i != target) {
    i = i + u64(1);
    steps = steps + u64(1);
  }
  return steps;
}

/// `==` as a while condition, i.e. the loop runs WHILE the two are equal.
/// Advances `a` until it stops matching `b`; with a != b on entry this
/// must return 0 without ever entering the body.
@bare
u64 advanceWhileEqual(u64 a, u64 b, u64 limit) {
  var x = a;
  var n = u64(0);
  while (x == b) {
    x = x + u64(1);
    n = n + u64(1);
    if (n >= limit) {
      return n;
    }
  }
  return n;
}

// ---------------------------------------------------------------------------
// Composed algorithms -- comparisons doing real work, not just being
// observed one at a time.
// ---------------------------------------------------------------------------

/// Clamp `v` into the inclusive range [lo, hi]. Three comparisons whose
/// boundaries touch: at v == lo and v == hi the result must be v itself,
/// which is what separates `<`/`>` from `<=`/`>=` here.
@bare
u64 clampU64(u64 v, u64 lo, u64 hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

/// The same clamp at u8, where the interesting bound is 255.
@bare
u8 clampU8(u8 v, u8 lo, u8 hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

/// Three-way compare: 0 if a < b, 1 if a == b, 2 if a > b. Mixes an
/// ordering compare and an equality compare in one function, which is the
/// only place the two lowering paths have to agree with each other.
@bare
u64 cmp3U64(u64 a, u64 b) {
  if (a < b) {
    return u64(0);
  }
  if (a == b) {
    return u64(1);
  }
  return u64(2);
}

/// Three-way compare at u16, same contract, returning u16.
@bare
u16 cmp3U16(u16 a, u16 b) {
  if (a < b) {
    return u16(0);
  }
  if (a == b) {
    return u16(1);
  }
  return u16(2);
}

/// Largest of three u32 values. Nested ordering compares with no equality
/// involved; ties must resolve to the (equal) value either way.
@bare
u32 max3U32(u32 a, u32 b, u32 c) {
  var m = a;
  if (b > m) {
    m = b;
  }
  if (c > m) {
    m = c;
  }
  return m;
}

/// Subtractive GCD: `!=`, `>` and a while loop together, with no division.
/// Every iteration re-tests both an equality and an ordering compare, and
/// the loop only terminates if both are exactly right -- a wrong predicate
/// here hangs or returns garbage rather than being off by one.
/// Undefined for a == 0 or b == 0 (the harness never passes those).
@bare
u64 gcdU64(u64 a, u64 b) {
  var x = a;
  var y = b;
  while (x != y) {
    if (x > y) {
      x = x - y;
    } else {
      y = y - x;
    }
  }
  return x;
}

/// Counts how many of 0..n-1 are strictly below `pivot`, i.e. min(n, pivot),
/// computed the long way so the compare runs n times. Exercises `<` inside
/// a loop body rather than as the loop's own condition.
@bare
u64 countBelowU64(u64 n, u64 pivot) {
  var i = u64(0);
  var hits = u64(0);
  while (i < n) {
    if (i < pivot) {
      hits = hits + u64(1);
    }
    i = i + u64(1);
  }
  return hits;
}
