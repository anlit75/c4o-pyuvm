# ChipForAll (C4O)

![CI Status](https://github.com/anlit75/ChipForAll/actions/workflows/verify.yml/badge.svg)
![release Version](https://img.shields.io/github/v/release/anlit75/ChipForAll?label=version)
[![License](https://img.shields.io/github/license/anlit75/ChipForAll)](LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/anlit75/ChipForAll)

*[繁體中文](README.zh-TW.md)*

**A verification and CI starter kit for open-source silicon.** Simulate your RTL, drive it from Python, simulate the gates it synthesises into, and read the signoff numbers — then hand the physical flow to LibreLane. One `make` command each, nothing to install.

## ✨ Features

*   **🧪 Testbenches that can actually fail**: `make sim` for Verilog, `make cocotb` for Python. Both exit non-zero when they should — a test that passes on a broken design is worse than no test.
*   **🔬 Gate-level simulation**: `make gatesim` re-runs your tests against the netlist synthesis actually produced. Latch inference and reset handling sit between your RTL and those gates, and none of it is visible from the RTL.
*   **📊 Signoff you can read**: `make report` pulls the handful of numbers that matter — area, timing, power, DRC/LVS/antenna — out of a 300-key `metrics.json` nobody opens.
*   **✅ CI that runs all of it**: a GitHub Actions workflow that lints, simulates, synthesises, builds the GDS and re-simulates the gates, on every push.
*   **🐳 Nothing to install**: Docker, or a Dev Container / Codespace. `make gds` works in all three.

### What this is not

The physical flow — RTL to GDSII — is [LibreLane](https://github.com/librelane/librelane)'s, and `make gds` is a thin wrapper around it. If all you want is a layout, LibreLane runs standalone with `--dockerized` and you do not need this repo.

What LibreLane does not cover is simulation and verification. That is what this starter kit adds, plus the CI and the Dev Container to run it in.

## 🚀 Quick Start

### Prerequisites
*   Docker (Desktop or Engine)
*   Make
*   Git

*… or none of the above: open it in a GitHub Codespace and everything is already there.*

### 1. Make your own copy

This repository is a **GitHub template**. Press **Use this template → Create a new repository**, then clone your copy:

```bash
git clone https://github.com/<you>/<your-repo>.git
cd <your-repo>
```

### 2. Run the full flow

```bash
make gds
```

*The first run installs the Sky130 PDK (~3GB) and takes a few minutes: synthesis, place & route, then the layout.*

### 3. Make it your design

The example is a blinky — a clock divider. To replace it with your own, four things have to agree, and nothing else does:

| Change | Where |
|---|---|
| Your RTL | `src/`, listed under `VERILOG_FILES` in `config.yaml` |
| `DESIGN_NAME` | `config.yaml` — must match your top module's name |
| Your testbenches | `test/`, under `"//TEST_FILES"` and `"//COCOTB_TESTS"` |
| The gate-level one | `test/gate/`, under `"//GATE_TESTS"` |

Nothing else names the design: the `Makefile` and the CI workflow both read `DESIGN_NAME` from `config.yaml`.

**The last two rows are optional.** Delete `"//COCOTB_TESTS"` or `"//GATE_TESTS"` from `config.yaml` and CI skips that kind of test instead of failing. Keep the key and point it at nothing and CI fails — correctly, since you asked for tests that are not there.

Get the first row wrong and you hear about it immediately, not three minutes into `make gds`:

```console
[ERROR] DESIGN_NAME is 'my_cpu', but no module by that name is declared in
        VERILOG_FILES. Declared there: blinky.
```

## 📖 Commands

| Command | Description | Output |
|---|---|---|
| `make all` | `lint`, `sim`, `cocotb` and `synth` — everything that runs in seconds. | `Terminal` |
| `make lint` | Checks your Verilog with Verilator. | `Terminal` |
| `make sim` | Runs the Verilog testbenches with Icarus Verilog. | `build/wave.vcd` |
| `make cocotb` | Runs the Python (cocotb) testbenches. | `build/cocotb-results.xml` |
| `make synth` | Synthesises RTL into gates with Yosys. | `build/synthesis.json` |
| `make schematic` | Draws the circuit as an SVG you can open anywhere. | `build/schematic.svg` |
| `make gds` | Builds the physical layout with LibreLane (~3 min). | `build/<DESIGN_NAME>.gds` |
| `make gatesim` | Re-runs simulation on the synthesised netlist. Needs `make gds` first. | `Terminal` |
| `make report` | Area, timing, power and signoff from the last `make gds`. | `Terminal` |
| `make shell` | A bash shell inside the c4o-core container. | — |
| `make clean` | Removes `build/`. Keeps `runs/`, which `report` and `gatesim` read. | — |
| `make distclean` | Removes `build/` and `runs/`. | — |

`make help` lists them in the terminal.

## 📊 Reading the result

`make gds` ends by printing what the flow measured, so you do not have to go looking for it:

```
  blinky

  die              69.485 x 80.205 um  (5573.04 um^2)
  utilization      57.1%
  standard cells   198
  setup slack      +4.70 ns  (0 violations)
  hold slack       +0.11 ns  (0 violations)
  power            0.290 mW
  signoff          clean  (Magic DRC, KLayout DRC, LVS, antenna, XOR)
  lint warnings    0
  layout           runs/blinky_run/final/render/blinky.png
```

**`signoff`** says the thing nothing else says: your layout passes the manufacturability checks. LibreLane errors on every one of them by default, so a run that reached this line has already passed them — `clean` states it, and names which checks it saw. When something is wrong it names that instead: `2 Magic DRC, 1 LVS`.

**`layout`** is the PNG the flow drew of your chip. Open it.

**Positive slack** means the design meets the clock in `config.yaml`. Negative means it does not, and the flow does not stop for it — so a run can finish and still be telling you it missed. [What to do about that](docs/guide.md#when-slack-is-negative) is in the guide.

`make report` prints all of it again without re-running anything.

## 📚 Next steps

The [guide](docs/guide.md) covers what comes after the first run:

*   [Writing a testbench for your own design](docs/guide.md#writing-a-testbench-for-your-own-design) — the smallest one that can actually fail
*   [Looking at the waveform](docs/guide.md#when-a-test-fails-look-at-the-waveform) when a test goes red
*   [Python testbenches](docs/guide.md#writing-testbenches-in-python) with cocotb, [random stimulus against a reference model](docs/guide.md#random-stimulus-and-a-reference-model), and [gate-level simulation](docs/guide.md#simulating-the-gates-not-just-the-rtl)
*   [Iterating](docs/guide.md#iterating-without-re-running-the-whole-flow) without re-running the whole flow, and [seeing the circuit](docs/guide.md#seeing-the-circuit)
*   [Working inside the container](docs/guide.md#working-inside-the-container), and the [full configuration reference](docs/guide.md#configuration-reference)

## 📂 Project Structure

```text
.
├── .devcontainer/     # 🐳 VS Code Dev Container definition
├── config.yaml        # ⚙️ Design name, clock, floorplan
├── Makefile           # 🎮 The command center
├── docs/              # 📚 Everything after the first run
├── src/               # ✍️ Your Verilog source code
│   └── blinky.v
├── test/              # 🧪 Your testbenches
│   ├── tb_blinky.v              # RTL simulation (make sim)
│   ├── test_blinky_cocotb.py    # Python testbenches (make cocotb)
│   ├── test_blinky_random.py    # Random stimulus vs a reference model
│   └── gate/                    # Gate-level simulation (make gatesim)
│       └── tb_blinky_gl.v
└── build/             # 📦 Generated artifacts (GDS, logs, netlists)
```

## 📝 Configuration

`config.yaml` is a [LibreLane](https://github.com/librelane/librelane) configuration file — the same file drives simulation and the physical design flow. These are the keys you normally touch:

```yaml
DESIGN_NAME: my_design

VERILOG_FILES:
  - dir::src/my_design.v

# Simulation only. LibreLane ignores keys starting with '//'.
"//TEST_FILES":
  - dir::test/*.v

CLOCK_PORT: clk
CLOCK_PERIOD: 10.0
```

The rest (`PDK`, `FP_SIZING`, `FP_CORE_UTIL`, …) configures the physical design flow; leave it alone until you need it. The die is not something you have to size — `FP_SIZING: relative` grows it to fit your design. The [configuration reference](docs/guide.md#configuration-reference) has the details.

---

Powered by the **[c4o-core](https://github.com/anlit75/c4o-core)** engine.
