# M0 — the seam

The one thing that has to be proven before anything else in this project (see `ROADMAP.md` M0, `README.md` "First action").

```
add.dart  ──dcc build --mode bare──►  add.o  ──llvm-nm -u──►  (nothing)   ✓ verified
                                        │
main.c ─────────────────────────────cc─┴──► binary that returns 5        ✓ verified (retargeted build, see below)
```

## Status: working

`dcc build --mode bare add.dart -o add.o` produces a real object file that passes
`core/scripts/verify-freestanding.sh` for real (`FREESTANDING: pass`). See
`core/docs/known-gaps.md` GAP-0001 for the full trail (toolchain install, vendored frontend,
`dcc-lower`/`backend` implementation) and `core/docs/decisions/0008-m0-frontend-strategy.md` for why
`add.dart` imports `core/runtime/dc-core-bare/prelude.dart` — `u64`/`bare` aren't builtin DCDart
syntax yet, they're real Dart extension-type/annotation declarations real front_end already
understands, which is enough for M0 without a compiler fork.

```bash
cd core/dcc && dart pub get   # once
dart bin/dcc.dart build --mode bare ../examples/m0-seam/add.dart -o add.o
DCDART_ALLOWLIST=../tools/bare-symbol-allowlist.txt NM=llvm-nm bash ../scripts/verify-freestanding.sh add.o
```

## One honestly-open piece: GAP-0005

Linking *this exact* `add.o` (target `x86_64-unknown-none-elf`) against `main.c` and running it needs
a Linux host or QEMU — Windows can't link an ELF object natively, and that's consistent with
`DCDART_SPEC.md`'s own testing model for `@bare` code (`dc-test --qemu`), not a defect. What *has*
been verified on this host: the identical `dcc-lower`/`backend` code, retargeted to the native host
triple, linked (via MinGW-w64 `gcc`) and run — exit code 5. Strong evidence the arithmetic/lowering
is correct; not literally the same artifact. See `core/docs/known-gaps.md` GAP-0005 for the precise
distinction and `core/tests/conformance/m0/run.sh` for the harness that will report an unqualified
`M0: PASS` once run on a compatible host.
