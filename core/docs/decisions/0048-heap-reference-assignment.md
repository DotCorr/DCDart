# ADR-0048: ARC semantics for assigning a heap reference (fields and locals)

**Status:** decided — **under explicit delegation from the project owner, 2026-08-22**, who was shown
escalation 0006 and instructed that the decision be taken and reviewed afterwards rather than blocked
on. Recorded that way because `CLAUDE.md` rule 4 makes this a §3 memory-model decision, and the
provenance of a frozen-area choice should be visible on its face. **Reversible** — the policy is
localized to two call sites and the alternative is documented below.

## Context

Escalation 0006 asked what happens when a heap reference is overwritten. Nothing could be built
without an answer: `a.next = b` and `head = Node(i, head)` were both rejected, which is why no DCDart
program could construct a linked list, a tree, or any mutable structure — and why four of M3's five
benchmarks were unwritable (GAP-0035).

## Decision

Assignment of a strong heap reference — to a **field** or to a **local** — is:

```
1. retain the new value      (unless it is already a fresh +1)
2. load the old value        (fields only; a local already has it)
3. store the new value
4. release the old value
```

Two of those four were settled by correctness rather than preference:

- **The old value must be released.** It held a strong reference; overwriting without releasing leaks,
  and `examples/m2-heap-field/` already depends on each field holding exactly one.
- **Retain must precede release.** `a.next = a.next` would otherwise free the object between the two
  steps and store a dangling pointer.

The genuinely open question was step 1's exception, and it is where the delegation matters.

### The chosen option, and what it costs

**Retain unless the right-hand side is a fresh-ownership source**, reusing `_isFreshHeapOwnership` —
the predicate `dcc-lower` already applies at the structurally identical site, a fresh allocation
passed to an `@owned` parameter (ADR-0021).

The alternative was **always retain**, letting elision pass 3 (ADR-0025) delete the redundant pair.
That is slower but *cannot double-free*, whereas this option makes correctness depend on a static
analysis being right: too conservative and it leaks, too aggressive and it frees a live object.

I chose the analysis because it is not new — it is the project's existing answer to "does this
expression hand me a reference I own", already trusted at an equivalent site — and because "always
retain" produces a pair that only *sometimes* gets elided, making the cost unpredictable rather than
merely higher.

**The honest risk:** if `_isFreshHeapOwnership` is ever extended incorrectly, this silently
double-frees. That is worse than a leak. It is mitigated by the leak check below being sensitive in
*both* directions, not by the analysis being obviously right.

## Verification

`tests/conformance/list/` builds a real linked list, and the load-bearing assertion is not the values:

> The M2 arena has **64 slots**. The harness builds a 10-node list **500 times** — 5000 allocations.
> That only completes if every node is freed.

One missing release exhausts the arena within a few iterations. One release too many frees a live node
and corrupts the walk. So the check fails whichever direction the policy is wrong in, which is exactly
the property the chosen option needs, given its failure mode.

`head = Node(i, head)` is the case that exercises the whole policy at once: the allocation is fresh
(no retain), the field store retains the old head, and the local assignment releases it — leaving each
node with exactly one owner.

## Consequences

- Mutable data structures are expressible. M3's tree/graph traversal benchmark becomes writable.
- Heap-typed locals may now be loop-carried, which is what makes building a structure in a loop work.
- **Weak-typed field stores are still rejected**, deliberately and separately. The strong policy does
  not transfer: a weak store adjusts the *weak* count and interacts with ADR-0023's zombie-slot
  semantics. That is a different decision and nobody has made it.
- ARC elision counts on every pre-existing target are unchanged, so this did not perturb what M3 will
  measure.
- **If the owner reverses this on review**, the change is two call sites in `_lowerHeapFieldStore` and
  the `VariableSet` heap branch: drop the `_isFreshHeapOwnership` guard and always retain. The
  conformance target would still pass, more slowly.
