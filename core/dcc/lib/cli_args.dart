// core/dcc/lib/cli_args.dart
//
// Hand-rolled argument parsing for the `dcc` CLI driver.
//
// No external packages -- not even package:args from pub.dev. dcc is
// bootstrap tooling that needs to run the moment a bare Dart SDK lands on
// PATH in this environment, without a `dart pub get` step (no vendored
// packages, possibly no network). See
// core/docs/decisions/0002-dcc-bootstrap-language.md.
//
// M0 scope only: one subcommand (`build`), three flags/positionals
// (`--mode`, input path, `-o`/`--output`). Extend as later milestones add
// subcommands -- do not pre-build flags nothing calls yet.

import 'dart:io' show Platform;

import 'package:backend/targets.dart';

/// The two compilation modes from DCDART_SPEC.md §2. `[LOAD-BEARING]` --
/// do not add a third value or rename these without a spec change.
enum BuildMode {
  bare,
  hosted;

  static BuildMode? tryParse(String value) {
    for (final mode in BuildMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// Parsed, validated arguments for `dcc build`. Construction is only
/// possible via [parseArgs] succeeding, so any [BuildOptions] in hand has
/// already passed argument-level validation (valid mode, both paths
/// present). It has NOT been checked against the filesystem -- that is the
/// caller's job (see bin/dcc.dart).
class BuildOptions {
  final BuildMode mode;
  final String inputPath;
  final String outputPath;

  /// Which machine/OS/object-format to emit for (ADR-0033). Orthogonal to
  /// [mode] -- see backend/lib/targets.dart's header for why. Defaults to
  /// [DCTarget.defaultTarget], so an invocation that predates `--target`
  /// compiles exactly the object it always did.
  final DCTarget target;

  /// Where to write the generated C header, or null if `--emit-header` was
  /// not passed (ADR-0034). Emitting a header does not replace the object
  /// file; both are produced.
  final String? headerPath;

  /// Bytes per size-class heap region (ADR-0058), or null to take the
  /// target-dependent default: 2 MiB per class hosted, 64 KiB per class
  /// freestanding, because freestanding `.bss` is physical frames a kernel
  /// must find at boot rather than address space an OS backs lazily.
  ///
  /// Exposed mainly so a test can ask for a DELIBERATELY TINY heap and reach
  /// the out-of-memory boundary in a few allocations. Without it, proving the
  /// OOM path means allocating 65,536 objects, which is slow and — since
  /// allocation inside a loop is not yet supported — would have to be done by
  /// recursing 65,537 frames deep, testing the C stack as much as the heap.
  final int? heapRegionBytes;

  /// Which file is THE PRELUDE, or null to use the one beside this `dcc`
  /// (`Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart')`).
  ///
  /// `@bare` is recognised by comparing an annotation's library URI against
  /// this one, as EXACT Uri equality on a lexically normalised path — `..` is
  /// folded, symlinks are resolved on neither side. So a program importing
  /// the prelude by any other spelling has no `@bare` functions as far as
  /// `dcc` is concerned, and fails with `no @bare top-level function found`,
  /// which reads as a broken compiler rather than a path mismatch.
  ///
  /// Before this flag the prelude was hard-wired, so a consumer whose source
  /// lives outside this repo had to spell its import exactly the way `dcc`
  /// happened to derive it — which made a downstream kernel's build
  /// non-portable across checkouts and cost a day of misattributed failures.
  final String? preludePath;

  const BuildOptions({
    required this.mode,
    required this.inputPath,
    required this.outputPath,
    this.target = DCTarget.defaultTarget,
    this.headerPath,
    this.heapRegionBytes,
    this.preludePath,
  });

  @override
  String toString() =>
      'dcc build --mode ${mode.name} --target $target $inputPath '
      '-o $outputPath${headerPath == null ? '' : ' --emit-header $headerPath'}';
}

/// Thrown for any argument-parsing problem: unknown command, missing
/// required flag, bad flag value, missing positional, unrecognized option.
/// Always a user error (bad invocation) -- never a compiler-pipeline error.
/// pipeline.dart's errors (DccLowerError, BackendError, etc.) are separate
/// and only ever thrown after argument parsing has already succeeded.
class CliUsageError implements Exception {
  final String message;
  const CliUsageError(this.message);

  @override
  String toString() => message;
}

/// Thrown when the user explicitly asked for help (`-h`/`--help`). Kept
/// distinct from [CliUsageError] so the caller can exit 0 on stdout instead
/// of exit 64 on stderr -- asking for help is not an error.
class CliHelpRequested implements Exception {
  const CliHelpRequested();
}

const String usage = '''
Usage: dcc build --mode <bare|hosted> [--target <target>] <input.dart> -o <output.o>

Commands:
  build     Compile a DCDart source file to a native object file.

Options for build:
  --mode <bare|hosted>     Compilation mode (DCDART_SPEC.md §2). Required.
  --target <target>        Machine/OS to emit for. Optional; defaults to
                           bare-x86_64. Use "host" for the current machine.
                           Orthogonal to --mode: a @bare object is a plain
                           C-ABI object and links into an ordinary native
                           program on any of these.
  --prelude <path>         Which file is the prelude. Defaults to the one
                           beside this dcc. `@bare` is recognised by comparing
                           library URIs as EXACT equality on a lexically
                           normalised path (symlinks resolved on neither
                           side), so a program importing the prelude by a
                           different spelling has no @bare functions as far as
                           dcc is concerned. Use this when your source lives
                           outside the DCDart repo.
  --heap-region-bytes <n>  Bytes per size-class heap region (ADR-0058).
                           Power of two, >= 4096. Total heap is 8x this.
                           Default: 2 MiB per class hosted (16 MiB total),
                           64 KiB per class freestanding (512 KiB total) --
                           freestanding .bss is physical frames a kernel must
                           find at boot, not address space an OS backs lazily.
  --emit-header <path>     Also write a C header declaring every exported
                           function, so C/Rust/Python can FFI into it.
  -o, --output <path>      Output object file path. Required.
  <input.dart>             Positional. Path to the DCDart source file.

  -h, --help               Show this message.

Exit codes:
  0   success
  64  usage error (bad or missing arguments)
  65  input file does not exist
  1   valid invocation, but compilation failed (frontend, dcc-lower, or
      backend error -- see stderr for which stage and why)
''';

/// Parses the full `dcc <command> [args...]` invocation (argv without the
/// program name). Only `build` exists at M0; anything else is a usage
/// error, not a silently-ignored no-op.
BuildOptions parseArgs(
  List<String> args, {
  String? hostOsName,
  String? hostArchName,
}) {
  if (args.isEmpty) {
    throw CliUsageError('dcc: missing command\n\n$usage');
  }
  if (args.first == '-h' || args.first == '--help') {
    throw const CliHelpRequested();
  }

  final command = args.first;
  if (command != 'build') {
    throw CliUsageError('dcc: unknown command "$command"\n\n$usage');
  }

  return _parseBuildArgs(
    args.skip(1).toList(),
    hostOsName: hostOsName ?? Platform.operatingSystem,
    hostArchName: hostArchName ?? Platform.version,
  );
}

BuildOptions _parseBuildArgs(
  List<String> args, {
  required String hostOsName,
  required String hostArchName,
}) {
  BuildMode? mode;
  String? outputPath;
  String? inputPath;
  DCTarget? target;
  String? headerPath;
  int? heapRegionBytes;
  String? preludePath;

  var i = 0;
  while (i < args.length) {
    final arg = args[i];

    if (arg == '-h' || arg == '--help') {
      throw const CliHelpRequested();
    }

    if (arg == '--mode') {
      if (i + 1 >= args.length) {
        throw const CliUsageError(
          'dcc build: --mode requires a value (bare|hosted)',
        );
      }
      final value = args[i + 1];
      final parsed = BuildMode.tryParse(value);
      if (parsed == null) {
        throw CliUsageError(
          'dcc build: invalid --mode "$value" (expected "bare" or "hosted")',
        );
      }
      mode = parsed;
      i += 2;
      continue;
    }

    if (arg == '--target') {
      if (i + 1 >= args.length) {
        throw CliUsageError(
          'dcc build: --target requires a value\n\n${DCTarget.describeAll()}',
        );
      }
      final value = args[i + 1];
      try {
        target = DCTarget.parse(
          value,
          hostOsName: hostOsName,
          hostArchName: hostArchName,
        );
      } on UnsupportedTargetError catch (e) {
        // A bad --target is a usage error like any other bad flag value, so
        // it exits 64 rather than 1. The registry's own message already
        // lists every supported target, so it is passed through unchanged.
        throw CliUsageError('dcc build: ${e.message}');
      }
      i += 2;
      continue;
    }

    if (arg == '--prelude') {
      if (i + 1 >= args.length) {
        throw CliUsageError(
          'dcc build: --prelude requires a value (path to prelude.dart)',
        );
      }
      preludePath = args[i + 1];
      i += 2;
      continue;
    }

    if (arg == '--heap-region-bytes') {
      if (i + 1 >= args.length) {
        throw CliUsageError(
          'dcc build: --heap-region-bytes requires a value (bytes per size '
          'class, a power of two >= 4096)',
        );
      }
      final raw = args[i + 1];
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed <= 0) {
        throw CliUsageError(
          'dcc build: --heap-region-bytes must be a positive integer, got '
          '"$raw"',
        );
      }
      // The power-of-two requirement is enforced again in the backend, which
      // is where the shift is actually emitted. Checked here too so a typo is
      // a usage error at the CLI rather than a compiler error deep in
      // emission -- the two messages explain the same constraint from the two
      // ends a reader might hit it from.
      if (parsed & (parsed - 1) != 0) {
        throw CliUsageError(
          'dcc build: --heap-region-bytes must be a power of two, got $parsed. '
          'The size-class-from-address computation is emitted as a shift; a '
          'non-power-of-two would push freed blocks onto the wrong free list.',
        );
      }
      heapRegionBytes = parsed;
      i += 2;
      continue;
    }

    if (arg == '--emit-header') {
      if (i + 1 >= args.length) {
        throw CliUsageError(
          'dcc build: --emit-header requires a value (output .h path)',
        );
      }
      headerPath = args[i + 1];
      i += 2;
      continue;
    }

    if (arg == '-o' || arg == '--output') {
      if (i + 1 >= args.length) {
        throw CliUsageError('dcc build: $arg requires a value (output path)');
      }
      outputPath = args[i + 1];
      i += 2;
      continue;
    }

    if (arg.startsWith('-')) {
      throw CliUsageError('dcc build: unrecognized option "$arg"\n\n$usage');
    }

    if (inputPath != null) {
      throw CliUsageError(
        'dcc build: multiple input paths given ("$inputPath" and "$arg"); '
        'dcc compiles one file at a time',
      );
    }
    inputPath = arg;
    i += 1;
  }

  final missing = <String>[
    if (mode == null) '--mode <bare|hosted>',
    if (inputPath == null) '<input.dart>',
    if (outputPath == null) '-o/--output <path>',
  ];
  if (missing.isNotEmpty) {
    throw CliUsageError(
      'dcc build: missing required argument(s): ${missing.join(', ')}\n\n$usage',
    );
  }

  return BuildOptions(
    mode: mode!,
    inputPath: inputPath!,
    outputPath: outputPath!,
    target: target ?? DCTarget.defaultTarget,
    headerPath: headerPath,
    heapRegionBytes: heapRegionBytes,
    preludePath: preludePath,
  );
}
