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
  String clangExecutable = 'clang',
}) async {
  final args = <String>[
    if (targetTriple != null) '--target=$targetTriple',
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
