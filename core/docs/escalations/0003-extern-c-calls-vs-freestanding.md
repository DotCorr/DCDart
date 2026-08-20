# Escalation 0003: Calling external C symbols collides with rule 1 (zero undefined symbols in `@bare`)

**Status: RATIFIED BY THE PROJECT OWNER, 2026-08-20 — option 2.** The owner was shown the conflict
(an external symbol is by definition an undefined symbol, so extern calls collide with rule 1), the
three options, and their costs, and chose the explicit `@extern` annotation with a mechanically
checked per-object manifest. This supersedes the previous "NOT RATIFIED BY A HUMAN" status; option 2
is now the sanctioned design, not an implementation proceeding ahead of its escalation.

The decision in the owner's terms: `@extern`-declared symbols are recorded in a per-object manifest
that `scripts/verify-freestanding.sh` consults. The check still **hard-fails any undefined symbol
that was not declared**, so it keeps catching `dc_alloc`, `dc_throw`, `dc_orc_*` and `Dart_*` exactly
as before. Rule 1 is not relaxed to "anything goes"; it becomes "zero undefined symbols except ones
the source explicitly declared, checked mechanically."

Option 2 is BUILT and shipping (ADR-0038, `tests/conformance/ffi-extern/`). It remains reversible —
deleting the manifest logic from `dcc/lib/pipeline.dart` and the manifest lookup from
`scripts/verify-freestanding.sh` restores the previous behaviour exactly — but reversing it is now a
decision to revisit, not a correction of an unratified change.

Nothing in ADR-0033/0034/0035/0036 depends on the answer; the outbound FFI direction (C calls DCDart)
was implemented and shipped without touching this question.

## The problem

DCDart can now be called *from* C: `--emit-header` (ADR-0034) generates the declarations, and the
object files were always plain C-ABI. Native targets (ADR-0033) mean that object links into a real
macOS, Windows or Linux program.

The other direction — DCDart calling `malloc`, `write`, `printf`, or any third-party C library — is
what "build entire systems" ultimately requires, and it is **not** merely unimplemented. It is in
direct tension with the project's first and least negotiable rule:

> **1. No runtime dependency in `@bare`.** Every `@bare` object file must link freestanding… fails on
> any undefined symbol outside the allowlist… This check is the project's spine.

A call to an external C symbol *is* an undefined symbol in the object file. That is what calling one
means. So `verify-freestanding.sh` will fail any `@bare` object that calls out — correctly, by
design. This is not a bug in the checker.

`CLAUDE.md` also lists "Any new `@bare` runtime symbol" as an explicit escalation, and
`tools/bare-symbol-allowlist.txt` says in the checker's own error text: *"Do NOT add to the allowlist
to make this pass. The allowlist is owned by E4."* Both point here.

This is currently filed as GAP-0019 ("no general inline asm / `@naked` / extern-to-external-symbol
FFI"), which describes the missing feature but not the rule conflict underneath it.

## Options

1. **Keep `@bare` closed. Extern C calls only in `@hosted`.**
   Preserves the spine exactly as written: a `@bare` object stays provably self-contained forever.
   Cost: the entire C ecosystem is unreachable from the only mode that currently works, since
   `@hosted` needs a runtime nobody has built (spec §2). "Build entire systems" would wait on M4+.

2. **An explicit `@extern` annotation that opts a symbol out of the freestanding check.**
   `@extern u64 write(i32 fd, Pointer<u8> buf, usize n);` emits a `declare` and a `call`, and the
   symbol is recorded in a per-object manifest the checker consults. The spine check becomes "zero
   undefined symbols *except ones the source explicitly declared*", which is still a real, mechanical
   guarantee — it catches accidental runtime leaks (`dc_alloc`, `dc_throw`, `Dart_*`), which is what
   the check is actually protecting against, while permitting deliberate ones that are visible in the
   source.
   Cost: weakens a bright-line rule into a rule-with-an-exception. The failure mode is drift — an
   `@extern` added "just for now" that becomes load-bearing.

3. **A third mode (`@freestanding` vs `@bare` vs `@hosted`).**
   Splits today's `@bare` into "provably self-contained" and "native but no DCDart runtime". Most
   honest taxonomy; also a spec §2 change, which is itself an escalation, and it makes the mode axis
   three-valued right when ADR-0033 has just finished separating mode from target.

## Reached independently, twice

Worth recording because it is the strongest evidence in this document: a second agent session working
on the same repo derived the same conclusion from rule 1 in parallel, without either seeing the
other's reasoning — an external symbol is an undefined symbol by definition, so the honest fix is an
explicit source-level opt-out with a mechanically-checked manifest, rather than weakening
`verify-freestanding.sh`. That session's implementation (`DCModule.externFunctions`, a per-object
manifest the checker consults) is the mechanism recommended below, built. That session's
implementation has now landed, and this section's "recommendation" framing has been rewritten below
as a description of what exists.

## Decision, as built (ADR-0038)

**Option 2**, with the allowlist mechanism kept intact and E4 still owning it. Ratified by the project
owner on 2026-08-20; see the status block at the top of this file for the provenance of that
ratification (owner's decision, relayed, not witnessed firsthand by whoever wrote this section).

The reasoning: the spine check's real purpose, judged by its own diagnostics, is catching *implicit*
runtime dependencies — the error text calls out `dc_alloc` ("a closure escaped, a String was built"),
`dc_throw`, `dc_orc_*`, and `Dart_*` ("OLD VM RUNTIME… escalate to E2 immediately"). Every one of
those is a symbol that appears because the compiler put it there without the programmer asking. An
`@extern` declaration written by hand in the source is the opposite: it is the programmer stating the
dependency explicitly, in a form a reviewer can see and grep for.

A check that distinguishes "the compiler smuggled in a runtime" from "the author declared a
dependency" is still a spine. A check that cannot express the difference forces option 1, which
indefinitely blocks the stated goal.

### What actually exists now

1. **Source.** `@extern` (a new prelude marker) plus Dart's own `external` keyword. Both are
   required; either one alone is a compile error naming the other. `external` means front_end already
   guarantees no body and Kernel IR already records `Procedure.isExternal` — no new Kernel node
   (rule 2). The Dart identifier is the C symbol name verbatim; there is no `@linkName` because
   nothing has needed a C name that is not a legal Dart identifier.
2. **DC-IR.** `DCModule.externFunctions: List<DCExternFunction>` — a module-level declaration list.
   No new instruction: an extern call and a `@bare` sibling call are the same `Call`, because at the
   call site they are genuinely the same thing.
3. **Backend.** One `declare` per extern, so the object carries a real undefined symbol with real
   relocations.
4. **Manifest.** `dcc` writes `<output>.o.externs` listing exactly those names, and DELETES a stale
   one when a build declares no externs — a leftover manifest would otherwise permit symbols the
   current object never declared.
5. **Checker.** `scripts/verify-freestanding.sh` permits exactly the manifest's names in addition to
   the allowlist, and prints them on every pass. The allowlist file is untouched.

### Both conditions from the original recommendation are met

- *"report declared externs even when passing"* — the pass line now reads
  `FREESTANDING: pass  foo.o  (7 declared extern(s): dcx_add …)`.
- *"`@extern` should be rejected in `@interrupt` functions"* — vacuously satisfied and **not built**:
  `@interrupt` does not exist yet (`known-gaps.md` GAP-0019 lists it as unimplemented). Whoever builds
  `@interrupt` owns this; it is recorded in GAP-0019 so it cannot be forgotten.

### What the check still refuses, proven mechanically

`tests/conformance/ffi-extern/run.sh` step 3 takes the passing object, removes its manifest, and
requires the same check to FAIL. That is the difference between "rule 1 with a declared exception"
and "rule 1 abandoned", and it is asserted on every run rather than argued in prose.

### Residual risk, stated rather than hidden

The manifest is generated by `dcc` from the source, so it always agrees with the source it was built
from — but a hand-written manifest could launder a symbol, exactly as a hand-edited allowlist already
could. The trust model is unchanged, not weakened; it is simply now two files instead of one. An
alternative that removes the risk — embedding the declaration set in a section of the object file
itself — was considered and rejected as premature (ADR-0038's "Rejected alternatives"), and it remains
available if ratification asks for it.

## What ratification would settle

- Whether option 2 is the answer at all, or whether option 1 (`@bare` stays closed, externs wait for
  `@hosted`) or option 3 (a third mode) is preferred. If it is option 1 or 3, ADR-0038's mechanism is
  removable without disturbing anything else.
- Whether an `@extern` declaration should require a justifying comment, the way `CLAUDE.md`'s
  "dangerous five" already do.
- Whether the manifest should live inside the object file rather than beside it.

## Why this is not decided here

It changes the meaning of rule 1, which `CLAUDE.md` calls "the project's spine" and which every
milestone so far has been verified against. That is a project-level decision about what DCDart
guarantees, not an implementation choice — and it is exactly the kind of call the escalation rule
exists to keep out of an implementation unit's hands.

It also interacts with spec §12's open allocator decision (escalation 0002): if `@bare` can call
`malloc`, the "explicit `Allocator` parameter everywhere" option looks materially different.
