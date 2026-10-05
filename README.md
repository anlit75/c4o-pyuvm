# c4o-pyuvm

![CI](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

*[繁體中文](README.zh-TW.md)*

**A pyuvm testbench for a UART somebody else wrote, taken all the way to a GDS.**

An APB agent, a scoreboard, and a register model generated from a SystemRDL file —
run against the RTL and again against the gates it synthesises into. One `make`
command each, nothing to install.

This is not a template to put your own design in.
[ChipForAll](https://github.com/anlit75/ChipForAll) is that, and this repository
was made from it.

**Who it is for.** Somebody who verifies hardware, or is learning to. It assumes
you already read Verilog, know what synthesis and a netlist are, and have met a
bus protocol before — the guide discusses APB phases and a 16550's register map
without explaining either. It also assumes the vocabulary — agent, driver,
monitor, sequencer, scoreboard, `ConfigDB`, register model — and explains why
*this* environment is built the way it is rather than what the layers are for.
Those are two separate gaps. If the Verilog and the flow are what is new, start
with [ChipForAll](https://github.com/anlit75/ChipForAll): it teaches those on a
design small enough to hold in your head, and this repository will still be here
afterwards. If the vocabulary is what is new, ChipForAll will not close it — its
tests are flat, with no layers to look at — and pyuvm's own documentation is
where to start.

**pyuvm is not SystemVerilog UVM**, and if you are building a portfolio the
difference is worth stating plainly. [pyuvm](https://github.com/pyuvm/pyuvm)
implements UVM 1.2's class library in Python, so the structure here is the real
thing: the same layers, the same phases, the same objection mechanism, the same
register layer. What does not carry over is the language — SystemVerilog's
macros, the factory, virtual interfaces, `fork`/`join`. So "built a pyuvm
verification environment" is a claim this repository supports; "SystemVerilog UVM
experience" is not, and an interviewer who asks a second question will find out
which you meant.

## What is unusual about it

**The gate-level run uses the same tests.** Not a second testbench written for the
netlist — the same Python, the same scoreboard, the same register model:

```bash
make gds          # produces the netlist
make gatesim      # runs the same tests against it
```

That works only because nothing in `tb/` touches anything but the top-level
ports. Every internal name is gone from a netlist, so a monitor that reached
inside would pass on the RTL and fail here.

**The register map is one file.** `regs/apb_uart.rdl`. `make ral` generates the
pyuvm model from it, and CI regenerates and diffs, so the map and the model cannot
drift apart.

**CI fails on timing.** LibreLane reports timing violations as a warning, so a
design can finish the flow and still miss its clock. A step here turns that into a
failed build, after printing the paths that missed.

**The DUT's bugs stay in.** Verifying a design you may not edit is a different
exercise from verifying one you wrote, and it is the one a DV engineer is paid
for.

## Quick start

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make all          # lint, Verilog sim, the pyuvm tests, synthesis — seconds
make gds          # the physical flow: minutes, plus ~3GB of PDK the first time
make report       # area, timing, power, signoff
make gatesim      # the same tests, on the gates
```

Needs Docker, Make and Git — or none of them: open it in a GitHub Codespace.

## The design under test

[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv), a
16550-style UART, vendored unmodified under `rtl/vendor/` at commit
`dfad6e04d19cc9481d3cd2750b45b970dc61271b` (Solderpad 0.51). APB register decode,
16-byte TX and RX FIFOs, a serialiser and deserialiser sharing a divisor, parity,
FIFO trigger levels, an interrupt.

Its upstream is archived. Three findings are documented rather than patched:

| finding | written down in |
|---|---|
| an inferred latch on `fifo_tx_data` | `config.yaml`, at the lint waiver |
| `cfg_stop_bits_i` is commented out on the TX instance while RX honours `LCR[2]` | `regs/apb_uart.rdl`, on the `STB` field |
| eight dead self-looping bits in the register file, which stop the physical flow | `config.yaml`, at `ERROR_ON_SYNTH_CHECKS` |

`rtl/apb_uart_sv.v` is Verilog-2005 translated from that SystemVerilog by `sv2v`,
because neither yosys nor Icarus reads the original. `make rtl` regenerates it.

## Commands

| Command | What it does | Output |
|---|---|---|
| `make all` | `lint`, `sim`, `cocotb`, `synth` — everything that runs in seconds | terminal |
| `make lint` | Verilator lint | terminal |
| `make sim` | the Verilog smoke test | `build/tb_apb_uart.vcd` |
| `make cocotb` | the pyuvm tests against the RTL | `build/cocotb-results.xml` |
| `make regress` | the tests of `tb/regression.yaml`, each over its seeds | `build/regress/` |
| `make coverage` | the RTL that the pyuvm tests run, counted on Verilator | `build/coverage/` |
| `make gatesim` | the same tests against the netlist (after `make gds`) | `build/cocotb-gl-results.xml` |
| `make rtl` | regenerate `rtl/apb_uart_sv.v` from `rtl/vendor/` | `rtl/apb_uart_sv.v` |
| `make ral` | regenerate `tb/uart_ral.py` from `regs/apb_uart.rdl` | `tb/uart_ral.py` |
| `make synth` | Yosys synthesis | `build/synthesis.json` |
| `make schematic` | the circuit as an SVG | `build/schematic.svg` |
| `make gds` | the physical layout, via LibreLane | `build/apb_uart_sv.gds` |
| `make report` | area, timing, power and signoff from the last `make gds` | terminal |
| `make site` | the layout, test verdicts, timing with its constraints, area and instances, power, signoff checks and both cocotb runs on one page | `build/site/index.html` |
| `make shell` | a shell inside the c4o-core container | — |
| `make clean` | remove `build/`, keep `runs/` | — |
| `make distclean` | remove `build/` and `runs/` | — |

`make cocotb SEED=<n>` replays a random failure. The payloads are logged, so a red
CI run gives you both the seed and the bytes.

`make regress` runs the list in `tb/regression.yaml`: one compile, then one simulation for each test and seed. A failed run prints its replay command, for example `make cocotb SEED=<n> TEST=test_uart.random_bytes`. `make coverage` merges its counters over the same runs. [More on `make regress`](https://github.com/anlit75/c4o-core/blob/main/docs/commands.md#many-seeds-regress).

`make coverage` counts block, branch and toggle points. The numbers belong to `rtl/apb_uart_sv.v`, the file that `sv2v` generates, and not to `rtl/vendor/`. Pass and fail stay with `make cocotb`. The [guide](docs/guide.md#code-coverage) has more.

`make cocotb WAVES=1` also writes `build/apb_uart_sv.vcd`. `make sim` writes its own `build/tb_apb_uart.vcd`.

CI builds the `make site` page on every run and publishes it from `main` to
GitHub Pages (a manual run of the workflow on `main` publishes it again), once **Settings → Pages → Source** is set to **GitHub Actions**.
While it is not, CI still passes and says in a notice that nothing was published.

## Layout

```text
config.yaml           design name, clock, constraints — each with its reason
regs/apb_uart.rdl     the register map, and what SystemRDL cannot express
rtl/apb_uart_sv.v     generated by make rtl — do not edit
rtl/vendor/           somebody else's SystemVerilog, unmodified
tb/apb_agent.py       APB3 driver, monitor, agent, register adapter
tb/uart_env.py        environment, scoreboard, test base class
tb/uart_ral.py        generated by make ral — do not edit
tb/test_uart.py       the data path, over the DUT's own loopback
tb/test_ral.py        the registers, through the model
tb/tb_apb_uart.v      the Verilog smoke test
docs/guide.md         how it works
```

Two files are generated and committed, so a fresh clone can run everything without
running the generators first.

## Read next

The [guide](docs/guide.md) covers how the testbench is built and why:

*   [The environment](docs/guide.md#the-environment) — what the scoreboard checks, and what it deliberately does not model
*   [What each test covers](docs/guide.md#what-each-test-covers) — and how to check a test can still fail
*   [The register model](docs/guide.md#the-register-model) — what SystemRDL cannot say about a 16550, and the pyuvm settings it needs
*   [Running on the gates](docs/guide.md#running-on-the-gates) — the one rule that makes it possible
*   [Constraints](docs/guide.md#constraints) — why the clock is 90.9 MHz
*   [Configuration reference](docs/guide.md#configuration-reference)

---

Powered by [c4o-core](https://github.com/anlit75/c4o-core), from the
[ChipForAll](https://github.com/anlit75/ChipForAll) template.
