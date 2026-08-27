# Escalation 0010: there is no array of ARC-managed references, and M3's own benchmark is paying for it

**Raised by:** the `hashmap` benchmark unit (ADR-0061, GAP-0061), 2026-08-26
**Why this is an escalation and not a gap entry:** `CLAUDE.md` — *"Anything where the honest fix is
'change the language' rather than 'change this code'."* Every fix below is a spec change (§3 memory
model, or §6 pointers) or a new type in the prelude. None of them is a lowering.
**Not blocking.** `hashmap` ships with a workaround whose cost is measured. This exists so the cost is
decided rather than inherited.

---

## 1. The finding

**A managed reference can only live in a field of a `HeapObject`.** There is no array type, no
array-typed field, and no way to turn a raw address back into a managed reference. Therefore

> **O(1) indexed access to ARC-managed objects is inexpressible in DCDart.**

Three routes exist and all three dead-end:

| route | what happens |
|---|---|
| a field of a `HeapObject` | the only legal home for a managed reference, and fields are named one at a time. A 1024-bucket table is 1024 declarations and a 1024-arm selector |
| `Heap.allocate` + `Pointer<T>` (ADR-0058) | raw bytes. A store emits no `Retain`, a free emits no `Release`. The reference is invisible to ARC: the object leaks, or is freed under a live alias |
| keep ownership elsewhere, index by address | **`Pointer<T>.fromAddress` has no inverse for managed types.** Every design that separates "who owns it" from "how I find it" fails at the read |

This was not visible before M3 because nothing had needed it. `tree-traversal`, every conformance
target and every example navigates by *named field*, which works and always did.

## 2. Why it matters now specifically

`docs/known-gaps.md` GAP-0051b and `bench/README.md` both listed `hashmap` as **writable** —
unblocked by ADR-0054's generic classes plus ADR-0058's heap, with the remaining work described as
"writing a `Map<K,V>` and a workload over it". That is the same error shape GAP-0050 and GAP-0051b
have each recorded once already: *a blocker clearing, and its clearing being read as the last blocker
clearing.* A hash map is writable. **A hash map with a bucket array is not**, and the bucket array is
the one operation a hash map is named for.

So `hashmap` indexes its 1024 buckets with a complete binary trie of depth 10, and `kernel.c` walks
the same trie so neither side chases more pointers than the other. The cost is measured, not asserted:

- **1.34× on the C baseline** — `bench/benchmarks/hashmap/index-tax/` runs the identical workload in C
  with a real bucket array. Same keys, same values, same order, same checksum.
- **Considerably more on the DCDart side, and this is the part that reaches the gate.** Reading a
  heap-typed field into a local is an alias retain (ADR-0017) with a matching release, and ADR-0025's
  intra-block pass 3 elides none of them. Each of the ten descent levels is one pair. An array-indexed
  map would execute roughly 1–2 pairs per operation; the trie executes ~10.

**`hashmap` scores ~2.4× against the trap-matched gate baseline, and a large part of that multiple is
this gap rather than ARC.** One of M3's five gate inputs is currently pricing a missing language
feature. That is the reason this is escalated rather than filed.

## 3. Options

| # | option | cost | consequence |
|---|---|---|---|
| 1 | **`Array<T>` in the prelude, backend-emitted, ARC-aware** — `Alloc`-adjacent instruction, element store emits retain/release-old, destructor releases every live element | largest. A new DC-IR instruction family and a destructor that loops. Touches spec §3.1 (the object header would need a length, or the length lives in the array object's own payload) | the honest end state. Every indexed structure becomes writable at once |
| 2 | **`unowned` array of raw slots + a separate owning chain** — the workaround made official rather than each program reinventing it | smallest to specify. `unowned` is spec §3.3 and is already unimplemented, so it is on someone's list either way | does not solve it. Ownership still has to live somewhere with O(1) access, and it does not |
| 3 | **A managed-pointer cast: `HeapRef<T>.fromAddress`** | small in the compiler, enormous in the language. It is `unsafeCast` for the ARC world | one of `CLAUDE.md`'s dangerous five, spelled at every use, and every use is a chance to get the retain wrong by hand. Fastest route to a use-after-free that no test can see — see GAP-0054, which is exactly that failure already happening *automatically* |
| 4 | **Do nothing; keep the trie, keep the caveat** | zero | M3's gate number keeps a multiplier in it that is not ARC. Every future indexed structure re-derives the same workaround |

**Recommendation: option 1**, and it does not have to be general to be useful. A fixed-length,
non-growable `Array<T>` allocated once — which is exactly what a bucket table is — needs no
reallocation, no capacity, and no growth policy. It needs an allocation whose size is a runtime
value (`AllocRaw` already does that, ADR-0058), an element store that emits the same retain/release
pair a field store already emits (ADR-0048 already does that), and a destructor that walks the
elements (ADR-0022's cascade already does that for fields). **The three mechanisms all exist; what is
missing is a type that lets a program name them at an index instead of at a field.**

**Do not decide option 3 quietly.** It is the one that looks cheapest from the compiler side and is
the only one that makes the memory model unsound by construction.

## 4. What happens if this is deferred

Nothing breaks. `hashmap` ships, ADR-0061 publishes the 1.34× index tax next to the number, and
`manifest.sh` prints the caveat where a reader of the result will see it. What is lost is that **one
of the five numbers deciding M3 is measuring something M3 did not ask about**, and that the next
person to need an indexed structure — a page table of managed pages, a ring buffer of objects, a
dynamic array — will rediscover this from scratch.

`CLAUDE.md` rule 4 freezes the memory model after M3. **Option 1 changes what a managed reference can
be stored in, so it is a rule-4 decision, and after M3 it is not a decision any more.** That is the
deadline, and it is the same one escalation 0002 and escalation 0007 are already sitting against.
