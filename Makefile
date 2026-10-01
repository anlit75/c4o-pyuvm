# ChipForAll Makefile
# Philosophy: Keep it simple. Delegate logic to c4o-core.

# Image Configuration
#
# Pinned to the minor, not the patch. c4o-core publishes 2.13.0, 2.13, 2 and
# latest for every release; 2.13 means a fix reaches you without anybody editing
# this line -- for as long as 2.13 is c4o-core's newest minor. Only the newest
# minor gets fixes, so once 2.14 is out this line has to move to keep getting
# them. A new behaviour never arrives unannounced. Pin 2.13.0 instead if you
# want a byte-identical image forever, and remember that you then also own
# noticing its fixes.
#
# Three files carry this version -- here, .devcontainer/devcontainer.json, and
# the docker pull in .github/workflows/verify.yml. CI refuses to continue when
# they disagree, so change all three together.
C4O_IMAGE := ghcr.io/anlit75/c4o-core:2.13
LIBRELANE_IMAGE := ghcr.io/librelane/librelane:3.0.14

# Extra flags for the LibreLane run. The reason this exists is iteration: a
# full flow is three minutes, and most of what you change after the first one
# -- FP_CORE_UTIL, CLOCK_PERIOD, the floorplan -- does not need synthesis redone.
#
#   make gds LIBRELANE_ARGS="--last-run --from floorplan"
#
# --last-run is why runs/ is left where LibreLane put it; see the gds target.
LIBRELANE_ARGS ?=
DESIGN_NAME := $(shell grep -E '^DESIGN_NAME:' config.yaml | sed -e 's/^DESIGN_NAME:[[:space:]]*//' -e 's/["'"'"']//g')
PWD := $(shell pwd)

# Common Docker Flags
# We mount the current directory to /workspace so artifacts persist in build/
DOCKER_RUN := docker run --rm -v $(PWD):/workspace -w /workspace -u $(shell id -u):$(shell id -g)

# Check if the entrypoint script exists locally (means we are inside the container)
ENTRYPOINT_SCRIPT := /opt/c4o-core/scripts/entrypoint.py

# C4O_COCOTB is the same command with a seed threaded through. A random test
# is only worth running if its failures repeat: cocotb seeds Python's random
# module from the seed below and logs the value it used, so
#
#   make cocotb SEED=1789965785
#
# replays a failed run exactly. It needs its own variable because the value
# has to cross into the container, which an exported shell variable does not.
#
# SEED here, RANDOM_SEED inside: that is cocotb 1.9's name for it, and cocotb
# 2 renames it again (COCOTB_RANDOM_SEED). Translating at this line is what
# keeps `make cocotb SEED=...` the same command across that change.
#
# C4O_SV2V and C4O_PEAKRDL are the two tools from the image reached directly
# rather than through the entrypoint. Neither is a c4o-core command -- they are
# binaries the image carries -- so on the host they need --entrypoint, and in the
# container they are just on PATH.
ifneq ($(wildcard $(ENTRYPOINT_SCRIPT)),)
	# Case A: We are inside the DevContainer
	C4O_CMD := python3 $(ENTRYPOINT_SCRIPT)
	C4O_COCOTB = $(if $(SEED),env RANDOM_SEED=$(SEED)) $(C4O_CMD)
	C4O_SV2V := sv2v
	C4O_PEAKRDL := peakrdl
else
	# Case B: We are on the Host Machine
	C4O_CMD := $(DOCKER_RUN) $(C4O_IMAGE)
	C4O_COCOTB = $(DOCKER_RUN) $(if $(SEED),-e RANDOM_SEED=$(SEED)) $(C4O_IMAGE)
	C4O_SV2V := $(DOCKER_RUN) --entrypoint sv2v $(C4O_IMAGE)
	C4O_PEAKRDL := $(DOCKER_RUN) --entrypoint peakrdl $(C4O_IMAGE)
endif

.PHONY: all help rtl ral lint sim cocotb cocotb-gl gatesim synth schematic gds pdk report site clean distclean shell

all: lint sim cocotb synth

help:
	@echo "Available targets:"
	@echo "  make rtl     - Regenerate src/apb_uart_sv.v from the vendored SystemVerilog"
	@echo "  make ral     - Regenerate test/uart_ral.py from regs/apb_uart.rdl"
	@echo "  make lint    - Run Verilator lint check"
	@echo "  make sim     - Run Icarus Verilog simulation"
	@echo "  make cocotb  - Run the pyuvm testbenches against the RTL"
	@echo "                 (repeat a random failure: make cocotb SEED=<n>)"
	@echo "  make cocotb-gl - Run the same tests against the netlist (after make gds)"
	@echo "  make gatesim - Re-simulate the synthesised netlist (~5 min, after make gds)"
	@echo "  make synth   - Run Yosys synthesis"
	@echo "  make schematic - Draw the circuit as build/schematic.svg"
	@echo "  make pdk     - Install/Enable Sky130 PDK via Ciel"
	@echo "  make gds     - Run LibreLane GDSII flow"
	@echo "  make report  - Show area, timing and power from the last GDS run"
	@echo "  make site    - Put report, layout, schematic and tests on one page (build/site/)"
	@echo "  make shell   - Enter c4o-core interactive shell"
	@echo "  make clean     - Remove build/ (keeps runs/, which report and gatesim read)"
	@echo "  make distclean - Remove build/ and runs/"
	@echo ""
	@echo "  Re-run part of the flow after the first full one:"
	@echo "    make gds LIBRELANE_ARGS=\"--last-run --from floorplan\""

# --- The DUT is generated, and the generated file is committed ---

# src/vendor/apb_uart_sv/ is somebody else's SystemVerilog. Nothing in this
# image reads it: yosys 0.33 stops at apb_uart_sv.sv:42 with "syntax error,
# unexpected '['". sv2v translates it to the Verilog-2005 that yosys, Icarus
# and LibreLane all accept.
#
# The result is committed rather than built on demand, because VERILOG_FILES is
# validated as a literal path -- LibreLane would refuse a file that does not
# exist yet, so `make gds` on a fresh clone has to find it already there. CI
# re-runs this target and fails if the committed file differs, which is what
# stops it drifting from the SystemVerilog above it.
#
# File order is src_files.yml's, and sv2v's output is deterministic, so
# re-running this on an unchanged source is a no-op.
VENDOR_SV := \
	src/vendor/apb_uart_sv/apb_uart_sv.sv \
	src/vendor/apb_uart_sv/uart_rx.sv \
	src/vendor/apb_uart_sv/uart_tx.sv \
	src/vendor/apb_uart_sv/io_generic_fifo.sv \
	src/vendor/apb_uart_sv/uart_interrupt.sv

rtl:
	@echo "🟢 sv2v: $(words $(VENDOR_SV)) SystemVerilog files -> src/apb_uart_sv.v"
	@{ \
		echo "// GENERATED by \`make rtl\` from src/vendor/apb_uart_sv/*.sv -- do not edit."; \
		echo "//"; \
		echo "// sv2v turns the vendored SystemVerilog into the Verilog-2005 that yosys and"; \
		echo "// Icarus read. Without it, yosys 0.33 stops at apb_uart_sv.sv:42 with"; \
		echo "// \"syntax error, unexpected '['\". Committed rather than built on demand so"; \
		echo "// that a fresh clone can run the flow, and checked in CI so it cannot drift"; \
		echo "// from the SystemVerilog above it."; \
		echo "//"; \
		echo "// The Solderpad 0.51 terms in src/vendor/apb_uart_sv/LICENSE cover this file"; \
		echo "// too: it is the same design, mechanically translated."; \
		echo "//"; \
		echo "// The \`timescale is ours, not sv2v's, and not decoration. Without it Icarus"; \
		echo "// runs this file at a precision of one second, while the PDK cell models a"; \
		echo "// gate-level run compiles alongside it carry 1ns/1ps -- so \`make cocotb\` and"; \
		echo "// \`make cocotb-gl\` saw two different meanings of time, and the same clock"; \
		echo "// period meant 10 ns on the gates and 10 s on the RTL."; \
		echo ""; \
		echo "\`timescale 1ns / 1ps"; \
		echo ""; \
		$(C4O_SV2V) $(VENDOR_SV); \
	} > src/apb_uart_sv.v

# regs/apb_uart.rdl is the register map, and test/uart_ral.py is what PeakRDL
# makes of it. Committed for the same reason src/apb_uart_sv.v is: a fresh clone
# has to be able to run the tests, and CI regenerates and diffs so the two cannot
# drift.
#
# The output is left exactly as peakrdl writes it -- no header of ours -- so that
# the diff in CI is against the tool's output and nothing else. What the map says
# and what it cannot say is written in the .rdl.
ral:
	@echo "🟢 peakrdl pyuvm: regs/apb_uart.rdl -> test/uart_ral.py"
	$(C4O_PEAKRDL) pyuvm regs/apb_uart.rdl -o test/uart_ral.py

# --- Logic Delegated to c4o-core ---

lint:
	$(C4O_CMD) lint

sim:
	$(C4O_CMD) sim

# The same RTL, driven from Python instead of Verilog. Not a replacement for
# `make sim`: that one is the smoke test, and this is where the verification
# lives -- a pyuvm environment with an APB agent and a scoreboard.
cocotb:
	$(C4O_COCOTB) cocotb

# The same tests again, against the gates. Not a different testbench: the exact
# same three tests, the exact same Python, driving runs/<tag>/final/nl/ instead
# of src/. That only works because nothing in test/ touches anything but the
# top-level ports -- reach inside the design and this target is where you find
# out, with an AttributeError naming the net that synthesis removed.
#
# Needs `make gds` first, for the netlist.
cocotb-gl:
	$(C4O_COCOTB) cocotb --netlist

# Simulates runs/<tag>/final/nl/, which `make gds` leaves behind, against
# the PDK's own cell models. `make sim` says the RTL behaves; this says the gates
# synthesis produced still behave, which is a different claim.
#
# Wants its own Verilog testbench under test/gate/, named by //GATE_TESTS in
# config.yaml. There is none: `make cocotb-gl` above covers the same ground
# without a second testbench to keep in step with the first.
gatesim:
	$(C4O_CMD) gatesim

synth:
	$(C4O_CMD) synth

# A picture of the RTL, not of the netlist. `make synth` runs a full synthesis
# and leaves a wall of technology cells; this stops after `proc; opt`, where
# the design still looks like the code you wrote.
schematic:
	$(C4O_CMD) schematic

pdk:
	@echo "📦 Installing PDK (Sky130)..."
	$(C4O_CMD) pdk

# --- Physical Design (Sidecar Pattern) ---
# 1. Ensure PDK is ready.
# 2. Guard Check: Stop unless a Docker daemon answers.
# 3. c4o-core validates the config.
# 4. We run the heavy LibreLane image using the PDKs installed in the previous step.
#
# The container command mirrors what `librelane --dockerized` runs itself:
# `python3 -m librelane` with the flags, and --user to keep artifacts owned by
# the host user. --manual-pdk stops Ciel from re-resolving the PDK, since the
# `pdk` target above already pinned and enabled it.
gds:
	@# 🛑 Guard Clause: LibreLane runs as a sidecar container, so this needs a
	@# daemon it can actually talk to. The Dev Container ships one (see
	@# .devcontainer/devcontainer.json); ask the daemon rather than guessing
	@# from where we are, so a container without the feature and a host without
	@# Docker both get the same clear answer instead of a wall of client error.
	@if ! docker info >/dev/null 2>&1; then \
		echo "❌ [ERROR] 'make gds' needs a working Docker daemon to run LibreLane."; \
		echo "👉 On your host: start Docker Desktop, or check 'docker info'."; \
		echo "👉 In the Dev Container: rebuild it so the docker-in-docker feature installs."; \
		exit 1; \
	fi

	$(MAKE) pdk

	@echo "🟢 Validating config with c4o-core..."
	$(C4O_CMD) check
	@echo "🟢 Running LibreLane..."
	mkdir -p build
	docker run --rm \
		-v $(PWD):/workspace -w /workspace \
		-v $(PWD)/pdks:/pdks \
		-e PDK_ROOT=/pdks \
		-e HOME=/tmp \
		-u $(shell id -u):$(shell id -g) \
		$(LIBRELANE_IMAGE) \
		python3 -m librelane --manual-pdk --pdk-root /pdks \
			$(LIBRELANE_ARGS) \
			--run-tag $(DESIGN_NAME)_run config.yaml
	@echo "🟢 Post-processing..."
	# Copy the final GDS to the build folder
	cp runs/$(DESIGN_NAME)_run/final/gds/$(DESIGN_NAME).gds build/$(DESIGN_NAME).gds
	# runs/ stays where LibreLane put it. Moving it into build/ used to look
	# tidier, and it silently broke --last-run: LibreLane looks for a previous
	# run in runs/, and there was never one there. c4o-core's report and
	# gatesim already search both locations, so nothing else cared.

	@# The flow just measured area, timing and power. Show them rather than
	@# leaving them in a 300-key metrics.json under runs/.
	@$(MAKE) --no-print-directory report

# Reads runs/<tag>/final/metrics.json, which `make gds` leaves behind.
report:
	$(C4O_CMD) report

# build/site/index.html: what `report` prints, the layout render, the schematic
# and both cocotb runs' verdicts, on one page. Shows whatever has been run so
# far. CI publishes it to GitHub Pages from main.
site:
	$(C4O_CMD) site

# --- Utilities ---

shell:
	$(DOCKER_RUN) -it --entrypoint /bin/bash $(C4O_IMAGE)

# runs/ is deliberately not in here. `make report` and `make gatesim` both
# read the last flow out of it, so wiping it on every clean costs you the
# ability to look at a finished run again -- which is most of what you want
# after a three-minute flow. `distclean` is there for when you do mean it.
clean:
	rm -rf build/

distclean: clean
	rm -rf runs/
