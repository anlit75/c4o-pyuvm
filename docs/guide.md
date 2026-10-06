# Guide

*[繁體中文](guide.zh-TW.md)*

How the testbench is built, and the decisions that are not obvious from the code.
The [README](../README.md) covers what the repository is and how to run it.

## The environment

```
tb/apb_agent.py   ApbTxn, driver, monitor, agent, register adapter
tb/uart_env.py    environment, scoreboard, test base class
tb/test_uart.py   the data-path tests
tb/test_ral.py    the register tests
```

**The driver is not a state machine.** APB3 has two phases, and this DUT ties
`PREADY` high unconditionally, so there is no backpressure to model: drive the
address with `PSEL`, raise `PENABLE`, read `PRDATA` at the edge that ends the
access phase, drop `PSEL`. Three cycles, every time. The monitor watches for the
cycle where `PSEL`, `PENABLE` and `PREADY` are all set and broadcasts what it saw.

**The scoreboard checks the loopback, not the bit timing.** `tx_o` is tied back to
`rx_i`, so every byte written to THR must reappear, in order, from RBR. That one
relation covers the APB decode, both FIFOs, the serialiser and the deserialiser.

Modelling the serial timing instead would mean asserting the DUT's divisor
arithmetic against a second copy of the same arithmetic. That proves nothing and
breaks whenever the divisor changes.

The scoreboard does track `LCR[7]`. At offset `0x0` a write is THR and a read is
RBR *only while that bit is clear*. With DLAB set, the same address is the divisor
latch and has nothing to do with the FIFOs.

**The loopback is a coroutine.** cocotb elaborates the DUT as the root, so there is
no testbench module to tie two ports together in:

```python
async def tie_tx_to_rx():
    dut.rx_i.value = dut.tx_o.value
    while True:
        await Edge(dut.tx_o)
        dut.rx_i.value = dut.tx_o.value
```

It triggers on `tx_o` changing, not on the clock. A clocked mirror reads the
pre-edge value and so adds a cycle of latency to the serial line. The RTL
tolerates that. A netlist with unit delays may not tolerate it, since one bit is only five cycles
wide. A wire has no latency.

## What each test covers

Six tests, each covering something the others cannot.

| test | what only it can catch |
|---|---|
| `loopback` | a single byte failing to make the round trip at all |
| `random_bytes` | anything that needs more than one byte. A read that does not advance the RX FIFO reads the same correct byte forever |
| `burst` | anything that needs more than one byte *in flight*. Sending one at a time never puts two in the FIFO, so it cannot tell a queue from a register |
| `reset_values` | a register coming out of reset wrong |
| `register_readback` | a write that lands at the wrong address. It is invisible to every data-path test, because the UART still sends correctly |
| `idle_status` | one status bit wrong where the whole byte still looks right |

`register_readback` is why the register model exists. The rest would all pass a
design that wrote IER's value into MCR.

**That table is this suite's coverage argument, and it is the only one.** There is
no functional or code coverage here: the generated register model is built with
`UVM_NO_COVERAGE`, and nothing collects coverpoints. Six tests on a design this
size can be argued about one at a time. The table does that. What
an interviewer means by coverage-driven verification is the machinery that takes
over when a table stops being possible. Worth knowing which one you have.

### Checking a test can still fail

A test that has never failed is a test nobody has checked. Break the design. Run
the tests. Check that the one you aimed at fails and says something useful:

```bash
# e.g. make the THR write drop its low bit, in rtl/apb_uart_sv.v
make cocotb                       # loopback: "sent 0xa5, RBR returned 0xa4"
git checkout -- rtl/apb_uart_sv.v
```

Worth knowing about two of them:

*   **`reset_values` is weaker than its name for LSR.** `THRE` and `TEMT` are
    driven combinationally, so the reset value is overwritten on the first clock
    edge and is not observable from the bus. Changing it in the RTL does not fail
    any test. What that check really asserts is that an idle transmitter reports
    itself empty. That is why `idle_status` pins those bits field by field.
*   **One check is aimed at the testbench.** The test base class asserts the
    scoreboard matched exactly as many bytes as were sent. So silencing the monitor
    fails loudly instead of letting every comparison pass on an empty queue.

## The register model

`regs/apb_uart.rdl` is the register map. `make ral` runs `peakrdl pyuvm` over it,
and CI regenerates and diffs the result.

The map describes IER, IIR, LCR and LSR. Four things about this DUT cannot be
expressed in SystemRDL, which is why the rest is driven through the agent directly:

1.  **THR/RBR at `0x0` is not a register.** A write pushes into the TX FIFO and a
    read pops the RX FIFO. There is no storage to mirror. UVM has `uvm_reg_fifo`
    for this, and PeakRDL does not generate it.
2.  **FCR at `0x2` is write-only and shares its address with the read-only IIR.**
    `alias` is SystemRDL's mechanism for two views of one address, but it is a view
    of the *same storage*, and these are unrelated hardware.
3.  **DLL and DLM replace THR and IER while `LCR[7]` is set.** A register's address
    cannot depend on another register's contents.
4.  **MCR, MSR and SCR are absent.** The RTL resets storage for them and then never
    decodes them, so they read back as zero. Describing them would make the model
    predict values the design cannot return.

Expected reset values come from `reg.get_reset()`, so the `.rdl` stays the only
place the map is written down.

### pyuvm settings the generated model needs

PeakRDL does not emit these, and `uart_env.py` sets them. If you hit one of these
errors, this is why:

| error | fix |
|---|---|
| `unsupported operand type(s) for +: 'NoneType' and 'int'` on any access | the map is created with `UVM_NO_ENDIAN`, which pyuvm reads as *no endianness specified*. Reconfigure it with one |
| the same error, after `Map ... does not seem to initialized correctly` | call `lock_model()` after `build()` |
| `value read from DUT (0x5F) does not match mirrored value (0x0)` | `set_auto_predict(True)`. Otherwise the mirror never leaves its reset value |
| `mirror(UVM_CHECK)` logs a mismatch and the test still passes | `set_sv_uvm_style_reporting_enabled(True)`, or the register layer's errors go to a logger the report server never counts |

Auto-prediction rather than a `uvm_reg_predictor` on the monitor is deliberate. A
predictor is the better setup in general. But the monitor here also sees the FCR
traffic the map cannot describe. It would feed an FCR write at `0x2` into IIR's
mirror.

## Running on the gates

```bash
make gds          # writes runs/<tag>/final/nl/
make gatesim      # drives it with the same tests
```

**One rule makes it work: nothing in `tb/` may touch anything but the top-level
ports.** Every internal name is gone from a netlist. Reach inside and this is where
you find out, with an `AttributeError` naming the net synthesis removed. CI runs it
on every pull request for that reason, and it costs a few seconds.

**The design carries a `` `timescale ``, and it has to.** A gate-level run compiles
the PDK cell models alongside the netlist and those carry `1ns/1ps`. RTL on its own
carries none, so Icarus runs it at a precision of one second. cocotb's `step` unit
is that precision, which means the same clock period means different things in the
two runs. `make rtl` writes `` `timescale 1ns / 1ps `` into the generated Verilog so
they agree, and the tests ask for nanoseconds.

For the same reason, do not reach for `COCOTB_RESOLVE_X` when a gate-level read
returns X. The registers these tests read are ones the test wrote or reset defines,
so an X is a real failure. `int()` raising on it is the behaviour to keep.

The shared report step in CI compares the two runs' summary lines rather than a count
written into the workflow: the same tests, the same verdicts, on both.

## Many seeds

```bash
make regress                                        # every test of tb/regression.yaml, each over its seeds
make cocotb SEED=<n> TEST=test_uart.random_bytes    # replay one failed run
```

`tb/regression.yaml` lists the tests. An entry is a module, or `<module>.<function>` for one test, and `seeds` says how many seeds it runs. `random_bytes` runs 10 seeds. The other entries run one.

`make regress` compiles once and runs one simulation for each entry and seed. A failed run does not stop the others. For each failed run it prints the `make cocotb SEED=<n> TEST=<entry>` command that replays it. The replay is exact, because each entry runs one module and `test_uart.py` builds its payloads from the seed when it is imported. `make regress SEED=<n>` reruns the whole list from one base seed. [All the details](https://github.com/anlit75/c4o-core/blob/main/docs/commands.md#many-seeds-regress).

## Code coverage

```bash
make coverage     # the same tests again, on Verilator, with counters
```

`make coverage` counts three kinds of points: blocks that ran, branches taken (each side of an `if` or a `case`) and signal bits that toggled. The results page shows each kind with the points hit and the total, and CI measures it on every run. `make all` does not. With `"//REGRESSION"` set, `make coverage` merges its counters over every run of the list.

**The numbers are for `rtl/apb_uart_sv.v`**, the file `sv2v` generates, and not for the SystemVerilog under `rtl/vendor/`. A block here is a block of the translation.

**Pass and fail stay with `make cocotb`.** That run is on Icarus. Verilator is 2-state, so a signal that is X before reset reads 0 there. So a test can pass on one and fail on the other. A failing Verilator run does not fail `make coverage`. A design that Verilator cannot build does. `make coverage SEED=<n>` sets the seed, and the page says which one the run used. [All the details](https://github.com/anlit75/c4o-core/blob/main/docs/commands.md#code-coverage-coverage).

## Constraints

Each value in `config.yaml` has its reason next to it. Two are worth explaining
here.

**`IO_DELAY_CONSTRAINT: 5`, against a default of 20.** The default reserves a fifth
of every clock period as external delay on the ports. That is right for a design whose
pins drive a package and a board. That is wrong for a block whose `PRDATA` goes to an APB
master on the same die. `IO_DELAY_CONSTRAINT` is a percentage, so it also makes the clock period a
poor lever: required time is

```
period − clock uncertainty − IO_DELAY_CONSTRAINT × period
```

At 20% each added nanosecond returns only 0.8 ns. At 5% it returns 0.95 ns.

**`CLOCK_PERIOD: 11.0` is 90.9 MHz, not 100.** At 100 MHz the setup paths still fit,
but hold fails in the `max_ss` corner and the flow stops. `config.yaml` has the
measured slack for both periods.

`ERROR_ON_SYNTH_CHECKS` is off, because the DUT's register file has eight dead
self-looping bits that the pre-synthesis check reports as logic loops. They are
gone after optimisation and never reach the netlist. A CI step asserts the reports
directly instead, so a *new* loop still fails the build.

## Iterating without re-running the whole flow

Floorplan parameters (`FP_CORE_UTIL`, the die, the placement) do not need
synthesis redone. Resume the last run from floorplan with LibreLane's own flags:

```bash
make gds LIBRELANE_ARGS="--from OpenROAD.Floorplan --with-initial-state runs/apb_uart_sv_run/13-openroad-floorplan/state_in.json"
```

`--with-initial-state` names the state that step was given last time: the
`state_in.json` in its directory. Without it LibreLane starts from the finished
design, and the flow fails. The command reads the previous run out of `runs/`,
which is why `make clean` leaves that directory alone and `make distclean` is the
one that removes it.

The resumed steps are added after the old ones, so the run directory holds two of
each until the next full run. `make gds` without `--from` is a full run, and it
starts from an empty run directory.

**`CLOCK_PERIOD` is not one of them**, which matters here because it is the key
this design's timing turns on. The clock is an input to synthesis, which sizes
cells and inserts buffers against it. So resuming from floorplan measures the
gates the *old* period produced under the new one. The 90.9 MHz in
[Constraints](#constraints) came from full runs for that reason.

## Seeing the circuit

```bash
make schematic
```

Draws `build/schematic.svg`. It shows the design as flops, adders and muxes, carrying the
names the RTL gave them. Open it in a browser or click it in VS Code.

It is not a picture of the netlist. `make synth` runs a full synthesis and leaves
hundreds of technology cells, from which nobody has ever learned anything about
their own design. `make schematic` stops earlier, where the circuit still looks like
the code it came from. Under a second, so it costs nothing to run after a change.

## Working inside the container

The repo ships a [Dev Container](https://containers.dev/). Open it in GitHub
Codespaces, or in VS Code with *Reopen in Container*, and you get the image CI uses
with the Verilog extensions installed. The `Makefile` notices it is already inside
and calls the tools directly instead of nesting another container.

`make gds` works in here too. The container ships a Docker daemon of its own for
the LibreLane sidecar. If it says it cannot find one, rebuild the Dev Container.

Two things to know:

*   **It runs as `root`.** On a Linux host, files it writes into `build/` end up
    owned by `root`, so `make clean` from the host may need `sudo`. Running as a
    normal user instead breaks Codespaces.
*   **Watch the disk in a Codespace.** The inner daemon has its own image store, so
    the LibreLane image is pulled again rather than shared, and the PDK is another
    several GB. Run `du -sh pdks/` to see its size. On the smallest machine type
    that is most of the disk.

`make shell` drops you into the same image from any terminal.

## Configuration reference

`config.yaml` is a [LibreLane](https://github.com/librelane/librelane) configuration
file. Keys LibreLane does not own carry a `//` prefix, which it ignores. That is
what keeps one file valid for both tools.

| Key | What it does |
|---|---|
| `DESIGN_NAME` | the top module's name. Everything else reads it from here |
| `VERILOG_FILES` | synthesisable sources. Each entry is checked as a literal path. `**` is not expanded |
| `"//TEST_FILES"` | Verilog testbenches for `make sim`. Globs work |
| `"//COCOTB_TESTS"` | Python testbenches for `make cocotb` and `make gatesim`. Only files defining `@cocotb.test()`. They import the rest of `tb/` |
| `"//REGRESSION"` | the YAML test list for `make regress`: `test`, and `seeds` for each |
| `"//DESCRIPTION"` | one line under the results page's title and in its link preview: what the design is |
| `CLOCK_PORT` / `CLOCK_PERIOD` | the clock to constrain, and its period in ns |
| `IO_DELAY_CONSTRAINT` | percentage of the period reserved as external delay on the ports |
| `LINTER_DISABLE_WARNINGS` | Verilator warnings waived for the design |
| `LINTER_DISABLE_WARNINGS_BLACKBOX` | the same for the PDK's blackbox stubs |
| `ERROR_ON_SYNTH_CHECKS` | whether pre-synthesis check errors stop the flow |
| `FP_SIZING` / `FP_CORE_UTIL` | how the die is sized |
| `PDK` / `STD_CELL_LIBRARY` | Sky130 and its standard cells. Leave alone |

**The die sizes itself.** `FP_SIZING: relative` floorplans from `FP_CORE_UTIL` (how
full the core should be), so a bigger design gets a bigger die instead of "does not
fit". Lower it if routing is tight. Raise it for a smaller chip.

A fixed die is still available: `FP_SIZING: absolute` with
`DIE_AREA: [0, 0, w, h]`. Do not leave `DIE_AREA` in the file under relative sizing.
The flow ignores it, but GDS stream-out still draws the chip boundary from it.
Signoff then fails on a boundary nothing else used.

Everything else belongs to LibreLane. See
[its documentation](https://librelane.readthedocs.io/) for the full list. See the
[c4o-core README](https://github.com/anlit75/c4o-core) for what this engine reads.
