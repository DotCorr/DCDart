# ADR-0002: dcc's CLI skeleton is written in plain hosted Dart

**Status:** decided

## Context

`core/dcc/` was empty. The task at hand: build a real argument-parsing
skeleton for `dcc build --mode bare|hosted <input.dart> -o <output.o>` that
wires into the (not-yet-existing) compile pipeline and fails loudly on the
unimplemented parts, per `SKILL.md`'s rule against stubs that fake success.

Choosing an implementation language for this is not free. There is a
genuine chicken-and-egg problem:

- Per `DCDART_SPEC.md` §1 `[LOAD-BEARING]`, `dcc` must eventually consume
  `pkg/front_end` (the DCDart CFE fork) to parse `.dart` source into Kernel
  IR. `pkg/front_end` is a Dart package. That means `dcc`'s real
  implementation is a Dart program, not a DCDart program — DCDart doesn't
  exist as a working compiler yet (that's the entire M0–M9 arc), so
  "write dcc in DCDart" is circular today.
- This dev environment has no `dart`, `clang`, or `llvm-nm` on `PATH` (see
  `core/docs/known-gaps.md` GAP-0001) — only `git`, `python`, and a POSIX
  shell. Nothing that requires a Dart runtime can be executed or verified
  here right now.
- The task at hand (arg parsing + failing loudly) does not actually need
  `pkg/front_end`, a Dart runtime feature, or any dependency beyond
  `dart:core`/`dart:io` — so the "no Dart SDK here" fact does not force a
  different language, it only means the result is unverified until one
  shows up.

## Options

1. **Python.** The only scripting language actually runnable in this
   environment right now. Would let the skeleton be executed and smoke-
   tested today.
2. **POSIX shell.** Also runnable today; even more minimal.
3. **Plain hosted Dart, zero pub dependencies.** Matches the eventual real
   implementation language. Cannot be executed in this environment today.
4. **DCDart itself (self-hosted).** Rejected outright — no working DCDart
   compiler exists yet; this is what M0–M9 are for. Circular.

## Decision

Option 3. `core/dcc/{bin,lib}` is plain hosted Dart:
`bin/dcc.dart` (entry point) imports `lib/cli_args.dart` and
`lib/pipeline.dart` by **relative path**, not `package:` URI, and the
package declares zero dependencies in `pubspec.yaml`. This means it needs
no `dart pub get` / package-resolution step — it runs as `dart
bin/dcc.dart ...` the instant a bare `dart` executable lands on `PATH`,
with no vendoring and no network access required.

Rejected 1 and 2 (Python/shell) even though they are the only things that
actually run here today, because:

- `dcc`'s real implementation is Dart, per the spec seam above. A
  Python/shell version of the CLI is not a stepping-stone toward that, it's
  a second, throwaway implementation of the same argument parser in the
  wrong language. Per `SKILL.md`'s explicit failure mode — *"Stubbing a
  dependency. Always becomes permanent."* — a Python `dcc` that happens to
  run today is exactly the kind of stub that quietly becomes "the CLI"
  because it's the one thing agents can invoke, while the Dart rewrite
  never quite gets prioritized. Writing the throwaway version is a trap,
  not a shortcut.
- Being executable *today* was not actually a requirement here: the task
  is a skeleton that parses arguments and fails loudly on the
  unimplemented compile step, not a smoke-tested binary. Executability is
  gated on GAP-0001 regardless of language choice, since the real pipeline
  (frontend/dcc-lower/dc-ir/backend) still won't exist even with a working
  Python CLI wrapper.

## Consequences

- **Unverified in this environment.** No `dart` binary exists here, so
  none of `core/dcc/bin/dcc.dart`'s code paths have actually been run.
  The implementation was reviewed by hand for syntax and control-flow
  correctness (definite-assignment analysis around the `Never`-returning
  `exit()`/`runBuild()` calls, exhaustive enum matching, etc.) but that is
  not a substitute for running it. Logged as GAP-0002 in
  `core/docs/known-gaps.md`, distinct from GAP-0001 (which is about the
  CFE not being vendored) because this is a concrete, reviewable artifact
  now sitting unexecuted, not just an absence.
- The next agent who has a Dart SDK available should run `core/dcc/bin/dcc.dart`
  against a handful of valid and invalid invocations before trusting it,
  and close GAP-0002 once confirmed.
- `lib/pipeline.dart`'s `runBuild()` is the seam the frontend/dcc-lower/
  dc-ir/backend work wires into later. It currently always throws
  `PipelineNotImplementedError` and touches no filesystem output — do not
  change that to a fake success to make the M0 checklist look further
  along than it is.

## Addendum (2026-08-13): "zero pub dependencies" no longer holds

Once `runBuild()` stopped being a stub and actually called into
`package:dcc_lower` and `package:backend` (see
`docs/decisions/0008-m0-frontend-strategy.md`), `core/dcc/pubspec.yaml`
gained two path dependencies. This section's "no `dart pub get` needed"
claim was true only while the pipeline was unimplemented — it was never a
property of the *language choice* in this ADR (plain hosted Dart), only of
how little the skeleton depended on. `bin/dcc.dart` still imports `lib/` by
relative path (that part of the decision stands); it's `lib/pipeline.dart`
importing real packages one level in that now requires `pub get`. Not worth
re-litigating the decision over — the alternative would be inlining
`dcc-lower`/`backend`'s entire implementation into `dcc`'s own package to
avoid a `pub get` step, which is a worse tradeoff than just running
`pub get` once.
