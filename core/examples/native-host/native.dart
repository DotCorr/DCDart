// Native-host conformance target: a real DCDart program compiled with
// `--target host` and linked into an ORDINARY hosted C program with plain
// `clang` -- no `-nostdlib`, no `-ffreestanding`, no hand-written `_start.S`,
// no Linux/x86-64 gate. Until `--target` existed, dcc hardcoded the
// freestanding triple `x86_64-unknown-none-elf`, so its output could not be
// linked into a native macOS (Mach-O) or Windows (COFF) program at all; the
// conformance harnesses worked around that with a Linux/x86-64-only entry
// stub. `--target host` emits a native object for whatever machine is
// running the build, and this target is the proof.
//
// The program itself is a small number-theory workbench, deliberately chosen
// so every answer is INDEPENDENTLY KNOWN and can be asserted exactly rather
// than merely observed:
//
//   * the perfect numbers below 10000 are 6, 28, 496, 8128 -- count 4, sum
//     8658 (a classical result, not something this program defines);
//   * pi(10000) = 1229 and the primes below 10000 sum to 5736396;
//   * sum of i*i for i in 1..n is the closed form n(n+1)(2n+1)/6, which the
//     C harness evaluates separately from the loop DCDart runs;
//   * gcd(1071, 462) = 21 and lcm(1071, 462) = 23562 (Euclid's own worked
//     example);
//   * 3^100 mod 65521 = 23072, 7^4096 mod 65521 = 11838.
//
// Features composed here: heap objects with real ARC (`Range` and `Tally`
// are alive simultaneously across a loop, and every call must return the
// arena to its 64-slot baseline -- the C harness reads the real `dc_free_top`
// symbol to check that), a borrowed `HeapObject` parameter, mutable heap
// fields written on every iteration, `while` loops, early `return`,
// if/else, cross-function calls, and the full operator set at all four
// widths: `+ - *` (trapping), `~/ %` (trapping on a zero divisor),
// `< <= > >= == !=`, and `& | ^ << >>`.
//
// NOTE on a real limit hit while writing this (kept honest rather than
// papered over): a heap-typed local may NOT be declared inside a `while`
// body -- dcc-lower rejects it with "naive ARC has no release policy for a
// loop back edge yet". So every allocation below happens once, before its
// loop. See docs/known-gaps.md.
import '../../runtime/dc-core-bare/prelude.dart';

/// A half-open interval [lo, hi). Immutable heap object, passed BORROWED
/// (no `@owned`) into the helpers below -- the default ownership per
/// ADR-0019, so no retain/release happens at those calls.
class Range extends HeapObject {
  final u64 lo;
  final u64 hi;
  const Range(this.lo, this.hi);
}

/// Mutable accumulator: both fields are written on every iteration of the
/// loops below, from a single allocation that outlives the whole loop.
class Tally extends HeapObject {
  u64 count;
  u64 total;
  Tally(this.count, this.total);
}

/// Width of a borrowed `Range`. Exists to prove a `HeapObject`-typed
/// parameter really is readable across a call boundary in a natively
/// linked object, not just within one function.
@bare
u64 rangeWidth(Range r) {
  return r.hi - r.lo;
}

/// Euclid's algorithm, using the real `%` operator (ADR-0036). `%` traps on
/// a zero divisor, which is why the loop guard is `y > 0` and not something
/// that could let a zero through.
@bare
u64 gcd(u64 a, u64 b) {
  var x = a;
  var y = b;
  while (y > u64(0)) {
    final t = x % y;
    x = y;
    y = t;
  }
  return x;
}

/// Least common multiple. Divides BEFORE multiplying (`(a ~/ g) * b`, not
/// `(a * b) ~/ g`) because `*` traps on overflow -- the naive spelling
/// would trap for large inputs where the answer itself is representable.
@bare
u64 lcm(u64 a, u64 b) {
  if (a < u64(1)) {
    return u64(0);
  }
  if (b < u64(1)) {
    return u64(0);
  }
  final g = gcd(a, b);
  return (a ~/ g) * b;
}

/// Sum of the proper divisors of `n` (divisors below `n`, including 1).
/// Trial division up to sqrt(n), expressed as `d * d <= n` -- one `*`, one
/// `<=`, one `%` and one `~/` per step, with the `q > d` guard stopping a
/// perfect square from counting its root twice.
@bare
u64 sumProperDivisors(u64 n) {
  if (n < u64(2)) {
    return u64(0);
  }
  var total = u64(1);
  var d = u64(2);
  while (d * d <= n) {
    if (n % d == u64(0)) {
      total = total + d;
      final q = n ~/ d;
      if (q > d) {
        total = total + q;
      }
    }
    d = d + u64(1);
  }
  return total;
}

/// 1 if `n` is prime, 0 otherwise. Uses `&` for the even test (`n & 1`),
/// `!=` for the composite test, and steps the trial divisor by 2.
@bare
u64 isPrime(u64 n) {
  if (n < u64(2)) {
    return u64(0);
  }
  if (n < u64(4)) {
    return u64(1);
  }
  if ((n & u64(1)) == u64(0)) {
    return u64(0);
  }
  var d = u64(3);
  while (d * d <= n) {
    if (n % d == u64(0)) {
      return u64(0);
    }
    d = d + u64(2);
  }
  return u64(1);
}

/// How many perfect numbers (sumProperDivisors(n) == n) lie in [lo, hi).
/// Two heap objects are live at once here -- an immutable `Range` and a
/// mutable `Tally` -- and both must be released before the call returns,
/// which the harness checks against the real arena free-list counter.
@bare
u64 perfectCount(u64 lo, u64 hi) {
  final range = Range(lo, hi);
  final tally = Tally(u64(0), u64(0));
  var n = range.lo;
  while (n < range.hi) {
    if (sumProperDivisors(n) == n) {
      tally.count = tally.count + u64(1);
      tally.total = tally.total + n;
    }
    n = n + u64(1);
  }
  return tally.count;
}

/// Sum of the perfect numbers in [lo, hi) -- same pass, other field.
@bare
u64 perfectSum(u64 lo, u64 hi) {
  final range = Range(lo, hi);
  final tally = Tally(u64(0), u64(0));
  var n = range.lo;
  while (n < range.hi) {
    if (sumProperDivisors(n) == n) {
      tally.count = tally.count + u64(1);
      tally.total = tally.total + n;
    }
    n = n + u64(1);
  }
  return tally.total;
}

/// pi(limit): how many primes are below `limit`. Also folds in the borrowed
/// `Range` read (`rangeWidth`) so the returned value is wrong -- not merely
/// unverified -- if a borrowed heap parameter fails to survive the call.
@bare
u64 primeCount(u64 limit) {
  final range = Range(u64(2), limit);
  final tally = Tally(u64(0), u64(0));
  if (rangeWidth(range) < u64(1)) {
    return u64(0);
  }
  var n = range.lo;
  while (n < range.hi) {
    if (isPrime(n) == u64(1)) {
      tally.count = tally.count + u64(1);
      tally.total = tally.total + n;
    }
    n = n + u64(1);
  }
  return tally.count;
}

/// Sum of the primes below `limit` -- same pass, other field.
@bare
u64 primeSum(u64 limit) {
  final range = Range(u64(2), limit);
  final tally = Tally(u64(0), u64(0));
  var n = range.lo;
  while (n < range.hi) {
    if (isPrime(n) == u64(1)) {
      tally.count = tally.count + u64(1);
      tally.total = tally.total + n;
    }
    n = n + u64(1);
  }
  return tally.total;
}

/// Sum of i*i for i in 1..n, accumulated into a heap object. The C harness
/// checks this against the closed form n(n+1)(2n+1)/6, which shares no code
/// with the loop below.
@bare
u64 sumOfSquares(u64 n) {
  final tally = Tally(u64(0), u64(0));
  var i = u64(1);
  while (i <= n) {
    tally.count = tally.count + u64(1);
    tally.total = tally.total + i * i;
    i = i + u64(1);
  }
  return tally.total;
}

/// Decimal digit sum -- `~/` and `%` by 10, the textbook use for integer
/// division that DCDart could not express at all before ADR-0036.
@bare
u64 digitSum(u64 n) {
  var rest = n;
  var total = u64(0);
  while (rest > u64(0)) {
    total = total + rest % u64(10);
    rest = rest ~/ u64(10);
  }
  return total;
}

/// Modular exponentiation at u32, square-and-multiply. `mod` is required to
/// be at most 65536 by the caller so that `b * b` cannot overflow u32 and
/// trap; the harness only ever passes 65521. Exercises u32 `*`, `%`, `&`,
/// `>>`, `>` and `==` together.
@bare
u32 modPow32(u32 base, u32 exp, u32 mod) {
  if (mod < u32(2)) {
    return u32(0);
  }
  var result = u32(1);
  var b = base % mod;
  var e = exp;
  while (e > u32(0)) {
    if ((e & u32(1)) == u32(1)) {
      result = (result * b) % mod;
    }
    b = (b * b) % mod;
    e = e >> u32(1);
  }
  return result;
}

/// 0 + 1 + ... + (n-1) at u16. Closed form n(n-1)/2; the harness passes
/// n = 300, so the answer is 44850, comfortably inside u16 -- `+` traps, so
/// a wider n would abort rather than wrap.
@bare
u16 triangleU16(u16 n) {
  var i = u16(0);
  var total = u16(0);
  while (i < n) {
    total = total + i;
    i = i + u16(1);
  }
  return total;
}

/// Euclid again, at u8 -- the narrowest width, proving `%` and `>` really
/// are wired at every width and not just u64.
@bare
u8 gcdU8(u8 a, u8 b) {
  var x = a;
  var y = b;
  while (y > u8(0)) {
    final t = x % y;
    x = y;
    y = t;
  }
  return x;
}
