// A second real, hand-written demo program (see core/examples/demo-collatz/
// for the first) -- a tiny bank-account simulator, chosen to exercise a
// DIFFERENT combination of already-verified features than the Collatz demo
// did: Result<T,E>/.propagate() composed with a real heap object's field
// (read AND write, ADR-0032), rather than just arithmetic/bitwise ops in a
// loop.
import '../../runtime/dc-core-bare/prelude.dart';

class Account extends HeapObject {
  u64 balance;
  Account(this.balance);
}

/// Withdraws `amount` from `acct` if there's enough balance, otherwise
/// returns an error (code 1 = insufficient funds). Mutates the account's
/// own field in place -- a real heap-field STORE (ADR-0032), not just a
/// read.
@bare
Result withdraw(Account acct, u64 amount) {
  if (acct.balance < amount) {
    return Result.err(u64(1));
  }
  acct.balance = acct.balance - amount;
  return Result.ok(acct.balance);
}

/// Opens an account with `initial`, withdraws `amount` twice via
/// `.propagate()` -- if the FIRST withdrawal fails, the second is never
/// attempted and the error bubbles straight out with no explicit check at
/// this level (spec §5's whole point).
@bare
Result openAndWithdrawTwice(u64 initial, u64 amount) {
  final acct = Account(initial);
  final afterFirst = withdraw(acct, amount).propagate();
  final afterSecond = withdraw(acct, amount).propagate();
  // afterFirst is intentionally unused beyond exercising .propagate() twice
  // in sequence -- dcc's compile step doesn't lint on this, so no need to
  // work around it with an artificial expression.
  return Result.ok(afterSecond);
}

/// Repeatedly withdraws `amount` until the balance can't cover another
/// withdrawal, returning how many succeeded. The loop CONDITION itself
/// reads a heap object's field directly (`acct.balance`) -- composing a
/// heap field read with `_lowerWhile`'s own condition-lowering, not just
/// its body.
@bare
u64 drainAccount(u64 initial, u64 amount) {
  final acct = Account(initial);
  var count = u64(0);
  while (amount < acct.balance) {
    acct.balance = acct.balance - amount;
    count = count + u64(1);
  }
  return count;
}
