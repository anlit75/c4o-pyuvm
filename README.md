# c4o-pyuvm

![CI Status](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

*[繁體中文](README.zh-TW.md)*

**A worked pyuvm example on somebody else's UART, taken all the way to a GDS.** A
pyuvm environment with an APB agent, a scoreboard and a generated register model,
run twice — once against the RTL and once against the 2710 gates it synthesises
into — plus every test proved against the bug it is there to catch.

Not a template to put your own design in. [ChipForAll](https://github.com/anlit75/ChipForAll)
is that, and this repository was made from it. This one is the example: a specific
design, verified, with the reasoning left in.

## What is different about it

**The same tests run against the gates.** Not a second testbench written for the
netlist — the same Python, the same scoreboard, the same register model:

```
                        RTL              gates
reset_values          190.00 ns        190.00 ns
register_readback     200.00 ns        200.00 ns
idle_status           110.00 ns        110.00 ns
loopback              800.00 ns        800.00 ns
random_bytes        11630.00 ns      11630.00 ns
burst                8600.00 ns       8600.00 ns
                    ---------        ---------
TESTS=6 PASS=6      21530.01 ns      21530.01 ns
                       0.53 s           1.34 s of wall time
```

Identical simulated time on both. That only works because nothing in `test/`
reaches inside the design: every internal name is gone from a netlist, so a
monitor that peeked at `dut.regs_q` would pass on the RTL and die on the gates.
`make cocotb-gl` is where you find out.

**Every test was run against the bug it defends.** Not "the tests pass" — each one
was checked by breaking the design and watching that test, and only that test,
fail. The tables are in [the guide](docs/guide.md#proving-a-test-can-fail), and
one of them is the reason the register model exists at all: an IER write
redirected to the wrong address is invisible to all six data-path checks and
caught by the mirror.

**The DUT is somebody else's, and its bugs stay in.**
[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv),
vendored unmodified at `dfad6e04d19cc9481d3cd2750b45b970dc61271b` under Solderpad
0.51. Verifying a design you may not edit is a different exercise from verifying
one you wrote, and it is the one a DV engineer is paid for. Three findings are
documented rather than patched:

| finding | where it is written down |
|---|---|
| an inferred latch on `fifo_tx_data` — 8 `dlxtn` cells in the layout | `config.yaml`, next to the lint waiver |
| `cfg_stop_bits_i` commented out on the TX instance while RX honours `LCR[2]` | `regs/apb_uart.rdl`, on the `STB` field |
| 8 dead self-looping bits in the register file, which stopped the physical flow | `config.yaml`, next to `ERROR_ON_SYNTH_CHECKS` |

**The register map is one file.** `regs/apb_uart.rdl` in SystemRDL; `make ral`
turns it into the pyuvm model, and CI regenerates and diffs so the two cannot
drift. Its header is mostly about the four things SystemRDL *cannot* say about a
1980s peripheral — which is the part worth reading.

## Quick start

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make all          # lint, Verilog sim, six pyuvm tests, synthesis -- seconds
make gds          # the physical flow: ~5 minutes, and ~3GB of PDK the first time
make report       # what it measured
make cocotb-gl    # the same six tests, on the gates make gds just produced
```

Docker (Desktop or Engine), Make and Git — or none of them: open it in a GitHub
Codespace and everything is already there.

## What it measures

`make report` after `make gds`:

```
  apb_uart_sv

  die              236.605 x 247.325 um  (58518.3 um^2)
  utilization      54.2%
  standard cells   2710
  setup slack      +0.92 ns  (0 violations)
  hold slack       +0.11 ns  (0 violations)
  power            4.095 mW
  signoff          clean  (Magic DRC, KLayout DRC, LVS, antenna, XOR)
  lint warnings    8
  layout           runs/apb_uart_sv_run/final/render/apb_uart_sv.png
```

90.9 MHz, not 100, and that took three measured rounds to arrive at rather than
one guess. [Why](docs/guide.md#closing-timing-took-three-wrong-answers) is in the
guide: the sky130 default reserves a fifth of every clock period as external
delay on the ports, which is right for a chip with pads and wrong for a block, and
which makes the clock period nearly useless as a lever until you notice.

CI gates it. `setup slack` or `hold slack` reporting anything but `(0 violations)`
turns the build red — because LibreLane reports timing violations as a warning,
and this repository went green twice on a design that missed its own clock before
that step existed.

## Commands

| Command | Description | Output |
|---|---|---|
| `make all` | `lint`, `sim`, `cocotb` and `synth` — everything that runs in seconds. | `Terminal` |
| `make lint` | Checks the generated Verilog with Verilator. | `Terminal` |
| `make sim` | The Verilog smoke test with Icarus Verilog. | `build/tb_apb_uart.vcd` |
| `make cocotb` | The six pyuvm tests against the RTL. | `build/cocotb-results.xml` |
| `make cocotb-gl` | The same six against the netlist. Needs `make gds` first. | `build/cocotb-gl-results.xml` |
| `make rtl` | Regenerates `src/apb_uart_sv.v` from the vendored SystemVerilog. | `src/apb_uart_sv.v` |
| `make ral` | Regenerates `test/uart_ral.py` from `regs/apb_uart.rdl`. | `test/uart_ral.py` |
| `make synth` | Synthesises RTL into gates with Yosys. | `build/synthesis.json` |
| `make schematic` | Draws the circuit as an SVG you can open anywhere. | `build/schematic.svg` |
| `make gds` | Builds the physical layout with LibreLane (~5 min). | `build/apb_uart_sv.gds` |
| `make report` | Area, timing, power and signoff from the last `make gds`. | `Terminal` |
| `make shell` | A bash shell inside the c4o-core container. | — |
| `make gatesim` | The Verilog gate-level testbench. Unused here — `cocotb-gl` covers it. | `Terminal` |
| `make clean` | Removes `build/`. Keeps `runs/`, which `report` and `cocotb-gl` read. | — |
| `make distclean` | Removes `build/` and `runs/`. | — |

`make help` lists them in the terminal. `make cocotb SEED=<n>` replays a random
failure — the payloads are logged, so a red CI run tells you both the seed and the
bytes.

## Project structure

```text
.
├── config.yaml        # ⚙️ Design name, clock, constraints -- with the reasons
├── Makefile           # 🎮 The command center
├── regs/
│   └── apb_uart.rdl   # 📋 The register map, and what SystemRDL cannot say
├── src/
│   ├── apb_uart_sv.v  # 🤖 GENERATED by make rtl -- do not edit
│   └── vendor/        # 📦 Somebody else's SystemVerilog, unmodified
├── test/
│   ├── apb_agent.py   # 🚌 APB3 driver, monitor, agent, register adapter
│   ├── uart_env.py    # 🏗️ Environment, scoreboard, and the test base class
│   ├── uart_ral.py    # 🤖 GENERATED by make ral -- do not edit
│   ├── test_uart.py   # 🧪 The data path, over the DUT's own loopback
│   ├── test_ral.py    # 🧪 The registers, through the model
│   └── tb_apb_uart.v  # 🧪 The Verilog smoke test (make sim)
└── docs/guide.md      # 📚 How it works, and what went wrong on the way
```

Two files in there are generated and committed: `src/apb_uart_sv.v` and
`test/uart_ral.py`. Committing generated code means a fresh clone can run
everything, and it means the pair can drift — so CI regenerates
`test/uart_ral.py` and diffs it.

## Next steps

The [guide](docs/guide.md) is the part with the reasoning in it:

*   [The environment](docs/guide.md#the-environment) — agent, scoreboard, and why the scoreboard never looks at the serial line
*   [Proving a test can fail](docs/guide.md#proving-a-test-can-fail) — the mutation tables, and which test each one needed
*   [The register model](docs/guide.md#the-register-model) — SystemRDL's four limits, and the four things pyuvm needed that PeakRDL does not provide
*   [Running on the gates](docs/guide.md#running-on-the-gates) — what it caught, starting with a bug in the testbench's idea of time
*   [Closing timing took three wrong answers](docs/guide.md#closing-timing-took-three-wrong-answers) — including two that were measured and discarded

---

Powered by the **[c4o-core](https://github.com/anlit75/c4o-core)** engine, from the
**[ChipForAll](https://github.com/anlit75/ChipForAll)** template.
