# ADR-0049: `null` and nullable heap references

**Status:** decided — implemented and verified (`tests/conformance/list/`)

## Context

`Node? next` could not be expressed. `null` was rejected outright (`unsupported expression
NullLiteral`), so no optional reference existed, so no list terminator, no empty tree, no "not found".
It blocked every data structure independently of ADR-0048.

## Decision

Three pieces, and the third is the one that matters.

**1. `NullRef`, a dedicated DC-IR instruction.** Not a `ConstInt` with a pointer destination —
`ConstInt` emits `add <type> N, 0`, valid for an integer and meaningless for a pointer. `NullRef`
emits LLVM's `null` through a no-op GEP so the result is a real SSA name, matching how every other
value in this backend is produced.

**2. `EqualsNull` is its own Kernel node.** `x == null` does **not** arrive as the `EqualsCall`
ADR-0035 handles for sized integers — the CFE gives it a distinct `EqualsNull`, and `x != null`
arrives as `Not(EqualsNull)`. Widening the integer-equality path would have missed it entirely; this
is a separate case, found by trying it rather than by reading the AST definitions.

**3. `Retain` and `Release` are now NULL-SAFE, and this is the load-bearing part.**

Both previously computed the object header as `object - 16` and dereferenced it unconditionally. On a
null reference that reads address `-16` — not a clean fault at address 0, a wild read of whatever
happens to be mapped. Both now branch on null first and no-op, matching every refcounting runtime that
permits null references.

Doing it in codegen rather than at each use site is deliberate: a null reference flows through the
same assignments, field stores and scope-exit releases as any other, so a guard at every site would be
both noisy and easy to miss one of. One check in two emitters covers all of them.

## Verification

`tests/conformance/list/`: `Node? head = null` as a list terminator, `while (cur != null)` as the walk
condition, and the 500-cycle leak check — which also exercises `Release` on null every time a list is
torn down to its terminator.

Full suite 28/28 after changing every `Retain` and `Release` in the language, and ARC elision counts
on existing targets are byte-identical.

## Consequences

- Optional references work: list terminators, empty trees, "not found" results.
- Retain/release each cost one compare-and-branch more. Unmeasured against M3's budget; it is a
  predictable constant, and GAP-0034 (blanket-volatile pointers) is a much larger term in the same
  sum.
- `null` is typed as an untyped heap pointer at its use site and checked against the declared type at
  the assignment or field store. That is sufficient today because there is no subtyping; it would need
  revisiting alongside spec §4.3 dispatch.
- **No null SAFETY.** Dart's type system distinguishes `Node` from `Node?`, and DCDart currently
  ignores that distinction: dereferencing a null heap reference is not prevented, it faults at
  runtime. `CLAUDE.md` rule 3 calls sound null safety "our main advantage over C and C++", so this is
  a real gap rather than a deferral — filed as GAP-0038.
