# dcc — the CLI driver

Status: **`dcc build --mode bare` works.** Verified end to end on this host (2026-08-13): produces a
real object file that passes `core/scripts/verify-freestanding.sh` for real, and the same
`dcc-lower`/`backend` code (retargeted for the host triple, since the freestanding ELF object can't
link natively on Windows) links and runs against `main.c`, returning 5 for `add(2,3)`. See
`core/docs/known-gaps.md` GAP-0001 (resolved) and GAP-0005 (the one honestly-open piece: the literal
"link the same freestanding object" step needs Linux/QEMU, not this host).

## What exists

```
core/dcc/
  pubspec.yaml         path deps: dcc_lower, backend (needs `dart pub get` once)
  bin/dcc.dart          entry point: main(), exit codes, wires args -> pipeline
  lib/cli_args.dart     parseArgs(): `build --mode <bare|hosted> <in> -o <out>`
  lib/pipeline.dart     runBuild(): real pipeline — dcc-lower, then backend, writes the object file
```

`dcc build --mode bare <input.dart> -o <output.o>`:
1. Parses and validates arguments (exit 64 on anything malformed).
2. Checks the input file exists (exit 65 if not).
3. Calls `dcc_lower.lowerToDCModule` — see `core/dcc-lower/README.md`.
4. Calls `backend.emitModule` + `backend.compileToObject` — see `core/backend/README.md`.
5. Writes the real object file bytes to the output path.

`--mode hosted` is parsed but always throws `UnimplementedError` — no backend target exists for it
yet (DCDART_SPEC.md §2's `@hosted` needs an allocator/ORC/threads runtime this project hasn't built).

Any failure at any stage (bad Kernel IR shape, backend error, `clang` failure) propagates to
`bin/dcc.dart`'s catch-all, prints the error, and exits 1 — **nothing is ever written to the output
path on failure**, matching `SKILL.md`'s rule against stubs that fake success.

## Running it

```bash
cd core/dcc && dart pub get     # once, resolves dcc_lower/backend path deps
dart bin/dcc.dart build --mode bare ../examples/m0-seam/add.dart -o add.o
```

Requires `dart`, `clang`, and `llvm-nm` on `PATH` (the last two only matter once you also want to run
`core/scripts/verify-freestanding.sh` on the result — `dcc build` itself only needs `dart`+`clang`).

Note `bin/dcc.dart` still imports `lib/` by relative path (`ADR-0002`'s original decision stands for
that part), but `lib/pipeline.dart` imports real packages one level in — see the addendum at the
bottom of `docs/decisions/0002-dcc-bootstrap-language.md` for why `pub get` is required now even
though it wasn't when this package was first written.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success — real object file written |
| 64 | usage error (bad/missing arguments) |
| 65 | input file does not exist |
| 1 | valid invocation, but compilation failed — see stderr for which stage and why |

## What "works" means precisely here

`dcc build --mode bare` on `core/examples/m0-seam/add.dart` has been run for real and:
- Exits 0, writes a real object file.
- That object file passes `core/scripts/verify-freestanding.sh` (`nm -u` prints nothing).
- The *arithmetic* is independently confirmed correct: the same `dcc-lower`/`backend` code, run with
  a native target triple instead of the freestanding one, was linked against `main.c` and executed —
  exit code 5.

What has **not** been demonstrated on this host: linking the *exact same freestanding object* that
passed the check above and running it (that specific object targets `x86_64-unknown-none-elf`, which
Windows cannot link natively — see `core/docs/known-gaps.md` GAP-0005). That needs a Linux host or
QEMU, consistent with how `DCDART_SPEC.md` says `@bare` code is meant to be tested
(`dc-test --qemu`) — not a defect in `dcc` itself.

## Scope — what M0's `dcc` does NOT do

See `core/dcc-lower/README.md` and `core/backend/README.md` for the precise cut. In short: one
`@bare` top-level function, `u64` parameters/return only, a body of exactly `return a + b;`. Anything
else in a `.dart` file passed to `dcc build` throws a specific, named error rather than silently
mishandling it.
