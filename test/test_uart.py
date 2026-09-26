"""
pyuvm tests for the vendored 16550 UART, driven entirely through its pins.

Three tests, all over the DUT's own loopback: `tx_o` is tied back to `rx_i` in
Python rather than in a Verilog wrapper, because cocotb elaborates the DUT as the
root -- there is no testbench module to do the tie in. That turns out to be the
right thing anyway: a coroutine copying one port to another works the same on the
synthesised netlist, and nothing in these tests or in apb_agent.py reaches inside
the design, so `cocotb --netlist` can run exactly this Python against the gates.

`make cocotb SEED=<n>` repeats a random failure.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from pyuvm import ConfigDB, uvm_root, uvm_sequence, uvm_test

from apb_agent import (DLAB, DLL, DLM, FCR, LCR, LSR, LSR_DATA_READY, RBR,
                       THR, ApbTxn)
from uart_env import UartEnv

# Time is counted in clock cycles, not nanoseconds. The generated Verilog carries
# no `timescale -- there is no testbench module to put one in, since cocotb
# elaborates the DUT as the root -- so Icarus runs at a precision of one second
# and asking for a 10 ns period is an error. It costs nothing: the design is
# fully synchronous and contains no delays, so only the order of edges matters.
CLOCK_PERIOD_STEPS = 2
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


class UartTestBase(uvm_test):
    payload = ()
    burst = False

    def build_phase(self):
        # Here, not in bring_up: uvm_root().run_test() clears the singletons
        # before it builds the tree, so anything put in the ConfigDB beforehand
        # is gone by the time the agent looks for it. uvm_test_top's build_phase
        # runs before its children's, which is early enough.
        ConfigDB().set(None, "*", "dut", cocotb.top)
        self.env = UartEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        # Logged so that a random failure is reproducible from the log alone:
        # the bytes are here and cocotb prints the seed that produced them.
        self.logger.info("payload: " + " ".join(f"{b:02x}" for b in self.payload))
        seq = UartSeq("seq", self.payload, burst=self.burst)
        await seq.start(self.env.agent.sequencer)
        self.drop_objection()


class LoopbackTest(UartTestBase):
    """One known byte, so a failure here means nothing else is worth reading."""
    payload = (0xA5,)


class RandomBytesTest(UartTestBase):
    """One byte at a time, twenty times, so the FIFO pointers wrap past 16.

    The payload is built when this module is imported, and cocotb seeds Python's
    random module before importing it, so `make cocotb SEED=<n>` reproduces the
    exact bytes a failure was found with.
    """
    payload = tuple(random.randrange(256) for _ in range(20))


class BurstTest(UartTestBase):
    """A full TX FIFO in one go, then drained in order.

    16 is TX_FIFO_DEPTH. Sending them one at a time, as the test above does,
    never puts more than one byte in the FIFO at once, so it cannot tell a queue
    from a register -- this one can.
    """
    payload = tuple(random.randrange(256) for _ in range(16))
    burst = True


async def bring_up(dut):
    """Clock, reset, and the loopback that makes the DUT talk to itself."""
    cocotb.start_soon(Clock(dut.CLK, CLOCK_PERIOD_STEPS, units="step").start())

    dut.RSTN.value = 0
    dut.PSEL.value = 0
    dut.PENABLE.value = 0
    dut.PWRITE.value = 0
    dut.PADDR.value = 0
    dut.PWDATA.value = 0
    dut.rx_i.value = 1          # an idle line is high; 0 would look like a start bit
    await ClockCycles(dut.CLK, 4)
    dut.RSTN.value = 1
    await ClockCycles(dut.CLK, 4)

    async def tie_tx_to_rx():
        while True:
            await RisingEdge(dut.CLK)
            dut.rx_i.value = dut.tx_o.value
    cocotb.start_soon(tie_tx_to_rx())


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
