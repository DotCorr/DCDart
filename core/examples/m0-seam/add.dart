// M0 exit criterion (ROADMAP.md). Compiled with: dcc build --mode bare add.dart -o add.o
// Must produce an object file where `nm -u add.o` prints nothing, and a C
// main linking against it must call add(2, 3) and get 5.
//
// The prelude import is M0's minimal frontend strategy (ADR-0008): `bare` and
// `u64` are not yet builtin DCDart syntax (that needs a real front_end fork,
// M1+ work) -- they're ordinary Dart declarations real, unmodified front_end
// already understands.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
u64 add(u64 a, u64 b) => a + b;
