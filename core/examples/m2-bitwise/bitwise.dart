// M2 bitwise-operator target (docs/decisions/0030-bitwise-operators.md,
// oscortex_core's interrupts-milestone escalation). Unlike Port.outb/inb
// (docs/decisions/0029-port-io.md), these are ordinary, unprivileged
// instructions -- ANDs/ORs/shifts run identically in kernel and
// userspace code, so this target is verified by real execution and an
// exact expected-value check, the strongest form this project's harnesses
// use, not the disassembly-only structural check Port I/O needed.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
u64 andU64(u64 a, u64 b) => a & b;
@bare
u64 orU64(u64 a, u64 b) => a | b;
@bare
u64 xorU64(u64 a, u64 b) => a ^ b;
@bare
u64 shlU64(u64 a, u64 b) => a << b;
@bare
u64 shrU64(u64 a, u64 b) => a >> b;

// One representative function per narrower width -- the dcc-lower
// recognition path is a single generalized block keyed off the width
// prefix (core/dcc-lower/lib/lower.dart), so exercising AND once per
// width is enough to prove the width-parsing branch for each, without
// re-testing all five operators at every width (already proven
// exhaustively at u64 above; the operator-selection logic itself does
// not vary by width).
@bare
u32 andU32(u32 a, u32 b) => a & b;
@bare
u16 andU16(u16 a, u16 b) => a & b;
@bare
u8 andU8(u8 a, u8 b) => a & b;
