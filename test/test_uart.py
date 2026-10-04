"""
The data path: three tests, all over the DUT's own loopback.

`tx_o` is tied back to `rx_i` in Python rather than in a Verilog wrapper, because
cocotb elaborates the DUT as the root -- there is no testbench module to do the
tie in. That turns out to be the right thing anyway: a coroutine copying one port
to another works the same on the synthesised netlist, and nothing in these tests
or in apb_agent.py reaches inside the design, so `make gatesim` runs exactly
this Python against the gates.

The registers are driven raw here, not through the register model. That is on
purpose: THR, RBR, FCR and the divisor latches are the four things
regs/apb_uart.rdl cannot describe, and its header says why. test_ral.py covers
what the model does describe.

`make cocotb SEED=<n>` repeats a random failure.
"""

import random

import cocotb
from pyuvm import uvm_root, uvm_sequence

from apb_agent import DLAB, DLL, DLM, FCR, LCR, LSR, LSR_DATA_READY, RBR, THR, ApbTxn
from uart_env import UartTest, bring_up

DIVISOR = 4             # cycles per UART bit, minus one

# A frame is ten bits of (DIVISOR + 1) cycles, so a byte needs ~50. Polling far
# longer than that and then failing is deliberate: without a bound, a DUT that
# never delivers looks like a slow test rather than a broken one.
LSR_POLL_LIMIT = 5000


class UartSeq(uvm_sequence):
    """Configure 8N1 at DIVISOR, then send bytes and read each one back.

    With `burst`, every byte is written to THR before any is read, which is the
    only way to put more than one at a time into the 16-deep TX FIFO.
    """

    def __init__(self, name, payload, burst=False):
        super().__init__(name)
        self.payload = payload
        self.burst = burst

    async def write(self, addr, data):
        txn = ApbTxn("w", addr=addr, data=data, write=True)
        await self.start_item(txn)
        await self.finish_item(txn)
        return txn

    async def read(self, addr):
        txn = ApbTxn("r", addr=addr, write=False)
        await self.start_item(txn)
        await self.finish_item(txn)
        return txn.rdata

    async def body(self):
        # The divisor latches are only reachable with DLAB set, so LCR first.
        await self.write(LCR, DLAB)
        await self.write(DLL, DIVISOR)
        await self.write(DLM, 0x00)
        await self.write(LCR, 0x03)          # DLAB off, 8 data bits
        await self.write(FCR, 0b110)         # clear both FIFOs

        if self.burst:
            for byte in self.payload:
                await self.write(THR, byte)
            for byte in self.payload:
                await self.receive(byte)
        else:
            for byte in self.payload:
                await self.write(THR, byte)
                await self.receive(byte)

    async def receive(self, byte):
        """Wait for one byte to arrive, then read it. The scoreboard checks it."""
        for _ in range(LSR_POLL_LIMIT):
            if await self.read(LSR) & LSR_DATA_READY:
                break
        else:
            raise AssertionError(
                f"LSR[0] never went high after {LSR_POLL_LIMIT} reads -- "
                f"0x{byte:02x} did not arrive"
            )
        await self.read(RBR)


class LoopbackTest(UartTest):
    """One known byte, so a failure here means nothing else is worth reading."""
    payload = (0xA5,)
    burst = False

    async def run(self):
        self.logger.info("payload: " + " ".join(f"{b:02x}" for b in self.payload))
        seq = UartSeq("seq", self.payload, burst=self.burst)
        await seq.start(self.env.agent.sequencer)


class RandomBytesTest(LoopbackTest):
    """One byte at a time, twenty times, so the FIFO pointers wrap past 16.

    The payload is built when this module is imported, and cocotb seeds Python's
    random module before importing it, so `make cocotb SEED=<n>` reproduces the
    exact bytes a failure was found with.
    """
    payload = tuple(random.randrange(256) for _ in range(20))


class BurstTest(LoopbackTest):
    """A full TX FIFO in one go, then drained in order.

    16 is TX_FIFO_DEPTH. Sending them one at a time, as the test above does,
    never puts more than one byte in the FIFO at once, so it cannot tell a queue
    from a register -- this one can.
    """
    payload = tuple(random.randrange(256) for _ in range(16))
    burst = True


@cocotb.test()
async def loopback(dut):
    await bring_up(dut)
    await uvm_root().run_test("LoopbackTest")


@cocotb.test()
async def random_bytes(dut):
    await bring_up(dut)
    await uvm_root().run_test("RandomBytesTest")


@cocotb.test()
async def burst(dut):
    await bring_up(dut)
    await uvm_root().run_test("BurstTest")
