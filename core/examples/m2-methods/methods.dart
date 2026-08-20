// M2 target for instance methods (docs/decisions/0043-instance-methods.md).
//
// Until this landed, DCDart had only top-level functions -- a `HeapObject`
// subclass could hold fields but could not have behaviour. Four of M3's five
// benchmarks describe object-oriented workloads (a JSON parser, a hashmap, a
// tree traversal), so this is a prerequisite of the gate rather than a
// convenience (known-gaps GAP-0035).
//
// A method lowers to an ordinary function whose FIRST parameter is the
// receiver, exactly as `_buildDestructor` (ADR-0022) already synthesized and
// exactly as C does it. No dispatch is involved: the concrete class is
// statically known at every call site.
import '../../runtime/dc-core-bare/prelude.dart';

class Account extends HeapObject {
  u64 balance;
  u64 fees;
  Account(this.balance, this.fees);

  /// Reads two fields through the implicit receiver.
  u64 net() => balance - fees;

  /// Takes an argument alongside the receiver.
  u64 afterDeposit(u64 amount) => balance + amount;

  /// Calls ANOTHER method on `this` -- the case that would break if the
  /// receiver were not threaded through correctly.
  u64 netAfterDeposit(u64 amount) => afterDeposit(amount) - fees;

  /// Composes a method call with arithmetic and a comparison.
  u64 isSolvent() {
    if (net() > u64(0)) {
      return u64(1);
    }
    return u64(0);
  }
}

@bare
u64 net(u64 balance, u64 fees) {
  final a = Account(balance, fees);
  return a.net();
}

@bare
u64 afterDeposit(u64 balance, u64 fees, u64 amount) {
  final a = Account(balance, fees);
  return a.afterDeposit(amount);
}

@bare
u64 netAfterDeposit(u64 balance, u64 fees, u64 amount) {
  final a = Account(balance, fees);
  return a.netAfterDeposit(amount);
}

@bare
u64 solvent(u64 balance, u64 fees) {
  final a = Account(balance, fees);
  return a.isSolvent();
}

/// Two objects, so the receiver argument genuinely has to vary per call
/// rather than being constant-folded.
@bare
u64 compareTwo(u64 b1, u64 f1, u64 b2, u64 f2) {
  final a = Account(b1, f1);
  final b = Account(b2, f2);
  if (a.net() > b.net()) {
    return u64(1);
  }
  return u64(0);
}
