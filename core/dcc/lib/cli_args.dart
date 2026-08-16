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

  const BuildOptions({
    required this.mode,
    required this.inputPath,
    required this.outputPath,
  });

  @override
  String toString() =>
      'dcc build --mode ${mode.name} $inputPath -o $outputPath';
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
Usage: dcc build --mode <bare|hosted> <input.dart> -o <output.o>

Commands:
  build     Compile a DCDart source file to a native object file.

Options for build:
  --mode <bare|hosted>     Compilation mode (DCDART_SPEC.md §2). Required.
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
BuildOptions parseArgs(List<String> args) {
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

  return _parseBuildArgs(args.skip(1).toList());
}

BuildOptions _parseBuildArgs(List<String> args) {
  BuildMode? mode;
  String? outputPath;
  String? inputPath;

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
  );
}
