// core/dcc/lib/pipeline.dart
//
// The real compilation pipeline, per DCDART_SPEC.md §1 `[LOAD-BEARING]`:
//
//   .dart -> [dart compile kernel] -> Kernel IR (.dill) -> [dcc-lower] ->
//   DC-IR -> [backend] -> LLVM IR -> [clang -c] -> object file
//
// See core/docs/decisions/0008-m0-frontend-strategy.md for why the first
// arrow is "the installed SDK's `dart compile kernel`" rather than "the
// vendored pkg/front_end in-process" — that's a deliberate M0 scoping
// choice, not a shortcut nobody noticed.
//
// M0 scope only: recognizes exactly what core/dcc-lower/lib/lower.dart
// recognizes (one `@bare` top-level function, u64 params/return, `a + b`
// body) and nothing past it — see that file's header for the exact cut and
// core/docs/known-gaps.md for what's tracked as still open.

import 'dart:io';

import 'package:backend/compile.dart';
import 'package:backend/llvm_emit.dart';
import 'package:dcc_lower/lower.dart';

import 'cli_args.dart';

/// Entry point the CLI calls once arguments are parsed AND the input file
/// has been confirmed to exist (see bin/dcc.dart). Writes a real object
/// file to `options.outputPath` on success; throws (and writes nothing) on
/// any failure — see bin/dcc.dart for how each exception type maps to an
/// exit code.
Future<void> runBuild(BuildOptions options) async {
  final preludeUri = _resolvePreludeUri();

  final module = await lowerToDCModule(
    options.inputPath,
    preludeUri: preludeUri,
  );

  // M0's only mode with a real target: `bare` gets the freestanding triple
  // from m0-target.md §1. `hosted` has no backend target designed yet —
  // DCDART_SPEC.md §2's `@hosted` needs an allocator/ORC/threads runtime
  // this project hasn't built, so there is nothing honest to emit for it.
  if (options.mode != BuildMode.bare) {
    throw UnimplementedError(
      '--mode hosted has no backend target yet (only --mode bare, per '
      'core/backend/m0-target.md, is implemented) — see '
      'core/docs/known-gaps.md',
    );
  }
  const targetTriple = 'x86_64-unknown-none-elf';

  final llText = emitModule(module, targetTriple: targetTriple);

  final tempDir = Directory.systemTemp.createTempSync('dcc_backend_');
  try {
    final llFile = File('${tempDir.path}/out.ll')..writeAsStringSync(llText);
    await compileToObject(
      llFile.path,
      options.outputPath,
      targetTriple: targetTriple,
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }
}

/// M0 simplification, not a real library resolver: DCDart's real design
/// (DCDART_SPEC.md §2/§8) wants `dc:core.bare` resolved as a proper scheme,
/// the way `dart:core` is — that needs the actual front_end fork
/// (ADR-0008's "deferred, not abandoned" alternative), not built yet. Until
/// then, dcc locates its own prelude relative to where `dcc.dart` itself
/// lives on disk. This means `dcc` currently only works run from inside
/// this checkout at this exact relative layout — true and worth knowing,
/// not hidden behind a name that suggests it's more general than it is.
Uri _resolvePreludeUri() {
  return Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart');
}
