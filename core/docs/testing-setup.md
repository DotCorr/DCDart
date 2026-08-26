# Testing DCDart in VS Code

A working setup on macOS, Linux or Windows, in the order that actually works. Every command here was
run on a Mac (Darwin/arm64) from a clean environment before being written down; where something does
not work yet, it says so rather than being left out.

---

## 0. What you are setting up

DCDart compiles a `.dart` file to a **native object file** with a C ABI. There is no VM and no
runtime, so the way you run a DCDart program is: compile it to a `.o`, then link it into an ordinary
C program. That is not a workaround — it is the language's actual shape, and it is why `main` lives
in a `.c` file in every example.

```
your.dart ──dcc build──▶ your.o ──clang──▶ ./your
                │                             ▲
                └──--emit-header──▶ your.h ───┘  (C declarations for everything you exported)
```

---

## 1. Prerequisites

| Tool | Why | Check |
|---|---|---|
| **Dart SDK 3.12.2** | runs the compiler; the vendored frontend is pinned to this tag (ADR-0005) | `dart --version` |
| **clang** | assembles the emitted LLVM IR and links the final binary | `clang --version` |
| **llvm-nm** | `verify-freestanding.sh` — `CLAUDE.md` rule 1, the project's spine | `llvm-nm --version` |
| **llvm-objdump** | the harnesses that assert on emitted *instructions* rather than results | `llvm-objdump --version` |

A different Dart SDK will usually still run `dcc`, but the vendored `front_end` is pinned, and a
mismatch surfaces as confusing Kernel IR errors rather than a version complaint. Match the version.

**macOS.** `clang` comes with the Xcode command-line tools (`xcode-select --install`). The LLVM
binutils come from Homebrew (`brew install llvm`) or from inside Xcode.

> **The macOS trap that costs an hour.** `llvm-nm` lives in
> `Xcode.app/.../XcodeDefault.xctoolchain/usr/bin`. The obvious move is to put that directory on
> `PATH`. **Do not.** It also contains a `clang` that shadows `/usr/bin/clang`, and that one has no
> macOS SDK sysroot, so every link fails with `ld: library 'System' not found` — which reads as a
> broken SDK rather than a shadowed compiler. `scripts/dcdart-env.sh` avoids this by symlinking only
> the tools it needs and leaving the rest of the Xcode toolchain off `PATH`.

**Linux.** `apt install clang llvm` covers all of it.

**Windows.** LLVM's official installer, or the MSVC build tools plus LLVM. See the caveat in §7.

---

## 2. First-time repo setup

**A fresh clone cannot build anything until you run this.** `core/frontend/vendor/` is `.gitignore`d
(~245 MB with its own nested git history), so nothing in `core/` resolves until it is restored:

```bash
bash core/scripts/vendor-frontend.sh
```

It reproduces the vendored SDK from the pinned sparse clone, re-applies the workspace-detach pubspec
edits (which live only in the ignored tree and cannot survive a re-clone), and proves the result with
a real `pub get` across all six packages. It takes a few minutes and prints what it is doing.

Then put the toolchain on `PATH` for your shell:

```bash
source core/scripts/dcdart-env.sh
```

It prints where it found each tool, or says `MISSING` — it will not silently half-work. If your Dart
SDK is not already on `PATH`, point it at one:

```bash
DCDART_DART_SDK=/path/to/dart-sdk source core/scripts/dcdart-env.sh
```

---

## 3. Prove the setup before you write anything

```bash
bash core/tests/run-conformance.sh
```

Expect a summary like:

```
===== conformance: 34 passed, 0 failed, 1 skipped [host Darwin/arm64, link mode: hosted] =====
  skipped (host-gated, NOT passes): ffi-extern
```

**Read that line carefully — it is worded the way it is on purpose.**

- **`skipped` is a real third outcome**, listed separately and never folded into the pass count. For
  weeks this project quoted "32 passed, 0 failed" that had been measured in a Linux container; on the
  actual dev host the number was 18/35, because harnesses that could not run reported themselves as
  *failures*. GAP-0048 has the full account. A skip means coverage is **absent**, not fine.
- **The host and link mode are in the summary line** so nobody can mistake one machine's number for
  the project's.
- `ffi-extern` skips on macOS because Apple's `ld` cannot link ELF. `brew install
  x86_64-elf-binutils` makes it run for real; when the linker *is* available the assertions are hard.

---

## 4. Your first program

Two files. `hello.dart`:

```dart
import '/absolute/path/to/DCDart/core/runtime/dc-core-bare/prelude.dart';

@bare u64 addUp(u64 n) {
  var total = u64(0);
  var i = u64(1);
  while (i < n + u64(1)) {
    total = total + i;
    i = i + u64(1);
  }
  return total;
}

@bare u64 greetingLength() => Str("hello from DCDart").length;
```

> **The import path is ugly and that is a real gap, not a style choice.** `dcc` has no `--prelude`
> flag, so the prelude must be reachable as a plain file path — absolute, or relative if your file
> sits inside the repo (the examples use `'../../runtime/dc-core-bare/prelude.dart'`). GAP-0049.

`main.c`:

```c
#include <stdint.h>
#include <stdio.h>
#include "hello.h"

int main(void) {
    printf("addUp(100)       = %llu\n", (unsigned long long)addUp(100));
    printf("greetingLength() = %llu\n", (unsigned long long)greetingLength());
    return 0;
}
```

Build and run:

```bash
dart /path/to/DCDart/core/dcc/bin/dcc.dart build \
     --mode bare --target host hello.dart -o hello.o --emit-header hello.h
clang -o hello main.c hello.o
./hello
```

```
addUp(100)       = 5050
greetingLength() = 17
```

`greetingLength()` returns **17**, the number of UTF-8 **bytes**. Read §6 before you rely on that.

---

## 5. VS Code

There is no DCDart language extension, and `.dart` files are ordinary Dart syntactically, so:

1. **Install the Dart extension** (`Dart-Code.dart-code`) for syntax highlighting, and the **C/C++**
   extension for the `main.c` side.
2. **Expect the Dart analyzer to complain** about `@bare`, `u64`, `Str` and friends in files outside
   the repo. It is analysing against stock `dart:core`, which has none of them. The analyzer being
   unhappy does **not** mean `dcc` will reject your file — they are different front ends, and
   `dcc` is the one that decides. This is worth knowing before it wastes an afternoon.
3. **Use tasks rather than the Dart debugger.** "Run" in the Dart extension starts the Dart VM, which
   is precisely what DCDart does not use. `.vscode/tasks.json` in this repo gives you:
   - **DCDart: run conformance suite** — the full suite, with the host in the summary
   - **DCDart: build current file** — `dcc build --target host` on whatever you have open
   - **DCDart: verify freestanding** — rule 1 on the object you just built

   `Cmd/Ctrl+Shift+P` → *Tasks: Run Task*.
4. **Debugging** is ordinary native debugging of the linked C binary — LLDB on macOS, GDB on Linux.
   Build with `clang -g` and use the C/C++ extension's launch config. There is no DCDart source-level
   debug info yet: you will be stepping through the emitted machine code, and the symbol names are
   your DCDart function names.

---

## 6. Two behaviours that will surprise you

**`.length` counts bytes, not characters.** `Str("héllo").length` is **6** in DCDart and **5** in
upstream Dart, because Dart counts UTF-16 code units and DCDart counts UTF-8 bytes (ADR-0053). This
is silently correct for pure-ASCII text and silently wrong at the first non-ASCII byte — the most
dangerous shape a divergence can take, which is why it is asserted in the suite rather than merely
documented. If you are indexing text, you are indexing bytes.

**Arithmetic traps rather than wrapping.** Overflow, divide-by-zero and `%` by zero all trap and kill
the process (SIGILL on Linux/x86-64, SIGTRAP on macOS/arm64). That is deliberate. Use `&+`, `&-`,
`&*` where wrapping is what you actually want, and say why in a comment.

---

## 7. What does not work yet

Being explicit so you do not spend time concluding it yourself:

| | |
|---|---|
| `--mode hosted` | throws — no backend target designed for it. Everything uses `--mode bare`, which still links into an ordinary native program |
| owning `String`, `StrBuf` | not implemented; blocked on the allocator decision. You can read and slice text, not build it (GAP-0045) |
| closures | `FunctionExpression` is not lowered at all |
| generic classes | generic *functions* are monomorphized (ADR-0052); `Box<T>` is not (GAP-0040) |
| `Str` over the C ABI | no `c_header.dart` mapping yet, so a function taking or returning one is not emitted into the header (GAP-0047) |
| Windows | `--target windows-x86_64` emits, and the target registry is real, but the conformance suite has not been run on a Windows host. Treat it as untested rather than working |

`docs/known-gaps.md` is the honest list and is kept current.

---

## 8. When something breaks

- **`ld: library 'System' not found`** on macOS → Xcode's `clang` is shadowing `/usr/bin/clang`. §1.
- **`mapfile: command not found`** → stock macOS bash 3.2 running a bash 4 script. Fixed in
  `verify-freestanding.sh`; if you hit it elsewhere, that is the cause.
- **`Couldn't resolve the package 'backend'`** → a `pub get` is mid-flight, or `vendor-frontend.sh`
  has not been run. §2.
- **Mass failures across many harnesses at once** → almost always environmental, not a regression.
  An identical message across many targets is one missing tool. Check exit codes: **2 is a setup
  error, 1 is a real failure.**
