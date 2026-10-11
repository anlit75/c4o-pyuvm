<div align="center">

# c4o-pyuvm

**A Layered pyuvm Testbench for a UART Somebody Else Wrote, from RTL to GDS.**

The same tests run on the RTL and on the gates. One SystemRDL file generates the register model.

[Live Results](https://anlit75.github.io/c4o-pyuvm/) · [Guide](docs/guide.md) · [ChipForAll](https://github.com/anlit75/ChipForAll) · [繁體中文](README.zh-TW.md)

![CI](https://github.com/anlit75/c4o-pyuvm/actions/workflows/verify.yml/badge.svg)
[![License](https://img.shields.io/github/license/anlit75/c4o-pyuvm)](LICENSE)

</div>

## What Makes It Different

**A layered environment on a UART that is not yours.** An APB agent, a scoreboard and a UVM register model verify a 16550-style APB UART. The DUT is vendored unmodified.

**One register map.** `make ral` generates the register model from `regs/apb_uart.rdl`. CI regenerates it and diffs it, so the map and the model cannot drift apart.

**One set of tests, two targets.** `make sim` runs the tests on the RTL. `make gatesim` runs the same Python, scoreboard and register model on the synthesised netlist. This works because `tb/` touches only top-level ports. A monitor that reached inside would pass on the RTL and fail on the gates, because a netlist has no internal names.

**CI fails on timing.** LibreLane reports timing violations as a warning, so a design can finish the flow and still miss its clock. A CI step prints the paths that missed, then fails the build.

**The DUT's bugs stay in.** Verifying a design you may not edit is a different exercise from verifying one you wrote. It is the one a DV engineer is paid for.

**Seeds and coverage.** `make regress` runs each test over its seeds, then measures coverage of the same runs. The coverage numbers belong to the generated Verilog, not to the vendored SystemVerilog.

## Quick Start

You need Docker, Make and Git. A GitHub Codespace needs none of them.

```bash
git clone https://github.com/anlit75/c4o-pyuvm.git
cd c4o-pyuvm
make sim          # compile, lint, synthesis, Verilog sim, pyuvm tests: seconds
make gds          # physical flow: minutes, plus a multi-GB PDK download on a first run
make gatesim      # the same tests, on the gates
```

The [live results page](https://anlit75.github.io/c4o-pyuvm/) shows the output of these commands.

## Commands for This Repository

| Command | What it does |
|---|---|
| `make sim` | Runs the Verilog smoke test and the pyuvm tests on the RTL |
| `make gatesim` | Runs the same tests on the netlist, after `make gds`. It stops if the RTL changed since |
| `make regress` | Runs the tests of `tb/regression.yaml`, each over its seeds, then measures coverage |
| `make cocotb SEED=<n> TEST=<entry>` | Replays one seed or one test |
| `make ral` | Regenerates `tb/uart_ral.py` from `regs/apb_uart.rdl` |
| `make sv2v` | Regenerates `rtl/apb_uart_sv.v` from `rtl/vendor/` |

A failed `make regress` run prints its replay command, for example `make cocotb SEED=<n> TEST=test_uart.random_bytes`. The payloads are logged, so a red CI run gives you both the seed and the bytes.

`make help` lists every command.

## The Design Under Test

[pulp-platform/apb_uart_sv](https://github.com/pulp-platform/apb_uart_sv) is a 16550-style UART. It is vendored unmodified under `rtl/vendor/` at commit `dfad6e04d19cc9481d3cd2750b45b970dc61271b` (Solderpad 0.51). It has APB register decode, 16-byte TX and RX FIFOs, a serialiser and deserialiser that share a divisor, parity, FIFO trigger levels and an interrupt.

Its upstream is archived. Three findings are documented rather than patched:

| Finding | Written down in |
|---|---|
| an inferred latch on `fifo_tx_data` | `config.yaml`, at the lint waiver |
| `cfg_stop_bits_i` is commented out on the TX instance while RX honours `LCR[2]` | `regs/apb_uart.rdl`, on the `STB` field |
| eight dead self-looping bits in the register file, which stop the physical flow | `config.yaml`, at `ERROR_ON_SYNTH_CHECKS` |

`rtl/apb_uart_sv.v` is Verilog-2005 that `sv2v` translates from that SystemVerilog, because neither yosys nor Icarus reads the original. `make sv2v` regenerates it, and CI checks it for drift. Both generated files are committed, so a fresh clone runs everything without running the generators first.

## Who It Is For

This repository is for people who verify hardware, or are learning to. It assumes you read Verilog, know synthesis and netlists, and have met a bus protocol. It also assumes you know the UVM vocabulary. The guide explains why this environment is built the way it is, not what each layer is for.

If Verilog and the flow are new, start with [ChipForAll](https://github.com/anlit75/ChipForAll). It teaches them on a design small enough to hold in your head. If the UVM vocabulary is new, ChipForAll will not close that gap, because its tests are flat. Start with pyuvm's own documentation.

## pyuvm Is Not SystemVerilog UVM

[pyuvm](https://github.com/pyuvm/pyuvm) implements the UVM 1.2 class library in Python. The layers, phases, objection mechanism and register layer here are the real structure. The language does not carry over: SystemVerilog macros, the factory, virtual interfaces and `fork`/`join` stay behind.

So "built a pyuvm verification environment" is a claim this repository supports. "SystemVerilog UVM experience" is not. If you build a portfolio, state the difference plainly. An interviewer who asks a second question will find out which you meant.

## Learn More

The [guide](docs/guide.md) covers how the testbench is built and why:

- [The Environment](docs/guide.md#the-environment): what the scoreboard verifies, and what it deliberately does not model
- [What Each Test Covers](docs/guide.md#what-each-test-covers): how to verify that a test can still fail
- [The Register Model](docs/guide.md#the-register-model): what SystemRDL cannot say about a 16550, and the pyuvm settings it needs
- [Running on the Gates](docs/guide.md#running-on-the-gates): the one rule that makes it possible
- [Constraints](docs/guide.md#constraints): why the clock is 90.9 MHz
- [Repository Layout](docs/guide.md#repository-layout): the files, and the waveforms that `WAVES=1` writes
- [Configuration Reference](docs/guide.md#configuration-reference)

---

<div align="center">

[MIT License](LICENSE) · Powered by [c4o-core](https://github.com/anlit75/c4o-core), from the [ChipForAll](https://github.com/anlit75/ChipForAll) template

</div>
