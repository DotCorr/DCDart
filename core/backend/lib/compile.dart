// core/backend/lib/compile.dart
//
// Turns emitted LLVM IR text into a native object file. Uses `clang -c`
// (m0-target.md §3b), not `llc` (§3a) — the LLVM.LLVM winget package this
// project's toolchain was installed from ships `clang`/`llvm-nm` but not a
// standalone `llc` binary (verified: `llc` absent from its bin/ directory).
// §3b's caveat table about several `-f*` flags being "likely no-op for
// `.ll` input" is accepted here for the same reason the doc gives: this is
// the path that's actually being relied on, not a fallback, so the caveat
// is worth re-reading if a future flag turns out to matter.

import 'dart:io';

/// Compiles the LLVM IR text at [llPath] to a native object file at
/// [objPath] via `clang -c`. [targetTriple] should match (or be null,
/// matching) whatever [llPath]'s own `target triple` line says — passing a
/// conflicting triple here doesn't error, it silently overrides the file's
/// own, so callers must keep the two in sync themselves (this function
/// doesn't read the .ll to check).
Future<void> compileToObject(
  String llPath,
  String objPath, {
  String? targetTriple,
  bool noRedZone = false,
  bool noFpRegs = false,
  String optLevel = '2',
  String clangExecutable = 'clang',
}) async {
  final args = <String>[
    if (targetTriple != null) '--target=$targetTriple',
    // Optimization level (ADR-0042). Until this landed dcc passed no -O at
    // all, so every DCDart program shipped -O0 code: locals spilled to the
    // stack, constants materialized in two instructions, no register
    // allocation worth the name.
    //
    // -O2 rather than -O3: -O3 trades size for aggressive unrolling and
    // vectorization, which is the wrong default for kernel code, and nothing
    // has measured a case where it wins here. -Os is the other defensible
    // choice for @bare and is a per-target question nobody has needed yet.
    //
    // ORDERING: this could not land before ADR-0041 made MMIO access
    // volatile. At -O2 a non-volatile MMIO read-back is deleted outright,
    // and the conformance suite could not see it (GAP-0006/GAP-0027).
    // Since ADR-0069's device/ordinary split, volatile is carried by
    // `Volatile<T>` only; ordinary `Pointer<T>` access is plain and -O2
    // may vectorize it (the GAP-0034 fix).
    '-O$optLevel',
    // The x86-64 red zone is unusable in kernel/bare-metal code: an interrupt
    // pushes its frame at RSP, straight over a leaf function's red-zone
    // locals. Correct in userland, silent corruption in a kernel. See
    // docs/decisions/0039-no-red-zone-on-freestanding-targets.md — the caller
    // derives this from the target rather than passing it by hand.
    if (noRedZone) '-mno-red-zone',
    // NO FP/SIMD REGISTERS ON FREESTANDING TARGETS.
    //
    // Same shape as `-mno-red-zone` above, derived from the same property,
    // and correctness rather than performance for the same kind of reason.
    //
    // THE BUG THIS FIXES. LLVM turns an ordinary `u64` zeroing loop into
    // `xorps %xmm0, %xmm0` + `movaps` stores. That puts SSE into a `@bare`
    // object whose source contains no floating point anywhere -- measured on
    // a 512-iteration `.bss` zeroing loop, and observed downstream as 275
    // xmm instructions appearing in `oscortex_core`'s kernel with no source
    // change, breaking its `m11-proc` harness.
    //
    // WHY IT IS CORRECTNESS. A kernel that never touches XMM can defer
    // saving FPU state; `oscortex_core` saves it hundreds of instructions
    // into `procYield`, which is sound only under that assumption. Once the
    // compiler puts SSE into `chanInit`/`elfInit`, a preempted process can
    // have its FPU state corrupted by kernel code that never asked for a
    // floating-point register.
    //
    // WHY `-fno-vectorize` IS NOT ENOUGH, measured rather than assumed:
    //
    //     (baseline)                          xmm=9
    //     -fno-vectorize -fno-slp-vectorize   xmm=5
    //     -mprefer-vector-width=0             xmm=9
    //     -mgeneral-regs-only                 xmm=0
    //
    // Disabling the vectorizers leaves the `memset` that loop-idiom
    // recognition forms, which is then expanded with vector stores. Only
    // forbidding the register class removes all of it.
    //
    // THE COST, STATED PLAINLY: on x86-64, using a float MEANS using xmm. So
    // this makes `@bare` floating point unavailable by default -- which is
    // the honest position rather than a limitation, because a `@bare` program
    // using FP has taken on an FPU-state obligation its host kernel may not
    // know about. `--allow-fp` opts in and says so out loud; the failure
    // without it is a clang diagnostic at the use site, not a silent xmm
    // appearing in a zeroing loop.
    if (noFpRegs) '-mgeneral-regs-only',
    '-ffreestanding',
    '-fno-builtin',
    '-fno-stack-protector',
    '-fno-exceptions',
    '-fno-unwind-tables',
    '-fno-asynchronous-unwind-tables',
    '-c',
    llPath,
    '-o',
    objPath,
  ];

  final ProcessResult result;
  try {
    result = await Process.run(clangExecutable, args);
  } on ProcessException catch (e) {
    throw BackendCompileError(
      'could not run "$clangExecutable" (${e.message}) — is LLVM/Clang on '
      'PATH? See core/docs/known-gaps.md GAP-0001.',
    );
  }

  if (result.exitCode != 0) {
    throw BackendCompileError(
      '$clangExecutable failed (exit ${result.exitCode}) compiling $llPath:\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}

class BackendCompileError extends Error {
  final String message;
  BackendCompileError(this.message);

  @override
  String toString() => 'BackendCompileError: $message';
}
