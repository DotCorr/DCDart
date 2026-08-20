# ADR-0036: `~/` and `%`, with an explicit zero-divisor trap

**Status:** decided — implemented and verified (correct results; divide-by-zero halts with SIGTRAP)

## Context

ADR-0035 completed multiplication and comparison without needing new DC-IR instructions. Division is
the one that genuinely does: there is no `IDiv`/`IRem` in `dc-ir/lib/instructions.dart`, and no
`llvm_emit` case for them.

Division also fails differently from the other arithmetic. `+`, `-` and `*` overflow, and LLVM offers
`llvm.*.with.overflow.*` intrinsics that report it. Division does not overflow that way; it has a
**zero divisor**, and in LLVM `udiv iN %a, 0` is not a hardware fault you can lean on — it is
immediate undefined behaviour producing `poison`, and the optimizer may delete surrounding code.
DCDart traps by default (spec §4.1), so relying on whatever the target CPU happens to do is not an
option.

## Options for spelling it

1. `/`, matching C.
2. `~/`, Dart's integer-division operator.

**Option 2.** In Dart, `/` returns a `double`. DCDart has no floating point, so defining `/` to mean
integer division would read as float division to every Dart programmer and silently mean something
else. `~/` is already the language's integer-division operator and needs no re-education. The cost is
that C programmers must learn one unfamiliar spelling; that is much cheaper than a familiar spelling
that lies.

## Decision

New `IDiv` and `IRem` DC-IR instructions, deliberately **without** an `Overflow` field — there is no
overflow intrinsic for division and nothing for the flag to select. Signedness comes from the
operands' own `DCInt.signed`, choosing `udiv`/`sdiv` and `urem`/`srem`, the same mechanism `IShr`
already uses to pick `lshr` vs `ashr` rather than splitting one concept across two instruction
classes.

`_emitDivRem` in `llvm_emit.dart` emits the guard explicitly:

```llvm
%divzero = icmp eq i64 %rhs, 0
br i1 %divzero, label %divtrap, label %divok
divtrap:
  call void @llvm.trap()
  unreachable
divok:
  %dest = udiv i64 %lhs, %rhs
```

Note the divide lands in `divok`, so it is only ever reached with a non-zero divisor. This differs
from `_emitArith`, where the value is computed *before* the branch and the trap only rejects it
afterwards.

**Block-splitting invariant.** This splits one DC-IR block into three real LLVM blocks, so any later
`phi` naming this block as a predecessor must name the *final* label. That is exactly the latent bug
ADR-0028 fixed for `Alloc`/`Release`/`WeakLoad`, so the split goes through `_FunctionEmitter.startBlock`
which already tracks it. Any future block-splitting instruction must do the same.

**Signed division is rejected outright**, not emitted. It needs a second guard beyond the zero check —
`INT_MIN / -1` overflows and is UB in LLVM too. No signed sized-int type has prelude support, so the
path is unreachable; it throws a specific backend error rather than emitting codegen without its
guard, so a future signed type cannot silently inherit something wrong (GAP-0024).

`dc-elide`'s `referencedValueIds` needed the two new cases. It did not need finding by hand: the
sealed `DCInstruction` hierarchy made the analyzer reject the incomplete switch, which is precisely
the safety net ADR-0031 relies on.

## Consequences

- Real algorithms that need division now work. Verified: Euclid's gcd via `%`, digit-sum via `~/ 10`
  and `% 10`, primality by trial division.
- `x ~/ u64(0)` halts with SIGTRAP instead of producing poison. Verified by running it.
- The trap costs a compare and a branch per division. Not optimized away when the divisor is a
  non-zero constant — a real (small) cost, recorded rather than hidden. Constant-folding it is
  optimizer work, and M3 is the milestone that decides whether it matters.
- No floating point, and no `/` operator, remain deliberate.
