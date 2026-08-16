# ADR-0008: M0 uses an extension-type prelude + unmodified front_end, not a real CFE fork

**Status:** decided

## Context

`DCDART_SPEC.md` §1 wants a real fork of `pkg/front_end` that natively understands DCDart syntax
(`@bare`, sized integers like `u64`, trapping arithmetic). Actually forking a compiler frontend
this size — modifying its parser, resolver, and type inference to add new builtin types and
semantics — is substantial, multi-week compiler engineering, not something to attempt blind in one
pass. M0's own stated goal (`ROADMAP.md`: "roughly 200 lines of output... validates the entire
backend architecture") suggests the project's own authors expected M0's frontend problem to be
small, not "fork a CFE."

Empirically tested (not guessed) with the real vendored/installed toolchain: Dart's **extension
types** (stable since Dart 3.3, so fully supported by the vendored `3.12.2` front_end with zero
source modification) let `u64` exist as a real, distinct type — a genuine `ExtensionType` Kernel IR
node with a recorded erasure (`int`) — using only ordinary library code. An annotation class gives
`@bare` the same treatment: a `ConstantExpression`/`InstanceConstant` Kernel IR node, no parser
changes needed. Verified end to end: `dart compile kernel` (the installed SDK's stable CLI, backed
by front_end) compiles `@bare u64 add(u64 a, u64 b) => a + b;` — given a library defining `bare` and
`u64` this way — into real Kernel IR with zero front_end/parser changes.

## Decision

For M0: `core/runtime/dc-core-bare/prelude.dart` defines `bare` (a const annotation) and `u64` (an
extension type over `int`, with `+`) as ordinary Dart. `core/examples/m0-seam/add.dart` imports it.
`core/dcc-lower`'s frontend stage:

1. Shells out to the installed SDK's `dart compile kernel` (not the vendored front_end's internal
   API in-process) via a synthetic driver file — `import 'add.dart' as target; import 'prelude.dart';
   void main() { target.add(u64(0), u64(0)); }` — written to a temp file alongside the real source.
   `dart compile kernel` requires a `main` entry point; the driver supplies one without ever
   modifying the user's actual source file. `--no-link-platform` keeps the platform library summary
   out of the emitted `.dill` (not needed downstream).
2. Loads the resulting `.dill` via the vendored `pkg/kernel` library (`loadComponentFromBinary`).
3. Finds the library matching the real source file's URI (not the driver's, not the prelude's) and
   its `add` procedure.

Empirically confirmed exact node shapes to match against (see conversation record / re-derivable by
rerunning the same introspection against `out.dill`):
- The `@bare` annotation: `Procedure.annotations` contains one `ConstantExpression` whose
  `.constant` is an `InstanceConstant` with `.classNode.name == '_Bare'` and
  `.classNode.enclosingLibrary.importUri` equal to the prelude's URI.
- Each `u64`-typed parameter/return: `.type is ExtensionType`, with
  `.extensionTypeDeclaration.name == 'u64'` and `.extensionTypeDeclaration.enclosingLibrary.importUri`
  equal to the prelude's URI (checking the library, not just the name, so an unrelated user type
  named `u64` elsewhere can never be misread as DCDart's).
- `a + b`: `FunctionNode.body is ReturnStatement` (not wrapped in a `Block` for this single-expression
  case) whose `.expression is StaticInvocation` with `.target.name.text == 'u64|+'`,
  `.target.isExtensionTypeMember == true`, `.target.enclosingLibrary` equal to the prelude's URI, and
  `.arguments.positional` are two `VariableGet`s naming the parameters.

## Rejected alternatives

- **Embed vendored `pkg/front_end`'s API in-process instead of shelling out to `dart compile
  kernel`.** Rejected for M0 specifically: front_end's programmatic surface lives mostly under
  `src/`, explicitly marked internal/unstable, and correctly driving `CompilerOptions` +
  `kernelForProgram` (target selection, platform summary supply, error-message plumbing) is real
  additional work with no payoff for M0's one-function target. `dart compile kernel` is the stable,
  supported CLI surface and gets identical Kernel IR. **This is deferred, not abandoned:** once
  DCDart needs syntax an extension-type/annotation prelude genuinely cannot express (trapping
  arithmetic as a first-class type property, `@bare`/`@hosted` changing what's even legal to parse,
  true builtin syntax with no import), that's when embedding the vendored front_end and actually
  modifying it becomes necessary — the vendoring work (ADR-0005/0007) was not wasted, it's ready for
  that day.
- **Fork front_end now to make `u64`/`@bare` truly builtin.** Rejected for M0 for the reason in
  Context: real scope, no current pressure to justify it (a working, honestly-scoped M0 doesn't
  need it), and the roadmap's own framing of M0 as small supports deferring it.

## Consequences

- `add.dart`'s exact text is no longer *only* `@bare\nu64 add(u64 a, u64 b) => a + b;` — it also
  imports the prelude. The M0 exit criterion in `ROADMAP.md` doesn't specify import-freedom, so this
  is judged compliant; flagging here so nobody is surprised the file isn't byte-for-byte the
  roadmap's inline snippet.
- `core/dcc-lower`'s Kernel-IR-walking code is necessarily narrow and pattern-specific (matching
  exact library URIs and member names from the prelude) rather than a general Kernel-IR-to-DC-IR
  compiler. That's correct for M0's scope — see `core/dcc-lower/README.md` for the explicit scope
  cut — and will need real generalization once M1 grows the type surface.
- `core/frontend/vendor/dart-sdk/pkg/front_end` (ADR-0005/0007) is not invoked by any code yet. It
  remains vendored and pub-resolvable for when embedding it directly becomes necessary.
