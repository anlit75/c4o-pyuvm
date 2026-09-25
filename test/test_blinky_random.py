"""
A self-checking random test: reference model, monitor, scoreboard.

test_blinky_cocotb.py drives the design and asserts on three moments
somebody chose by hand. This file does the other half of verification: a
model that says what the design *should* do, a loop that samples what it
did, and a comparison on every cycle -- under stimulus nobody wrote out.

Repeating a failure. cocotb seeds Python's random module itself and logs
the seed it used ("Seeding Python random module with 1789965785"), so a
run that failed can be run again exactly:

    make cocotb SEED=1789965785

What this does not check: reset *timing*. The stimulus moves rst only
just after a clock edge, so an asynchronous reset and a synchronous one
behave identically here. Recovery and removal are a timing question, and
`make gds` already answers it -- that is what the hold slack row is.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

WIDTH = 26                  # blinky's default; led is count[WIDTH-1]
LIMIT = 1 << WIDTH
TOP = 1 << (WIDTH - 1)      # the count at which led rises

WINDOWS = 5                 # random starting points per run
CYCLES = 40                 # clocks checked from each one
NEAR = 5                    # how close to an edge "near" means
QUIET = NEAR + 2            # cycles before a random reset may interrupt


class BlinkyModel:
    """
    What blinky should do, in Python: count, wrap, clear on reset.

    Deliberately not a transcription of the RTL. The same behaviour
    written a second way is the only thing a scoreboard can usefully
    disagree with the design about.
    """

    def __init__(self, count):
        self.count = count

    def tick(self, rst):
        self.count = 0 if rst else (self.count + 1) % LIMIT

    @property
    def led(self):
        return (self.count >> (WIDTH - 1)) & 1


def start_in(region):
    """A starting count: just below the led edge, just below the wrap, or anywhere."""
    if region == "rise":
        return TOP - random.randint(1, NEAR)
    if region == "wrap":
        return LIMIT - random.randint(1, NEAR)
    return random.randrange(LIMIT)


async def load(dut, count):
    """Reset, then put the counter where the test wants it."""
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.count.value = count
    dut.rst.value = 0
    await Timer(1, units="ns")


async def run_window(dut, start, quiet):
    """
    CYCLES clocks from `start`, led compared against the model every one.

    Random resets begin after `quiet` cycles. That delay is what keeps the
    two windows placed at an led edge from being neutered by a reset that
    lands before the edge does -- a run where led never moves would pass
    while proving nothing.
    """
    await load(dut, start)
    model = BlinkyModel(start)
    previous = model.led
    transitions = resets = held = 0

    for cycle in range(CYCLES):
        # Stimulus for the edge about to happen, driven a moment before it.
        if cycle >= quiet and held == 0 and random.random() < 0.05:
            held = random.randint(1, 3)
            resets += 1
        rst = 1 if held else 0
        held = max(held - 1, 0)
        dut.rst.value = rst
        await Timer(1, units="ns")

        await RisingEdge(dut.clk)
        await Timer(1, units="ns")

        model.tick(rst)
        if int(dut.led.value) != model.led:
            raise AssertionError(
                f"led is {int(dut.led.value)}, model says {model.led}: "
                f"cycle {cycle} of a window from count {start}, rst {rst}, "
                f"model count {model.count}"
            )

        if model.led != previous:
            transitions += 1
            previous = model.led

    return transitions, resets


@cocotb.test()
async def random_stimulus_matches_the_model(dut):
    """Random resets from random starting counts; led checked every cycle."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    # Two windows are placed where led changes, so a run cannot come back
    # green having watched a signal that never moved. The rest are free.
    plan = [("rise", QUIET), ("wrap", QUIET)]
    plan += [(random.choice(("rise", "wrap", "any")), 0) for _ in range(WINDOWS - 2)]
    random.shuffle(plan)

    transitions = resets = 0
    for region, quiet in plan:
        moved, reset_count = await run_window(dut, start_in(region), quiet)
        transitions += moved
        resets += reset_count

    assert transitions >= 2, (
        f"led moved {transitions} times in {WINDOWS * CYCLES} cycles. The "
        "stimulus never reached an edge, so this run checked nothing."
    )

    dut._log.info(
        f"{WINDOWS * CYCLES} cycles checked, {resets} resets, "
        f"{transitions} led transitions"
    )
