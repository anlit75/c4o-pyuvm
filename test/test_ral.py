"""
The register model: what regs/apb_uart.rdl says about the design, checked against
the design.

Two tests. The first reads every described register after reset and compares it
with the reset value the model carries -- not with a number written here, so the
.rdl stays the only place the map is stated. The second writes the two registers
that are real storage and reads them back through the model's mirror.

None of this touches THR, RBR, FCR or the divisor latches. They are the four
things SystemRDL cannot describe for this design, the .rdl header says why, and
test_uart.py drives them through the agent instead.
"""

import cocotb
from pyuvm import uvm_check_e, uvm_report_server, uvm_root, uvm_status_e

from uart_env import UartTest, bring_up

# Written with DLAB clear on purpose. LCR[7] re-banks offsets 0x0 and 0x1 to the
# divisor latches, so a register model that set it would then write DLM when it
# thought it was writing IER -- and the mirror would be quietly wrong. Keeping it
# clear is the discipline the model cannot enforce for itself.
LCR_PATTERN = 0x5F      # every bit the design stores, except DLAB
IER_PATTERN = 0x05      # RDA and RLS, not THRE


class ResetValuesTest(UartTest):
    """Every described register reads back what the .rdl says reset leaves it at.

    Worth running rather than assuming: 0x60 in LSR is two status bits the design
    asserts when idle, and 0xC1 in IIR is a hardwired 0b1100 in the read path over
    uart_interrupt's iir_q, which resets to 0b0001. Neither is a value anybody
    would guess, and neither comes from the same mechanism.

    For LSR this is weaker than its name suggests, and the difference was
    measured: change the RTL's LSR reset from 0x60 to 0x00 and this test still
    passes. THRE and TEMT are driven combinationally from tx_elements and
    tx_ready, so regs_n overwrites both on the first clock edge after reset and
    the reset value is never observable from the bus. What this checks for LSR is
    that an idle transmitter reports itself empty -- which is why
    IdleStatusTest below exists to pin the same two bits from the other side.
    """

    async def run(self):
        for reg in (self.env.regs.IER, self.env.regs.IIR,
                    self.env.regs.LCR, self.env.regs.LSR):
            status, value = await reg.read()
            want = reg.get_reset()
            self.logger.info(
                f"{reg.get_name()} reads 0x{value:02x}, .rdl says 0x{want:02x}")
            if status != uvm_status_e.UVM_IS_OK:
                raise AssertionError(f"{reg.get_name()}: read returned {status}")
            if value != want:
                raise AssertionError(
                    f"{reg.get_name()} after reset is 0x{value:02x}, "
                    f"and regs/apb_uart.rdl says 0x{want:02x}"
                )


class RegisterReadbackTest(UartTest):
    """The two registers that are storage hold what was written to them.

    LCR and IER are the only registers in the map the software can write and read
    back: IIR and LSR are status. mirror(UVM_CHECK) is what makes this a register
    test rather than two more bus transfers: it compares the design against the
    model's expectation, so a write that landed in the wrong place is caught even
    though the read itself succeeded.

    The error-count check at the end is what gives that teeth, and it was added
    because the test needed it. pyuvm's do_check() reports a UVM_ERROR and returns
    False -- it does not raise, and a cocotb test does not fail on a UVM_ERROR by
    itself. Measured: with the IER write redirected to MCR in the RTL,
    mirror(UVM_CHECK) logged the mismatch and this test passed.
    """

    async def run(self):
        before = uvm_report_server.get().get_stats().error_count
        for reg, pattern in ((self.env.regs.LCR, LCR_PATTERN),
                             (self.env.regs.IER, IER_PATTERN)):
            status = await reg.write(pattern)
            if status != uvm_status_e.UVM_IS_OK:
                raise AssertionError(f"{reg.get_name()}: write returned {status}")
            self.logger.info(f"{reg.get_name()} <- 0x{pattern:02x}")

        # Read back after both writes rather than between them, so a decode that
        # wrote the right value to the wrong address has somewhere to hide and
        # gets caught anyway.
        for reg in (self.env.regs.LCR, self.env.regs.IER):
            status = await reg.mirror(uvm_check_e.UVM_CHECK)
            if status != uvm_status_e.UVM_IS_OK:
                raise AssertionError(f"{reg.get_name()}: mirror returned {status}")
            self.logger.info(
                f"{reg.get_name()} mirrors 0x{reg.get_mirrored_value():02x}")

        errors = uvm_report_server.get().get_stats().error_count - before
        if errors:
            raise AssertionError(
                f"mirror(UVM_CHECK) reported {errors} mismatch(es) -- the message "
                "above names the register, the value read and the value expected"
            )


class IdleStatusTest(UartTest):
    """An idle transmitter says so in LSR, bit by bit rather than as a byte.

    ResetValuesTest reads the same 0x60 and cannot tell which bit is which. This
    takes the bits apart, so breaking either one alone fails here and names it.
    """

    async def run(self):
        _, value = await self.env.regs.LSR.read()
        for field, want in ((self.env.regs.LSR.THRE, 1),
                            (self.env.regs.LSR.TEMT, 1),
                            (self.env.regs.LSR.DR, 0)):
            # From the value just read, not from field.get_mirrored_value(). These
            # fields are volatile -- the hardware writes them -- so pyuvm does not
            # let a read update their mirror, and warns that the mirrored value
            # "may not reflect the actual current value" if you ask anyway. The
            # position and width still come from the model, so regs/apb_uart.rdl
            # remains the only place the bit numbers are written down.
            got = (value >> field.get_lsb_pos()) & ((1 << field.get_n_bits()) - 1)
            self.logger.info(f"LSR.{field.get_name()} = {got}")
            if got != want:
                raise AssertionError(
                    f"LSR.{field.get_name()} is {got} on an idle transmitter "
                    f"with an empty receiver, and should be {want}"
                )


@cocotb.test()
async def reset_values(dut):
    await bring_up(dut)
    await uvm_root().run_test("ResetValuesTest")


@cocotb.test()
async def register_readback(dut):
    await bring_up(dut)
    await uvm_root().run_test("RegisterReadbackTest")


@cocotb.test()
async def idle_status(dut):
    await bring_up(dut)
    await uvm_root().run_test("IdleStatusTest")
