# ADR-0005: Vendor dart-lang/sdk's pkg/front_end + pkg/kernel via sparse shallow clone

**Status:** decided — **pin commit superseded by ADR-0007** (re-pinned from a `main` commit to the
`3.12.2` release tag; the sparse/shallow/partial-filter clone *strategy* decided here still stands)

## Context

`DCDART_SPEC.md` §1 requires the DCDart CFE to be a **fork** of `dart-lang/sdk`'s `pkg/front_end`
(and its `pkg/kernel`, `pkg/_fe_analyzer_shared` dependencies), not a reimplementation — that's the
entire point of forking at the Kernel IR boundary rather than the VM (spec §1, "Why fork at the
Kernel boundary, not the VM"). `core/frontend/` was empty (GAP-0001). The full `dart-lang/sdk`
monorepo is far larger than the three packages this project needs — it also contains the VM
runtime, `dart2js`, `dart2wasm`, the analyzer, build tooling, and third-party DEPS-pinned
dependencies, none of which this project forks.

## Options

1. Full clone of `dart-lang/sdk` (all history, all directories).
2. Shallow (`--depth=1`), sparse (`--sparse` + `git sparse-checkout set`), partial-filter
   (`--filter=blob:none`) clone, restricted to `pkg/front_end`, `pkg/kernel`,
   `pkg/_fe_analyzer_shared`.
3. Download a source tarball/zip of just those directories instead of `git clone` (no `.git`
   history at all).

## Decision

Option 2. `git clone --filter=blob:none --sparse --depth=1` into `core/frontend/vendor/dart-sdk/`,
then `git sparse-checkout set pkg/front_end pkg/kernel pkg/_fe_analyzer_shared`.

Pinned commit: **`99980117ece50fa18acdb2de1e2e4ddaad0c6893`** (dart-lang/sdk default branch, as of
this vendoring — this is now the fork's baseline, not a moving target).

Resulting size: ~172M working tree (the three packages, which include their own test fixtures) +
~71M `.git` metadata.

Rejected option 3 (tarball, no `.git`) because keeping the actual git history/remote makes it
possible to `git fetch`/diff against upstream later to pull forward fixes — which a full fork will
eventually want — without re-vendoring from scratch. A shallow+sparse+partial clone gets that same
future capability at a fraction of the size of option 1.

## Consequences

- `core/frontend/vendor/dart-sdk/` now contains real upstream source, not a stub. Nothing in it has
  been modified yet — the actual "fork" (DCDart-specific changes to the CFE) hasn't started; this
  ADR only covers vendoring the baseline.
- Because this is `--depth=1`, there's no history prior to the pinned commit locally. If the fork
  ever needs to bisect an upstream regression, a deeper/unshallow fetch will be needed then — not
  worth paying for up front.
- `pkg/front_end` and `pkg/kernel` bring their own `pubspec.yaml`/dependencies (on `package:meta`,
  `package:_fe_analyzer_shared`, etc.) which are not yet resolved (`pub get` hasn't been run — no
  Dart SDK was confirmed on PATH at the moment this ADR was written). That's the next gate, not
  solved here.
- This directory is large (~243M). It should not be treated as throwaway scratch — it's the actual
  frontend baseline the fork builds on.
