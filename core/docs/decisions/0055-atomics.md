# ADR-0055: Atomic read-modify-write

**Status:** decided — implemented and verified (`tests/conformance/atomic/`)

## Context

ADR-0051 gave DCDart mutable global storage, and `oscortex_core` consumed it the same day. It gave
no atomicity guarantee at all, and said so — that is GAP-0039, filed by ADR-0051's own consequences
section. `examples/m2-bss/bss.dart`'s `bumpTicks()` is a load, an add and a store on a `@bss` word:

```
  movq (%rip), %rax
  incq %rax
  movq %rax, (%rip)
```

The live case is the PIT interrupt handler incrementing a tick counter the shell reads. On one core,
interrupt entry and exit serialize the sequence, so **the wrong code works**. It keeps working until
the first second core, and then fails as a lost tick, which reads as a scheduler bug rather than a
language bug. That property — correct today, silently wrong later, and wrong in a way that points at
the wrong subsystem — is what makes this worth building before SMP rather than after.

`DCDART_SPEC.md` §6's required-primitives table already lists this: *"Atomics | `Atomic<u32>`, CAS,
fetch-add"*. Nothing implemented it.

## Why this is decidable without unfreezing the memory model

`CLAUDE.md` rule 4 freezes §3. This is the same argument ADR-0051 made for `@bss` and it holds for
exactly the same reason: **an atomic here operates on raw integers through a raw `Pointer<T>`.** No
ARC reference is involved, so none of §3's questions — retain/release conventions, lifetimes, ARC
roots — arise. This ADR changes nothing about how a `HeapObject` is counted.

That boundary is worth stating sharply, because the adjacent question **is** a §3 change and it is
not decided here: **ARC's own refcounts are non-atomic** (`llvm_emit.dart`'s `_emitRetain` /
`_emitRelease` are a plain `load i32` / `add` / `store i32`). Building atomics makes that
inconsistency visible for the first time, and it is frozen at M3 like everything else in §3.
Escalated as `docs/escalations/0007-arc-refcount-atomicity.md` rather than decided here or, worse,
inherited from whatever this implementation happened to do.

## Decision

Static methods on a non-generic `Atomic` class, taking a `Pointer<T>`:

```dart
final p = Pointer<u64>.fromAddress(Bss.addressOf(tickCounter));
final previous = Atomic.fetchAdd(p, u64(1));
```

`load`, `store`, `exchange`, `fetchAdd`, `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`. Widths `u8`,
`u16`, `u32`, `u64`.

### Not spec §6's `Atomic<u32>` type, and the reason is mechanical

A wrapper *type* needs generic CLASSES, which do not exist (GAP-0040 — ADR-0052 monomorphized
generic functions only). So spec §6's literal spelling is not writable today. The methods are generic
FUNCTIONS, which are, and the element width is read off the `Pointer<T>` argument rather than
restated in the method name (`fetchAdd64`). The wrapper type is a strictly additive change once
generic classes land; nothing here has to move to get it.

`dcc-lower` recognizes these **ahead of** the generic-call path, so a call never reaches the
monomorphizer. They are generic only so one declaration covers every width; there is no body to
specialize, and queueing a specialization would emit a symbol for a function with no machine
representation.

### Not `@bss`-only

It takes a `Pointer<T>`, so it works on any address — a `@bss` counter, a heap payload field, a
device mailbox. `@bss` is only where the hazard was first noticed.

### Sequentially consistent, with no `Ordering` parameter

Every operation is seq_cst. This is the one decision here with a real cost, so the reasoning is
recorded rather than assumed:

- On x86-64 a `lock`-prefixed RMW is **already** a full barrier. seq_cst costs a fetch-and-op exactly
  nothing — verified in the emitted code, which is `lock xaddq` either way.
- Only a seq_cst `store` is more expensive than a relaxed one: `xchg` rather than `mov`.
- **The asymmetry decides it.** Starting strong and relaxing later is a widening: no program compiled
  today becomes incorrect when `Ordering` is added as an optional parameter. Starting relaxed and
  tightening later would silently break every program that assumed the default was enough. Recorded
  as GAP-0044 so the relaxation is a queued item rather than a discovery.

### Not compare-exchange

`cmpxchg` returns two values — the previous contents and whether the swap happened — and DC-IR has
**no multi-result instruction**, by an explicit design rule stated in `instructions.dart`'s own
header ("if a future instruction genuinely needs to define more than one value, that's a new node
shape to design then"). Adding one for this is a larger change than the rest of this ADR combined,
and `exchange` already makes the thing a kernel needs first — a test-and-set spinlock — expressible:
swap 1 in, and you hold the lock iff 0 came out. GAP-0041.

### Atomic arithmetic WRAPS

This is the single exception to spec §4.1's "arithmetic traps by default", and it is not a choice.
An atomic RMW's overflow is only observable **after** the write has committed, and there is nothing
to roll back to. Stated in the prelude, the IR node and here, rather than left as the one silent
inconsistency in the integer model. GAP-0044.

## The rule-1 property, which is the actual risk in this unit

LLVM lowers an atomic to a real instruction only when the type is an integer of a power-of-two byte
size the target supports natively. Outside that set it emits a call to `__atomic_load` /
`__atomic_fetch_add` / … from **libatomic**. In a `@bare` object that is an undefined runtime symbol
— a `CLAUDE.md` rule 1 violation, and a failed change even with a green suite.

So `_atomicWidthBytes` in `llvm_emit.dart` is not defensive tidiness; it is where that guarantee is
enforced, and it rejects a non-integer or unsupported operand by name. The conformance harness checks
the outcome independently, by grepping the object's undefined symbols for `__atomic_*` / `__sync_*`
at every optimization level — separately from `verify-freestanding.sh`, so the diagnostic identifies
this specific failure rather than reporting "some symbol leaked".

## Verification

`tests/conformance/atomic/` is shaped around one fact: **atomicity is invisible to every technique
the other harnesses in this repo use.** A single-threaded run cannot tell `lock xaddq` from
`movq; incq; movq`. Value-checking is therefore the *weakest* step here and is labelled as such.

The two steps that discriminate:

- **No libatomic.** Checked by name, at `-O0/-O1/-O2/-O3/-Os`.
- **The paired disassembly.** `examples/m2-atomic/atomic.dart` contains `plainBumpTicks` and
  `atomicBumpTicks` — the same read-modify-write on the same `@bss` word, one non-atomic and one
  atomic. The harness requires a `lock` prefix in the atomic one **and its absence in the plain one**.
  The absence half is what makes the test mean anything: without it a `lock`-everything backend would
  pass, and the negative control is asserted first so that a failure there reports that every
  assertion after it is meaningless.

Mutation-tested rather than assumed: rewriting `atomicBumpTicks` back to `p.value = p.value + u64(1)`
makes the harness fail with the right message, while `main.c`'s value checks all still pass.

Measured, per operation, on `bare-x86_64` at the `-O2` ADR-0042 ships:

| source | emitted |
|---|---|
| `Atomic.fetchAdd` / `fetchSub` | `lock xaddq` / `lock xaddq` after `negq` |
| `Atomic.fetchOr` / `fetchAnd` / `fetchXor` | `lock cmpxchgq` retry loop (result is used) |
| `Atomic.exchange`, `Atomic.store` | `xchgq` / `xchgl` — implicitly locked on x86, no prefix encoded |
| `Atomic.load` | plain `movq` — a seq_cst load needs nothing more under TSO |
| `plainBumpTicks` (control) | `movq` / `incq` / `movq`, no prefix |

`xchg` is asserted by mnemonic rather than by prefix, because x86 asserts the bus lock implicitly for
a memory-operand `xchg` and does not encode a `lock` byte. A prefix-based check would wrongly fail it.

**ARC delta: zero.** `dc-objdump --arc` reports `alloc=0 retain=0 release=0` for every function in
both new examples, and the reference heap example (`examples/m2-heap/box.dart`) still reports
`alloc=1 release=1`. This unit touches no ARC codegen; the only change to `dc-elide` is two operand
cases in `referencedValueIds`, a read-only analysis.

## Consequences

- `oscortex_core`'s tick counter and free-frame bitmap become correct-by-construction rather than
  correct-by-single-core. The bitmap is `fetchOr`/`fetchAnd`, not `fetchAdd` — GAP-0039 names "a
  corrupted bitmap entry" as the second failure mode and it is a different operation.
- A test-and-set spinlock is expressible. A lock-free structure needing ABA-safe update is not
  (GAP-0041).
- **Alignment is neither checked nor representable.** An under-aligned atomic is undefined at the
  hardware level — a `lock` operation spanning a cache line is not atomic on some x86 parts and
  faults on others — and `DCPointer` carries no alignment for anything to check. GAP-0042.
- This says nothing about ORDERING. A fence is ADR-0056, deliberately a separate unit with a separate
  IR node: atomicity is a property of one access, ordering is a property of the relationship between
  two, and a node carrying both would invite code that asks for one and silently relies on the other.
- **The M3 benchmark suite should now measure ARC both ways** (see escalation 0007). If ARC refcounts
  later become atomic, an M3 number measured with non-atomic ones is invalid, and M3 is the gate that
  freezes the model.
