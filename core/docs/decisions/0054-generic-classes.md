# ADR-0054: Generic classes, monomorphized per instantiation

**Status:** decided — implemented and verified (`tests/conformance/generic-class/`)

## Context

ADR-0052 monomorphized generic FUNCTIONS and opened GAP-0040 in the same breath: generic CLASSES were
not implemented, which blocks every container and therefore M3's hashmap benchmark
(`ROADMAP.md`'s five-benchmark suite). This is one of the last M3 prerequisites; `String`/`Str`
(ADR-0053) landed just before it.

The question was not "monomorphize or not" — `DCDART_SPEC.md` §4.2 settles that — but whether
ADR-0052's mechanism **extends** to classes or whether classes need a second one. Two generic
instantiation mechanisms in one compiler is a permanent tax, so the extension had to be shown to
work rather than assumed.

## Decision

**It extends, and the extension is one idea: the unit that has a machine representation is the
INSTANTIATION, not the class.**

ADR-0052's insight was that a generic function is a template with no machine representation, because
`T` has no size. The same sentence is true of a generic class, and it is true of strictly more:
`Box<T>` has no field layout, no payload size, no destructor and no method bodies. So `_HeapLayouts`
— which owned all four of those, keyed by `Class` — is now keyed by a `_ClassInstance`: a class plus
its type arguments.

A **non-generic class is the degenerate instantiation** with an empty type-argument list, whose
mangled name is its own name. That is what keeps this one mechanism rather than two: `Account_net`,
`BoxHolder_dtor` and every other M2 symbol keeps the name, layout and body it had, and the whole of
M2 flows through the new path unchanged. The conformance suite went 35 → 36 with no other row moving.

Naming reuses ADR-0052's mangling **verbatim, via the same function** — `Box$u64`, `Box$Node_dtor`,
`Box$u64_unwrap` — so a class instantiation and a function specialization can never disagree about
what a type is called. `$` cannot appear in a Dart identifier, so a specialization can never collide
with a hand-written name, which matters because `linkName` is emitted verbatim (spec §9).

Discovery and queueing follow ADR-0052 exactly: instantiations are found at **use sites during
lowering**, not in a separate discovery pass, because walking use sites twice means two
implementations of one traversal that are free to disagree. Three site kinds discover an
instantiation — a constructor invocation (`Box<u64>(v)`, which names its type arguments outright), a
signature type (a parameter or return of type `Box<u64>`, so a function that only ever *receives* one
still gets its methods and destructor), and a field type (`final Box<Node> inner`, so an
instantiation reachable only by being held is still emitted).

The drain is now **one fixpoint loop over two queues**, because they feed each other: lowering
`pick$u64` can construct a `Box<u64>`, and lowering `Box$u64`'s methods can call `pick<u64>`. Two
sequential drains would have been a latent bug that only fires on a program combining both.

## The ARC consequence, which is the whole reason this is not a layout refactor

**Every instantiation gets its own destructor decision, and the decision genuinely differs.**

```
Box<u64>    field: DCInt.u64        payload 8    destructor: NONE
Box<u32>    field: DCInt.u32        payload 4    destructor: NONE
Box<Node>   field: DCHeapPointer    payload 8    destructor: Box$Node_dtor
```

`Box<u64>` and `Box<Node>` are the pair that matters: **identical payload size**, and opposite ARC
obligations. `Box<Node>`'s field must be released when the box dies or the `Node` leaks one arena
slot per construction; `Box<u64>`'s must not be touched at all, because releasing it would treat a
`u64` as a heap pointer. An implementation that keyed layout on size, or answered "does this class
need a destructor" per class rather than per instantiation, passes every value check and is wrong in
exactly one of those two directions depending on which way it guessed.

This falls out of the design rather than being special-cased: `destructorNameFor` computes the
instantiation's layout and asks whether any field lowered to a `DCHeapPointer`. The retain/release
shape at construction follows the same way — `_lowerHeapConstruction` retains a constructor argument
only when the field's lowered type is a heap pointer, which is now an instantiation-dependent fact.

The conformance target asserts the negative directly: `Box$u64_dtor` and `Box$u32_dtor` **must not
exist** in the symbol table. A leak test alone would not catch a spurious value-type destructor —
that failure is a released integer, not a leak.

Nothing about the object header changed. `cls` is still the destructor slot ADR-0022 defined, still
written by `Alloc`, still dispatched through by `Release`. Monomorphization multiplies the number of
distinct destructors but not the shape of the header, so spec §3.1 is untouched — see
`docs/escalations/0009` for the part of this that is nevertheless a pre-freeze question.

## What bounds code size

Monomorphization's classic failure is unbounded code growth, and with generic classes the unbounded
case is real rather than theoretical: `f<T>` calling `f<Box<T>>` builds `Box<Box<Box<…>>>` forever.
GAP-0040 recorded that as deliberately unguarded, on the grounds that generic classes did not exist
to build the infinite type with. They exist now, so it is guarded now.

**Deduplication.** Both queues are keyed by mangled name, and that keying *is* the deduplication:
a thousand call sites asking for `Box<u64>` produce one key, one layout, one destructor and one copy
of each method. There is no separate identical-body merge step and none is needed — two
instantiations with identical mangled names are the same instantiation by construction.

**Two bounds, because they catch different shapes.** A type-argument nesting limit
(`_maxTypeArgNesting = 8`) catches the recursive case directly and names the type that ran away; a
total-instantiation limit (`_maxInstantiations = 512`) is the backstop for merely-excessive breadth,
where no single type is deep but the cross product is large. Both are compile errors naming what was
being instantiated, never silent truncation — a build that quietly emitted a truncated instantiation
set would be worse than either rejecting or hanging, because the program that ran would not be the
program that was written. `examples/m3-generic-class/recursive_reject.dart` is a permanent negative
fixture, and the harness runs it **under a timeout**, treating a hang as its own failure: a bound
that is merely slow is not a bound.

**Nothing measures the actual code-size cost yet**, and that is the same omission ADR-0052 recorded.
Escalation 0009 argues it should be measured inside M3 rather than after it.

## Two real bugs this found, both pre-existing

Neither was in the new code; both were latent and became reachable the moment a type argument could
itself be generic.

**ADR-0052's mangling dropped a type argument's own type arguments.** `_typeArgMangle` returned an
`InterfaceType`'s class name and nothing else, which was invisible while no `InterfaceType` type
argument could be generic. It is not invisible now: `pick<Box<u64>>` and `pick<Box<Node>>` both
mangled to `pick$Box`, and a queue that deduplicates by mangled name would have emitted **one body
for two different layouts**. Now recursive, and shared with `_ClassInstance.mangledName`.

**`_lowerCalleeType` only substituted a bare `T`.** A callee signature saying `Box<T>` is not a
`TypeParameterType`, so the old top-level check skipped it entirely and passed `Box<T>` down with the
callee's `T` unbound. That surfaced far away as *"unsupported struct field type TypeParameterType"*
naming a class the programmer never wrote. Substitution is structural now (`_substituteType`), which
is the same widening `_resolveTypeParameter` needed for the same reason.

## What is deliberately NOT here

- **Generic METHODS on classes** (`R map<R>()`) would need one body per (class instantiation × method
  type arguments) pair. Refused by name at the call site rather than half-handled — GAP-0055.
- **Generic class hierarchies.** No `class Sub<T> extends Base<T>`; DCDart has no HeapObject
  subtyping to speak of yet and this ADR adds none.
- **`Weak<Box<T>>`.** Untested; `Weak<T>` lowers to a placeholder pointee like `DCHeapPointer` does,
  so it is likely to work, and "likely" is not a claim this ADR makes.

## `@bare` viability

Unchanged, and that is the point. Generic classes add **no new runtime symbol, no new DC-IR
instruction and no new backend knowledge**: the lowered type of a `Box<u64>` reference is the same
`DCHeapPointer(DCVoid())` placeholder every heap reference has already used since ADR-0019 (GAP-0003),
because layout is resolved from the access site's instantiation, not from the DCValue's type. Once
`T` is concrete in `_HeapLayouts`, `dc-elide`, `dc-objdump` and the backend see ordinary classes and
need no knowledge of generics whatsoever — the same property ADR-0052 traded on, which is the
strongest evidence that this is one mechanism rather than two.

Allocation is still ADR-0015's arena, so generic classes inherit escalation 0002's open
allocator-threading problem exactly as every other heap object does, and neither worsen nor improve
it. A generic container is precisely the code that will want an explicit `Allocator` first, which is
noted in GAP-0054 rather than solved here.

## Verification

`tests/conformance/generic-class/`, four independent assertion families because no one of them
catches the others' failures:

1. **Freestanding** — `verify-freestanding.sh` over the `bare-x86_64` object. CLAUDE.md rule 1.
2. **Symbol table** — `Box$u64_unwrap`, `Box$u32_unwrap`, `Box$Node_unwrap`, `Box$Node_dtor` present;
   `Box_unwrap`, `Box_dtor`, `Box$u64_dtor`, `Box$u32_dtor` absent. A wrong implementation emitting
   one shared `Box` body computes every right answer in (4); only the symbols show whether
   specialization happened.
3. **ARC counts** — exact per-function `Alloc`/`Retain`/`Release` via `dc-objdump --arc`, the only
   level they are countable at (ADR-0024). Includes the assertion that the value-typed instantiations
   carry **no retain at all**.
4. **Behaviour and leak** — values read back at the right width (the `u32` cases use values that only
   survive a correct 4-byte round trip), and the heap back to baseline over 1200 iterations across
   three instantiations, well past the arena's 64 slots.

Plus the negative fixture above. The link step goes through
`tests/conformance/_lib/hosted-link.sh`, so this harness has no Linux/x86-64 host gate (GAP-0048).

The ARC derivation worth recording, because it is the one number that is not obvious. In `boxNode`:
`Node(v)` allocs; `Box<Node>(n)` allocs and retains `n` (storing a borrowed constructor parameter
into a field the new object outlives, ADR-0020); `b.unwrap()` retains its result into a local
(ADR-0017); the return releases all three. ADR-0025's pass 3 then **elides the `unwrap` alias pair**,
giving `alloc=2 retain=1 release=2`. That elided number is what the harness asserts, so a pass that
stops firing here fails the test. It is balanced, which is what makes it correct rather than merely
smaller: the `Node` carries +2 (its `Alloc`, the field-store retain) against −2 (the local release,
and `Box$Node_dtor`'s release of the field); the `Box` carries +1/−1.

## Consequences

- **GAP-0040 is closed.** Containers become writable, and M3's hashmap benchmark is unblocked on this
  axis. Closures (landing in parallel) are the other prerequisite; nothing here depends on them, and
  a generic class holding a closure will need whatever ownership rule that unit establishes.
- **GAP-0040's unguarded recursion is closed too**, by the bounds above, with a permanent fixture.
- Code size grows with the number of *distinct* instantiations, deduplicated by mangled name. Nothing
  measures it — escalation 0009.
- Three new gaps, all found by probing the boundary rather than by guessing: GAP-0054 (an ADR-0025
  elision hazard this made easier to reach, pre-existing), GAP-0055 (generic methods), GAP-0056
  (`_receiverInstanceOrNull` recovers type arguments structurally from the receiver expression, and
  the set of shapes it understands is finite).
