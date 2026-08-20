"""cocotb testbench for the registered adder (ABACUS-13).

Written against cocotb 2.0. Notable differences from the 1.x tutorials
floating around online:

  * Timer/Clock take ``unit=`` (singular), not ``units=``.
  * ``dut._log`` is private now -- use ``cocotb.log``.
  * ``cocotb.fork`` is gone -- use ``cocotb.start_soon``.
  * Failures are plain ``assert``; TestFailure/TestSuccess were removed.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

WIDTH = 8
CLK_PERIOD_NS = 10


async def start_clock(dut):
    """Kick off the free-running clock in the background."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def reset_dut(dut, cycles=2):
    """Hold reset low for a few cycles, then release on a clean edge."""
    dut.rst_n.value = 0
    dut.a.value = 0
    dut.b.value = 0
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def check_add(dut, a, b):
    """Drive one operand pair and check the result the DUT registers.

    Timing is the part that trips people up, so spelling it out:

      1. Writing ``.value`` schedules the write for the ReadWrite phase of
         the *current* timestep -- i.e. it lands before the next edge.
      2. ``RisingEdge`` resumes us in the Active region, *before* nonblocking
         assignments have settled. Reading ``sum`` here gets the stale value.
      3. ``ReadOnly`` waits for the end of the timestep, when the flop output
         is final. You cannot drive signals from ReadOnly, hence the trailing
         ``RisingEdge`` to get back to a drivable phase.
    """
    dut.a.value = a
    dut.b.value = b

    await RisingEdge(dut.clk)  # this edge captures a and b
    await ReadOnly()           # let the NBA settle before sampling

    got = int(dut.sum.value)
    assert got == a + b, f"{a} + {b}: expected {a + b}, got {got}"

    await RisingEdge(dut.clk)  # leave ReadOnly so the caller can drive again


@cocotb.test()
async def test_reset_and_directed(dut):
    """Reset clears the output, then a few hand-picked cases."""
    await start_clock(dut)
    await reset_dut(dut)

    await ReadOnly()
    assert int(dut.sum.value) == 0, "sum should be zero coming out of reset"
    await RisingEdge(dut.clk)

    max_val = (1 << WIDTH) - 1
    for a, b in [(0, 0), (1, 1), (max_val, 0), (max_val, max_val), (170, 85)]:
        await check_add(dut, a, b)

    cocotb.log.info("directed cases passed, including full-width carry out")


@cocotb.test()
async def test_random(dut):
    """100 random operand pairs against a Python golden model."""
    await start_clock(dut)
    await reset_dut(dut)

    for _ in range(100):
        a = random.randrange(1 << WIDTH)
        b = random.randrange(1 << WIDTH)
        await check_add(dut, a, b)