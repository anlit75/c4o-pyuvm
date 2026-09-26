"""
The environment: one APB agent and a scoreboard that models the loopback.

The scoreboard never looks at the serial line. `tx_o` is tied back to `rx_i`, so
every byte written to THR has to reappear, in order, from RBR -- and that is the
whole design in one relation: APB decode, TX FIFO, serialiser, deserialiser, RX
FIFO. Modelling the bit timing here would assert the DUT's divisor arithmetic
against a second copy of the same arithmetic, which proves nothing and breaks
whenever the divisor changes.

It follows the register writes to know what the data reads mean: at offset 0x0 a
write is THR and a read is RBR, but only while LCR[7] is clear -- with DLAB set
the same address is the divisor latch and has nothing to do with the FIFOs.
"""

from collections import deque

from pyuvm import uvm_env, uvm_subscriber

from apb_agent import DLAB, FCR, LCR, RBR, THR, ApbAgent


class LoopbackScoreboard(uvm_subscriber):
    """Every byte sent must come back, in order, and nothing may be left over."""

    def build_phase(self):
        self.expected = deque()
        self.matched = 0
        self.failures = []
        self.dlab = False

    def write(self, txn):
        if txn.write and txn.addr == LCR:
            self.dlab = bool(txn.data & DLAB)
            return

        # FIFO clears are the one thing that legitimately loses data in flight.
        if txn.write and txn.addr == FCR and txn.data & 0b110:
            self.expected.clear()
            return

        if self.dlab:
            return          # divisor latches, not data

        if txn.write and txn.addr == THR:
            self.expected.append(txn.data & 0xFF)
        elif not txn.write and txn.addr == RBR:
            got = txn.rdata & 0xFF
            if not self.expected:
                self.failures.append(f"read 0x{got:02x} from RBR with nothing sent")
            else:
                want = self.expected.popleft()
                if got != want:
                    self.failures.append(f"sent 0x{want:02x}, RBR returned 0x{got:02x}")
                else:
                    self.matched += 1

    def check_phase(self):
        if self.expected:
            left = ", ".join(f"0x{b:02x}" for b in self.expected)
            self.failures.append(f"never came back out of RBR: {left}")
        if self.failures:
            raise AssertionError("; ".join(self.failures))
        # A scoreboard that checked nothing is a scoreboard that passes anything.
        if self.matched == 0:
            raise AssertionError("the scoreboard saw no bytes at all")
        self.logger.info(f"{self.matched} bytes made the round trip")


class UartEnv(uvm_env):
    def build_phase(self):
        self.agent = ApbAgent("agent", self)
        self.scoreboard = LoopbackScoreboard("scoreboard", self)

    def connect_phase(self):
        self.agent.ap.connect(self.scoreboard.analysis_export)
