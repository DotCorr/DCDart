# ADR-0047: `break` and `continue`

**Status:** decided — implemented and verified (`tests/conformance/breakcontinue/`)

## Context

`_lowerWhile`'s doc comment listed "no `break`/`continue`" as a limitation, reason given: "no
`BreakStatement` lowering exists". True, and not the interesting part.

Asking GAP-0037's audit question instead — *what would have to be true for this refusal to be
correct?* — produced a better answer:

- **`continue` is free.** It is a branch to the loop header carrying the current loop-variable
  values, which is byte-identical to the back edge `_lowerWhile` already emits.
- **`break` was blocked by an unstated invariant.** `exitBlockId` was created with **no block
  parameters**, and the code after the loop restored values from the *header's* phi params. That is
  correct only because the exit was reachable through exactly one edge. Add a `break` and a body that
  assigns a loop variable then breaks would read the variable's **pre-body value** — a wrong answer,
  not a crash.

So the refusal was right, for a reason nobody had written down and which its stated reason did not
mention. That is the mirror image of ADR-0044, where the comment sounded right and wasn't; having both
cases is what makes GAP-0037 a usable rule rather than an anecdote.

## Decision

Kernel spells `break` and `continue` as the **same node** — `BreakStatement` — distinguished only by
which `LabeledStatement` is targeted:

```
break:                          continue:
  LabeledStatement                WhileStatement
    WhileStatement                  LabeledStatement   <- wraps the BODY
      ... BreakStatement -> label       ... BreakStatement -> label
```

A label wrapping the **loop** means jump past it; a label wrapping the **body** means jump to the
header. `_lowerWhile` registers both against a map from label to `(target block, loop variables)`, and
`BreakStatement` emits a `Branch` carrying the current values.

**The exit block now takes the loop variables as parameters**, and the header's false edge passes them
too. That is the whole fix for `break`, and it restores the invariant GAP-0037 exposed: *a block needs
parameters iff it has more than one predecessor.*

## The bug this shipped through, which is the more useful half

Implementing it produced a **silent infinite loop**, and the cause was not in the new code.

`_collectLoopCarriedCandidates` — the walker that finds loop-carried variables before the header is
built — recognized `Block`, `ExpressionStatement`, `IfStatement` and `WhileStatement`, and **fell off
the end silently** for anything else, on the stated reasoning that nothing unrecognized "can't itself
carry a `VariableSet` target".

`continue` introduces a `LabeledStatement` around the entire loop body. So the walker collected
**nothing**, the header got no phi parameters, the condition compared the variable's entry value
forever, and the emitted loop was `b 0x4` — a branch to itself. No diagnostic. No wrong value. A hang.

The walker is now **exhaustive**: recognized containers recurse, statements that genuinely cannot
contain an assignment are listed explicitly, and **anything else throws**. A missed assignment cannot
be reported downstream, because nothing downstream is malformed — the IR is well-formed and simply
means something different. That is precisely when silence is unaffordable.

This is the same class as GAP-0037's other three, and the sharpest instance: a shape check that
silently skips unknown shapes, where the consequence of a miss is wrong code rather than an error.

## Verification

- **`firstMatch`** — assign-then-break. The exit must see the assigned value (4, 0, 9) and the
  pre-loop value (999) when no match occurs. This is the case the missing exit parameters broke.
- **`sumEvens`** — `continue`, which exercises the `LabeledStatement` walk that produced the hang.
- **`breakInner`** — `break` leaves only the inner loop; the outer keeps running.
- **`bothInOne`** — both in one loop body.

All freestanding-clean, run natively, hand-checked. Full suite 28/28 after parameterizing the exit
block, which changes code generation for **every** existing loop.

## Consequences

- One more M3 prerequisite closed. `oscortex_core`'s bounded waits stop being flag-and-condition
  dances.
- Labelled `break` to a non-loop statement is rejected explicitly rather than mis-lowered.
- Still unsupported inside a loop body, and still deliberately: heap- or weak-typed locals, because
  the ARC policy for a back edge is undecided — the same family as escalation 0006, and genuinely
  unresolved rather than merely untested.
