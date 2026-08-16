# ADR-0001: core/ holds the project, repo root holds only the guide docs

**Status:** decided

## Context

Repo root had six markdown files (`CLAUDE.md`, `AGENTS.md`, `DCDART_SPEC.md`, `ROADMAP.md`,
`README.md`, `SKILL.md`) and nothing else runnable. Needed a place for actual compiler/runtime/test
code to live without mixing it into the always-loaded guidance layer.

## Options

1. Put source directly at repo root, alongside the guide docs.
2. Put all non-guide-doc project content under `core/`.

## Decision

Option 2. `core/` mirrors the compiler architecture from `DCDART_SPEC.md` §1
(`frontend/ → dcc-lower/ → dc-ir/ → backend/`), plus `runtime/`, `tests/`, `examples/`, and the
project's three state files (`docs/compat-matrix.md`, `docs/known-gaps.md`, `docs/decisions/`) and
`docs/escalations/`. `scripts/` and `tools/` also moved under `core/` so the whole buildable tree is
one subtree.

## Consequences

- `CLAUDE.md`'s literal paths (`scripts/verify-freestanding.sh`, `tools/bare-symbol-allowlist.txt`)
  are now `core/scripts/...` and `core/tools/...`. Agents running commands from repo root need the
  `core/` prefix; this doc is the record of why the prefix exists.
- Repo root stays exactly the six guide files plus `core/` and `mnt/` (pre-existing, unrelated user
  data mount) — nothing to search through to find the rules.
