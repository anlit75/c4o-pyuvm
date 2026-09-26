"""
An APB3 agent for the DUT's register interface.

APB3 is two phases and no backpressure worth modelling: PSEL with the address in
the setup phase, PENABLE in the access phase, and the slave answers by holding
PREADY high -- which this DUT does unconditionally (`assign PREADY = 1'b1`). So
the driver is a fixed three-cycle sequence rather than a state machine, and the
monitor only has to notice the cycle where PSEL, PENABLE and PREADY are all set.

Nothing here touches anything but the top-level ports. That is deliberate: the
same tests run against the synthesised netlist, where every internal name is
gone, and a monitor that peeked at `dut.regs_q` would work on the RTL and fail
on the gates with an AttributeError.
"""

from cocotb.triggers import RisingEdge
from pyuvm import (ConfigDB, uvm_agent, uvm_analysis_port, uvm_driver,
                   uvm_monitor, uvm_sequence_item, uvm_sequencer)

# 16550 offsets, from the DUT's own parameter list. The pairs share an address:
# THR is a write and RBR the read at 0x0, FCR a write and IIR the read at 0x2,
# and DLL/DLM replace THR/IER entirely while LCR[7] (DLAB) is set.
THR = RBR = DLL = 0x0
IER = DLM = 0x1
IIR = FCR = 0x2
LCR = 0x3
LSR = 0x5

DLAB = 1 << 7          # LCR[7]
LSR_DATA_READY = 1 << 0


class ApbTxn(uvm_sequence_item):
    """One APB transfer. `rdata` is filled in by the driver on a read."""

    def __init__(self, name="apb_txn", addr=0, data=0, write=False):
        super().__init__(name)
        self.addr = addr
        self.data = data
        self.write = write
        self.rdata = None

    def __str__(self):
        if self.write:
            return f"W 0x{self.addr:x} <- 0x{self.data & 0xff:02x}"
        got = "?" if self.rdata is None else f"0x{self.rdata & 0xff:02x}"
        return f"R 0x{self.addr:x} -> {got}"


class ApbDriver(uvm_driver):
    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "dut")

    async def run_phase(self):
        self.dut.PSEL.value = 0
        self.dut.PENABLE.value = 0
        self.dut.PWRITE.value = 0
        while True:
            txn = await self.seq_item_port.get_next_item()
            await self.transfer(txn)
            self.seq_item_port.item_done()

    async def transfer(self, txn):
        await RisingEdge(self.dut.CLK)
        self.dut.PADDR.value = txn.addr
        self.dut.PWDATA.value = txn.data
        self.dut.PWRITE.value = 1 if txn.write else 0
        self.dut.PSEL.value = 1
        self.dut.PENABLE.value = 0

        await RisingEdge(self.dut.CLK)
        self.dut.PENABLE.value = 1

        # PRDATA is combinational from the decode, so the access phase is where
        # it is valid -- read it at the edge that ends the phase, before letting
        # PSEL go.
        await RisingEdge(self.dut.CLK)
        if not txn.write:
            txn.rdata = int(self.dut.PRDATA.value)
        self.dut.PSEL.value = 0
        self.dut.PENABLE.value = 0
        self.dut.PWRITE.value = 0


class ApbMonitor(uvm_monitor):
    """Broadcasts every completed transfer, reconstructed from the pins."""

    def build_phase(self):
        self.dut = ConfigDB().get(self, "", "dut")
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            await RisingEdge(self.dut.CLK)
            if not (self.dut.PSEL.value and self.dut.PENABLE.value
                    and self.dut.PREADY.value):
                continue
            write = bool(self.dut.PWRITE.value)
            txn = ApbTxn("observed",
                         addr=int(self.dut.PADDR.value) & 0x7,
                         data=int(self.dut.PWDATA.value) if write else 0,
                         write=write)
            if not write:
                txn.rdata = int(self.dut.PRDATA.value)
            self.ap.write(txn)


class ApbAgent(uvm_agent):
    def build_phase(self):
        self.sequencer = uvm_sequencer("sequencer", self)
        self.driver = ApbDriver("driver", self)
        self.monitor = ApbMonitor("monitor", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.sequencer.seq_item_export)
        self.ap = self.monitor.ap
