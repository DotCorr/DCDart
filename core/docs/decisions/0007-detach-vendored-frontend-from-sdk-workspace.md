# ADR-0007: Detach vendored front_end/kernel/_fe_analyzer_shared from dart-lang/sdk's pub workspace, and pin to a release tag instead of `main`

**Status:** decided

## Context

ADR-0005 vendored `pkg/front_end`, `pkg/kernel`, `pkg/_fe_analyzer_shared` via sparse shallow clone,
pinned at a `main`-branch commit. Two problems surfaced the first time `dart pub get` was actually
run against the result:

1. `dart-lang/sdk` resolves all `pkg/*` (and more) as a single Dart pub workspace — the repo-root
   `pubspec.yaml` lists ~60 members (`pkg/analysis_server`, `pkg/dart2wasm`, `pkg/dds`, ...), and
   each vendored package's own `pubspec.yaml` opts in via `resolution: workspace`. `pub get` refused
   to resolve `pkg/front_end` alone: "No workspace packages matching `pkg/analysis_server`" — every
   listed member must be physically present, whether or not `front_end` actually depends on it.
2. A `main`-branch commit's `pkg/front_end` requires an SDK version (`^3.13.0-0`, an unreleased
   prerelease) newer than any stable Dart SDK actually installable via winget (`3.12.2`). Tracking
   `main` means permanently requiring a dev-channel SDK that has to be re-matched on every re-vendor.

## Decision

Two changes, both now:

1. **Re-pinned the vendor to the `3.12.2` git tag** (commit `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`)
   instead of a `main` commit. A tagged release's `pkg/front_end` declares `sdk: '^3.12.0-0'`, which
   the winget-installed stable `3.12.2` satisfies exactly. Re-vendoring in the future should track
   another release tag, not `main`, unless there's a specific reason to need unreleased SDK features.
2. **Edited the three vendored `pubspec.yaml` files** to drop `resolution: workspace` (and
   `front_end`'s own nested `workspace: [testcases]`) and resolve standalone instead:
   - `_fe_analyzer_shared`: `meta`, `source_span` as ordinary hosted (pub.dev) deps — both are
     normal published packages, no vendoring needed.
   - `kernel`: `_fe_analyzer_shared` as a `path: ../_fe_analyzer_shared` dep.
   - `front_end`: `_fe_analyzer_shared` and `kernel` as path deps to their vendored siblings;
     `package_config`, `yaml` as hosted deps.
   - All three drop their upstream `dev_dependencies` (`analyzer`, `compiler`, `dart2wasm`, `test`,
     etc.) — this fork doesn't run `front_end`'s own upstream test suite against those dev-only
     packages; DCDart's conformance tests live in `core/tests/conformance/`, not here.

Verified: `dart pub get` inside `pkg/front_end` now resolves cleanly (10 packages: the two vendored
siblings plus `collection`, `meta`, `package_config`, `path`, `source_span`, `string_scanner`,
`term_glyph`, `yaml` — all ordinary pub.dev packages).

## Consequences

- This vendored copy no longer builds via `dart-lang/sdk`'s own build system (`gn`/`ninja`,
  `tools/build.py`) — it's a plain three-package pub-resolvable subtree, which is what this fork
  actually needs to consume from DCDart's own `dcc`, not a way to build the whole Dart SDK.
- Re-vendoring (e.g. to pick up a newer stable release) means repeating both the sparse-clone step
  (ADR-0005) and this workspace-detach edit — the detach is not a one-time patch that survives a
  re-clone. Worth a small script if re-vendoring becomes routine; not written now since it's happened
  exactly once.

  **Addendum (2026-08-20):** it happened a second time — a fresh clone on a new machine, where the
  ignored `vendor/` tree meant *nothing* in `core/` could `pub get` at all (known-gaps.md GAP-0021).
  The script anticipated above now exists: `core/scripts/vendor-frontend.sh`. It performs both steps,
  hard-fails if the checkout is not this ADR's pinned commit, and proves the result with a real
  `pub get` across all six `core/` packages rather than assuming. Verified from an empty
  `core/frontend/`.
- The three edited `pubspec.yaml` files are the first actual modifications to vendored upstream
  source in this fork (everything before this was unmodified vendoring). Each carries an inline
  "DCDart fork note" comment pointing back to this ADR.
