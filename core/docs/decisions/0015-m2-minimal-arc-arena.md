# ADR-0015: M2's first ARC proof uses a fixed internal arena, not the real Allocator

**Status:** decided AND VERIFIED (hand-built leak test: alloc+retain+release+release, balanced,
1000+ cycles, heap returns to baseline every time, under real Linux/SysV, still freestanding) — does
NOT resolve escalations/0002

## Context

`ROADMAP.md` M2 exit criterion: "allocation-heavy programs run leak-free under `dc-test --leakcheck`;
`weak` references nil out correctly; `dc-objdump --arc` shows elision firing." `DCDART_SPEC.md` §3.1
fully specifies the `DCObject` header (`{u32 strong; u32 weak; ClassInfo* cls;}`) and retain/release
semantics — those are settled. What allocation mechanism supplies the memory is NOT settled:
`Allocator` threading (explicit param vs. implicit context) is one of spec §12's five decisions
explicitly marked "do not let an agent silently pick one" — escalated separately as
`docs/escalations/0002-allocator-threading.md`.

M2 needs *something* to allocate from to prove retain/release/leak-detection works at all. Waiting
for the Allocator escalation to resolve before writing any ARC code would block real progress on a
decision that's explicitly not this unit's to make.

## Decision

For this first slice only: a fixed-size, fixed-slot-size, global static arena (64 slots × 64 bytes),
free-list allocated (LIFO stack of free indices). Real, working, leak-detectable — but explicitly
**not** the real `Allocator` design:

- No `Allocator` interface, no threading model, no per-call-site allocator argument. One hardcoded
  global arena, referenced directly by the backend's `Alloc` codegen.
- Fixed slot size regardless of actual payload size (wasteful, fine for a proof).
- Out-of-memory (all 64 slots taken) calls `llvm.trap()` — matches spec §5's `panic()` model for
  `@bare` unrecoverable states, not a real allocator failure-handling API.
- No `ClassInfo`/destructor dispatch on release (`cls` header field is written as null and never
  read) — GAP-0003, still deferred; M2's first target is a single concrete class with no
  destructor-worthy state.

Object layout: `DCHeapPointer`'s address is the **payload** start (Swift/Obj-C convention — the
header sits at a fixed negative offset, `pointer - 16`). This lets payload field access reuse the
exact same address-plus-offset mechanism ADR-0011's `@packed` struct fields already use — no new
field-access machinery needed, only the header manipulation (`Alloc`/`Retain`/`Release`) is new.

New DC-IR instruction: `Alloc(dest: DCHeapPointer, payloadSizeBytes: int)`. `Retain`/`Release`
already existed (since the very first `core/dc-ir` unit, M0-era) with no backend implementation
until now.

## Rejected alternative

**Wait for escalations/0002 to resolve before writing any M2 code.** Rejected: the Allocator
*threading model* and the ARC *mechanism* (header layout, retain/release, freeing) are separable
concerns — spec §3.1 (the mechanism) is fully settled, only §12 item 2 (how allocator access is
spelled at call sites) is open. Proving the mechanism now, behind a clearly-labeled temporary arena,
produces real signal without deciding the open question; the temporary arena gets replaced (not
extended) once the escalation resolves.

## Consequences

- This arena is **not production API surface** — nothing in `core/runtime/dc-core-bare/prelude.dart`
  exposes it as `Allocator` or anything resembling the real interface. Whoever resolves
  escalations/0002 replaces this arena's call sites, not extends them.
- Fixed 64-slot capacity means this can't yet demonstrate genuinely allocation-heavy programs — fine
  for M2's first leak test (`docs/known-gaps.md` will track scaling this if pressured before the real
  Allocator lands).
- `ClassInfo`/destructors remain deferred (GAP-0003) — this ADR's `Alloc` writes a null `cls` and
  `Release` never reads it. A class with a real destructor-worthy field (e.g. an owned heap pointer
  inside another heap object) is explicitly out of scope for this first slice.
