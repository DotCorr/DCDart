// A busy-wait poll through a port -- the shape oscortex_core's UART output
// depends on, and the reason it needs its own conformance target.
//
// `Port.inb` is safe under optimization only because ADR-0029 lowers it to
// LLVM `asm sideeffect`. ADR-0041 (volatile Load/Store) does NOT apply to it:
// PortIn/PortOut are a different code path entirely. So the safety here is
// INCIDENTAL to a decision made for another reason, load-bearing for a real
// kernel, and was untested until this target existed.
//
// If the lowering ever loses `sideeffect`, LLVM may hoist the read out of the
// loop, and the failure mode is the worst kind: the poll spins forever on a
// stale Line Status Register. No wrong bytes, no crash -- the machine just
// stops.
import '../../runtime/dc-core-bare/prelude.dart';

/// Polls the 16550 Line Status Register until the transmit-holding-register-
/// empty bit (0x20) sets, bounded so a test can call it.
@bare
u64 waitTxReady(u64 limit) {
  var i = u64(0);
  while (i < limit) {
    final status = Port.inb(u16(0x3FD));
    if ((status & u8(0x20)) > u8(0)) {
      return i;
    }
    i = i + u64(1);
  }
  return limit;
}

/// A fixed sequence of writes to the same port. Each is a distinct side
/// effect the hardware observes in order; none may be coalesced or dropped
/// however identical they look to the optimizer.
@bare
u64 writeThree(u8 a, u8 b, u8 c) {
  Port.outb(u16(0x3F8), a);
  Port.outb(u16(0x3F8), b);
  Port.outb(u16(0x3F8), c);
  return u64(3);
}
