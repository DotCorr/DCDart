// M2 port-I/O target (docs/decisions/0029-port-io.md, oscortex_core's M0
// escalation). A real, standard 16550 UART (COM1, 0x3F8) initialization
// sequence -- not synthetic busywork, this is the exact sequence
// oscortex_core's own kernel needs, exercised here as a DCDart-side
// structural verification target.
//
// Cannot be executed directly: `outb`/`inb` are privileged (ring-0-only)
// x86 instructions -- running this as a normal Linux userspace process
// would trap (SIGSEGV). See core/tests/conformance/m2-port/run.sh, which
// verifies the emitted disassembly contains the correct instructions
// instead of running the binary.
import '../../runtime/dc-core-bare/prelude.dart';

@bare
void initCom1() {
  Port.outb(u16(0x3F9), u8(0x00)); // disable interrupts
  Port.outb(u16(0x3FB), u8(0x80)); // enable DLAB (divisor-latch access)
  Port.outb(u16(0x3F8), u8(0x03)); // divisor low byte (38400 baud)
  Port.outb(u16(0x3F9), u8(0x00)); // divisor high byte
  Port.outb(u16(0x3FB), u8(0x03)); // 8 bits, no parity, one stop bit
  Port.outb(u16(0x3FA), u8(0xC7)); // enable FIFO, clear, 14-byte threshold
  Port.outb(u16(0x3FC), u8(0x0B)); // IRQs enabled, RTS/DSR set
}

@bare
u8 readLineStatus() {
  return Port.inb(u16(0x3FD));
}
