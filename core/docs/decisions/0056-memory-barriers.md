# ADR-0056: Memory barriers — `fence(Ordering.…)`

**Status:** decided — implemented and verified (`tests/conformance/fence/`)

## Context

GAP-0033: `volatile` (ADR-0041) stops the optimizer deleting, duplicating or reordering an access
relative to *other volatile accesses*. That is what single-core MMIO correctness needs. It is not a
memory-ordering model — `volatile` is not atomic, not a fence, and says nothing about multi-core
visibility or about ordering relative to non-volatile accesses. `DCDART_SPEC.md` §6 asks for
"explicit ordering" and lists `fence(Ordering.acquire)` in its required-primitives table. Nothing
implemented it.

## Ordering is not atomicity, and this is a separate unit for that reason

ADR-0055 landed atomics in the same commit as this. They are two mechanisms and neither implies the
other:

- **Atomicity** is a property of ONE access: it cannot be interleaved.
- **Ordering** is a property of the relationship BETWEEN accesses: which of them can be observed to
  have happened first.

An atomic RMW orders nothing beyond itself. A fence makes no access indivisible. A kernel needs both.
They get separate ADRs, separate DC-IR nodes and separate conformance targets, because a single node
carrying both would invite code that asks for one and silently relies on the other's guarantee.

## Decision

Spec §6's own spelling, which is writable as-is (unlike ADR-0055's `Atomic<u32>`, which needs generic
classes):

```dart
data.value = payload;
fence(Ordering.release);
ready.value = u32(1);
```

Five orderings:

| `Ordering` | lowers to | x86-64 machine code |
|---|---|---|
| `acquire` | `fence acquire` | *nothing* |
| `release` | `fence release` | *nothing* |
| `acqRel` | `fence acq_rel` | *nothing* |
| `seqCst` | `fence seq_cst` | `mfence` |
| `compilerOnly` | `call void asm sideeffect "", "~{memory}"()` | *nothing, on any target* |

### `Ordering` is a class with `const` instances, not a Dart `enum`

An `enum` implies `dart:core::Enum` as a supertype, and `dcc-lower` compiles with
`--no-link-platform`, under which an unbound platform node is one this compiler cannot safely inspect
— the same hazard the prelude documents for `Pointer._address`.

Each instance carries its own NAME as a `const String`, and `dcc-lower` reads that. This is ADR-0040's
lesson applied again: a `const` field's references are inlined at every use site, so `Ordering.release`
does not arrive as a `StaticGet` naming a field, it arrives as a `ConstantExpression` wrapping an
`InstanceConstant`. **Names survive constant evaluation; identity does not.** Carrying the name rather
than an index also means a malformed call produces an error naming the ordering.

### `compilerOnly` exists, and it is the odd one out

LLVM has **no** `fence` ordering meaning "constrain the compiler and emit nothing" — `fence monotonic`
is not even legal IR. The mechanism is an empty `asm sideeffect` with a `~{memory}` clobber, which is
exactly what Linux's `barrier()` is.

It was included rather than trimmed for one concrete reason: **it is the correct and sufficient
barrier for `oscortex_core` as it exists today** — single core, interrupts as the only concurrency,
and interrupt entry is itself a serializing event. Omitting it means a kernel author reaches for
`seqCst`, buying an `mfence` that does nothing, or for nothing at all, which is a real bug. It is
NOT sufficient at the first second core, and both the prelude and this ADR say so where that author
will read it.

## Verification, and an honest limit that is unusual enough to state twice

`tests/conformance/fence/`.

On x86-64, TSO already provides acquire and release ordering in hardware, so three of the five
orderings correctly emit **no machine instruction at all**. They are not decorative — they constrain
the COMPILER, which is free to reorder the surrounding accesses without them — but that constraint is
invisible in a disassembly. So:

- **The discriminator for those three is the emitted LLVM IR**, the same resolution ADR-0041/GAP-0036
  reached for `volatile` and for the same reason. The harness requires each of `fence acquire`,
  `fence release`, `fence acq_rel`, `fence seq_cst` and the memory-clobbering asm to appear, and
  requires each to appear **exactly once** — a lowering that collapsed all five onto one ordering
  would satisfy a presence check but not a count.
- **`seqCst` is asserted in the disassembly**, as `mfence`, at every optimization level. It is the
  only ordering that forbids StoreLoad reordering — a store to one location followed by a load of a
  different one, which TSO permits to be reordered and which Dekker's algorithm and every seqlock
  reader depend on not being.
- **The four cheap orderings are asserted to emit NO serializing instruction.** This is the assertion
  with teeth. Mapping every ordering to seq_cst is the easy, safe-looking mistake; it would satisfy
  every other check in the file while making each barrier in the kernel cost an `mfence` it does not
  need.

**What no test here can currently show is a differential** — "without the fence the compiler reorders
these two accesses, with it it does not". Every access in `examples/m2-fence/fence.dart` goes through
`Pointer<T>.value`, which ADR-0041 makes **volatile**, and volatile accesses already may not be
reordered relative to one another. So on today's language these fences are redundant with a guarantee
`Pointer<T>` hands out for free.

That is not a reason to skip them. It is a reason to write it down: the redundancy ends the moment
GAP-0034's device-memory/ordinary-memory type split lands and ordinary pointer access stops being
volatile, and at that point these fences become load-bearing with no code change. Recorded as
GAP-0043 rather than left for someone to rediscover as a puzzling test.

**ARC delta: zero.** `dc-objdump --arc` reports all zeros for every function in
`examples/m2-fence/fence.dart`; `examples/m2-heap/box.dart` is unchanged at `alloc=1 release=1`.

## Consequences

- GAP-0033 is closed for *fences*. It is NOT closed for the rest of a memory-ordering model: DCDart
  still has no happens-before relation written down anywhere, no acquire/release **loads and stores**
  (as distinct from standalone fences), and no statement about what a `@volatile` access orders with
  respect to a fence. A standalone fence is the coarser and safer of the two idioms and is what a
  kernel writes; per-access ordering is the faster one. GAP-0044.
- `oscortex_core`'s publish/consume patterns — fill a buffer, then set the flag saying it is filled —
  become expressible with the ordering stated in the source rather than assumed from the target.
- **No ordering is emitted for `@interrupt` entry/exit**, and nothing here changes that. Code relying
  on "interrupt entry serializes" is relying on a property of the hardware and the single-core
  configuration, not on anything the language promises. That assumption is exactly what
  `Ordering.compilerOnly`'s doc comment asks authors to state explicitly.
- The `mfence`-vs-nothing split is target-specific and this ADR's table is x86-64 only. On AArch64
  every one of acquire/release/acqRel/seqCst emits a real `dmb`, and the conformance harness's step 3
  would need a per-target expectation before `bare-aarch64` is exercised. Recorded here rather than
  discovered when that target is first used.
