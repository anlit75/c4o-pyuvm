# ChipForAll Makefile
# Philosophy: Keep it simple. Delegate logic to c4o-core.

# Image Configuration
#
# Pinned to the minor, not the patch. c4o-core publishes 2.8.0, 2.8, 2 and
# latest for every release; 2.8 means a fix reaches you without anybody editing
# this line, while a new behaviour never arrives unannounced. Pin 2.8.0 instead
# if you want a byte-identical image forever, and remember that you then also
# own noticing its fixes.
#
# Three files carry this version -- here, .devcontainer/devcontainer.json, and
# the docker pull in .github/workflows/verify.yml. CI refuses to continue when
# they disagree, so change all three together.
C4O_IMAGE := ghcr.io/anlit75/c4o-core:2.8
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
# C4O_SV2V is the one place a tool from the image is reached directly rather
# than through the entrypoint. sv2v is not a c4o-core command -- it is a binary
# the image carries -- so on the host it needs --entrypoint, and in the
# container it is just on PATH.
ifneq ($(wildcard $(ENTRYPOINT_SCRIPT)),)
	# Case A: We are inside the DevContainer
	C4O_CMD := python3 $(ENTRYPOINT_SCRIPT)
	C4O_COCOTB = $(if $(SEED),env RANDOM_SEED=$(SEED)) $(C4O_CMD)
	C4O_SV2V := sv2v
else
	# Case B: We are on the Host Machine
	C4O_CMD := $(DOCKER_RUN) $(C4O_IMAGE)
	C4O_COCOTB = $(DOCKER_RUN) $(if $(SEED),-e RANDOM_SEED=$(SEED)) $(C4O_IMAGE)
	C4O_SV2V := $(DOCKER_RUN) --entrypoint sv2v $(C4O_IMAGE)
endif

.PHONY: all help rtl lint sim cocotb gatesim synth schematic gds pdk report clean distclean shell

all: lint sim cocotb synth

help:
	@echo "Available targets:"
	@echo "  make rtl     - Regenerate src/apb_uart_sv.v from the vendored SystemVerilog"
	@echo "  make lint    - Run Verilator lint check"
	@echo "  make sim     - Run Icarus Verilog simulation"
	@echo "  make cocotb  - Run the Python (cocotb) testbenches"
	@echo "                 (repeat a random failure: make cocotb SEED=<n>)"
	@echo "  make gatesim - Re-simulate the synthesised netlist (~5 min, after make gds)"
	@echo "  make synth   - Run Yosys synthesis"
	@echo "  make schematic - Draw the circuit as build/schematic.svg"
	@echo "  make pdk     - Install/Enable Sky130 PDK via Ciel"
	@echo "  make gds     - Run LibreLane GDSII flow"
	@echo "  make report  - Show area, timing and power from the last GDS run"
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
		echo ""; \
		$(C4O_SV2V) $(VENDOR_SV); \
	} > src/apb_uart_sv.v

# --- Logic Delegated to c4o-core ---

lint:
	$(C4O_CMD) lint

sim:
	$(C4O_CMD) sim

# The same RTL, driven from Python instead of Verilog. Not a replacement for
# `make sim`: it is a second way to write a testbench, and the example shows the
# thing Python is better at -- writing to a signal inside the design.
cocotb:
	$(C4O_COCOTB) cocotb

# Simulates runs/<tag>/final/nl/, which `make gds` leaves behind, against
# the PDK's own cell models. `make sim` says the RTL behaves; this says the gates
# synthesis produced still behave, which is a different claim.
#
# Budget four to five minutes: the netlist has no WIDTH left to shrink, so
# test/gate/tb_blinky_gl.v has to run the divider's full 2**26 cycles.
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
