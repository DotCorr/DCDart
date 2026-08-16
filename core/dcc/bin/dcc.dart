#!/usr/bin/env dart
// core/dcc/bin/dcc.dart
//
// Entry point for the `dcc` CLI driver (ROADMAP.md M0, README.md "First
// action"). This parses arguments and calls into the compile pipeline; it
// does not implement compilation itself (see lib/pipeline.dart).
//
// This is plain hosted Dart, not DCDart. dcc is bootstrap tooling that
// compiles DCDart -- it does not need to be written in the language it
// compiles, and cannot be yet (DCDart has no working compiler; that
// circularity is exactly why this file exists as plain Dart). See
// core/docs/decisions/0002-dcc-bootstrap-language.md for the full
// reasoning. Because of that, CLAUDE.md's DCDart-specific coding rules
// (sized integers, Result<T,E>/no throw in @bare, ARC weak/unowned) govern
// the language dcc emits code *for*, not the language dcc is written in --
// this file uses ordinary Dart exceptions and exit codes on purpose.
//
// Usage (once a Dart SDK + clang/llvm-nm are on PATH -- see GAP-0001):
//   cd core/dcc && dart pub get   # once, to resolve dcc_lower/backend
//   dart bin/dcc.dart build --mode bare add.dart -o add.o
//
// bin/ still imports lib/ by relative path (not package:), but lib/ now
// imports package:dcc_lower and package:backend (path deps, see
// pubspec.yaml) to do the real compile. That means, unlike when this file
// was first written (see git history / GAP-0002's original text), a
// `dart pub get` inside core/dcc/ IS required before this runs -- the
// "zero pub dependencies" property only ever applied to argument parsing
// (cli_args.dart), never to the compile pipeline itself.
//
// Exit codes:
//   0   success
//   64  usage error (bad or missing arguments)         -- sysexits EX_USAGE
//   65  input file does not exist                      -- sysexits EX_DATAERR
//   1   valid invocation, but compilation failed (see lib/pipeline.dart)

import 'dart:io';

import '../lib/cli_args.dart';
import '../lib/pipeline.dart';

Future<void> main(List<String> argv) async {
  final BuildOptions options;
  try {
    options = parseArgs(argv);
  } on CliHelpRequested {
    stdout.writeln(usage);
    exit(0);
  } on CliUsageError catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }

  final inputFile = File(options.inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('dcc build: input file not found: ${options.inputPath}');
    exit(65);
  }

  try {
    await runBuild(options);
  } catch (e) {
    // Every pipeline-stage error (DccLowerError, KernelFrontendError,
    // BackendError, BackendCompileError, UnimplementedError for
    // --mode hosted) surfaces here as an honest failure: nothing above this
    // catch writes to options.outputPath before throwing, so a non-zero
    // exit here means no output file was produced -- never a partial or
    // fake one (SKILL.md's rule against stubs that fake success applies to
    // failures too: fail loudly, don't half-succeed quietly).
    stderr.writeln('dcc build: $e');
    exit(1);
  }
}
