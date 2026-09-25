"""
cocotb tests for blinky: Python coroutines driving the RTL, same simulator
underneath as `make sim`.

This is not a translation of test/tb_blinky.v. That testbench shrinks the
design to WIDTH=4 so a full divider period fits in a short run. `make cocotb`
elaborates blinky itself as the root module, so WIDTH stays at its default 26
and one period is 2**26 cycles -- far too slow to sit and wait for.

What Python can do instead is reach into the design and put the counter where
the interesting behaviour is. The last test does exactly that, in four cycles,
and it is the reason to keep this file alongside the Verilog one.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

WIDTH = 26  # blinky's default; led is count[WIDTH-1]


async def tick(dut):
    """
    One clock, then a moment for the design to settle.

    RisingEdge resumes *at* the edge, before the non-blocking assignment to
    count has taken effect and before led's continuous assignment has followed
    it. Reading either one here gives you the previous cycle's value. Relative
    checks still pass that way, which is exactly what makes it easy to miss --
    so every read in this file happens after the Timer.
    """
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


async def start(dut):
    """Clock running, reset applied and released."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    await tick(dut)
    await tick(dut)
    dut.rst.value = 0


@cocotb.test()
async def reset_holds_the_counter_low(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    await tick(dut)
    await tick(dut)
    assert int(dut.count.value) == 0, f"count was {int(dut.count.value)} while rst asserted"
    assert dut.led.value == 0, f"led was {dut.led.value} while rst asserted"


@cocotb.test()
async def counts_up_by_one(dut):
    await start(dut)
    await tick(dut)
    previous = int(dut.count.value)
    for _ in range(5):
        await tick(dut)
        expected = previous + 1
        assert int(dut.count.value) == expected, (
            f"count went {previous} -> {int(dut.count.value)}, expected {expected}"
        )
        previous = expected


@cocotb.test()
async def led_is_the_counter_top_bit(dut):
    """
    Put the counter one tick below each transition and watch led follow.

    A Verilog testbench reaches this property only by overriding WIDTH -- which
    test/gate/tb_blinky_gl.v cannot do, because synthesis resolved it -- or by
    running 2**25 cycles, which is what that gate-level run spends four minutes
    on. From Python the counter is just a signal to write.
    """
    await start(dut)

    dut.count.value = (1 << (WIDTH - 1)) - 1      # top bit still 0; next tick sets it
    await tick(dut)
    assert dut.led.value == 1, (
        f"led should rise when count reaches {1 << (WIDTH - 1)}, "
        f"got led={dut.led.value} at count={int(dut.count.value)}"
    )

    dut.count.value = (1 << WIDTH) - 1            # all ones; next tick wraps to 0
    await tick(dut)
    assert dut.led.value == 0, (
        f"led should fall when count wraps, "
        f"got led={dut.led.value} at count={int(dut.count.value)}"
    )
