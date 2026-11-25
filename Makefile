#==============================================================================
# SIGARCH ML accelerator template -- top-level Makefile
#
#   make help                       list targets and knobs
#   make run TEST=vadd              build + simulate one test
#   make regress                    run every test in sw/tests
#   make synth                      Design Compiler synthesis of accel_top
#
# Hardware parameters (VLEN, MAT_DIM, ...) can be overridden on the command
# line, e.g. `make run TEST=matmul VLEN=512 MXU_ROWS=16`. Every distinct
# configuration gets its own build directory, so switching is cheap.
# See docs/simulation.md for every knob.
#==============================================================================
ifneq ($(filter 3.%,$(MAKE_VERSION)),)
  $(error GNU make $(MAKE_VERSION) is too old (need >= 4.0). The Synopsys module puts make 3.80 on PATH; 'source setup_env.sh' removes it, or run /usr/bin/make)
endif

REPO  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD := $(REPO)/build
SHELL := /bin/bash -o pipefail

# ---------------- hardware configuration (RTL parameters) ----------------
VLEN         ?= 128
MAT_DIM      ?= 16
NUM_TREGS    ?= 2
NUM_ACCS     ?= 1
MXU_ROWS     ?= 4
HBM_DATA_W   ?= 256
ICACHE_LINES ?= 16
NUM_CORES    ?= 4
SPAD_KB      ?= 16
# Cores 0 .. NUM_VPUS-1 have a vector unit, cores 0 .. NUM_MXUS-1 a matrix unit.
NUM_VPUS     ?= $(NUM_CORES)
NUM_MXUS     ?= $(NUM_CORES)
# Pipeline stages in the VPU / MXU floating-point datapaths (0, 1 or 2).
FP_PIPE      ?= 1

# RTL directory (contains filelist.f). hw/rtl is the design you work on; pass
# RTL_DIR=<dir> to build, simulate and synthesize another copy of the RTL.
RTL_DIR ?= $(REPO)/hw/rtl
override RTL_DIR := $(abspath $(RTL_DIR))

# Generated RTL: the SRAM wrapper accel_sram_1rw (hw/sram/sram_gen.py
# --wrapper). It is compiled in front of the files of filelist.f in
# simulation, lint and synthesis, so a design can simply instantiate it.
SRAM_WRAPPER := $(BUILD)/gen/accel_sram_1rw.sv
GEN_SRCS     := $(SRAM_WRAPPER)

$(SRAM_WRAPPER): $(REPO)/hw/sram/sram_gen.py
	@python3 $< --wrapper $@

# (A suffix for the units appears only when they differ from NUM_CORES, FP_PIPE=0
# has none, and another RTL_DIR adds its directory name.)
HW_CFG := v$(VLEN)_m$(MAT_DIM)_t$(NUM_TREGS)_a$(NUM_ACCS)_r$(MXU_ROWS)_d$(HBM_DATA_W)_i$(ICACHE_LINES)_c$(NUM_CORES)_s$(SPAD_KB)$(if $(filter-out $(NUM_CORES)x$(NUM_CORES),$(NUM_VPUS)x$(NUM_MXUS)),_u$(NUM_VPUS)x$(NUM_MXUS))$(if $(filter-out 0,$(FP_PIPE)),_p$(FP_PIPE))$(if $(filter-out $(REPO)/hw/rtl,$(RTL_DIR)),_$(notdir $(RTL_DIR)))

# ---------------- PDK location (synthesis, SRAM macro models) ----------------
ASAP7_DIR    ?= $(REPO)/pdk/asap7
ASAP7_CORNER ?= TT

# ---------------- settings (competition.json) ----------------
# One file holds the numbers that simulation, synthesis and scoring share:
#   design    yours to tune: clock period and area target
#   synth     yours to tune: how hard and how long Design Compiler works
#   platform  fixed: host link delay, HBM latency, result tolerance
# Every value can also be overridden on the command line for an experiment,
# e.g. `make synth CLK_PERIOD=2.0 SYNTH_RETIME=1`. See docs/competition.md.
RULES_FILE := $(REPO)/competition.json
RULES      := $(shell python3 $(REPO)/tools/competition.py make)
ifneq ($(words $(RULES)),13)
  $(error cannot read $(RULES_FILE): run 'python3 tools/competition.py make' to see why)
endif
RULE_CLK_PERIOD     := $(word 1,$(RULES))
MAX_AREA_UM2        ?= $(word 2,$(RULES))
SYNTH_TIME_LIMIT_MIN ?= $(word 3,$(RULES))
SYNTH_EXTRA_PASSES  ?= $(word 4,$(RULES))
SYNTH_RETIME        ?= $(word 5,$(RULES))
SYNTH_CLOCK_GATING  ?= $(word 6,$(RULES))
SYNTH_MAX_FANOUT    ?= $(word 7,$(RULES))
SYNTH_BUFFER_PORTS  ?= $(word 8,$(RULES))
LINK_DELAY_NS       ?= $(word 9,$(RULES))
HBM_RD_LATENCY_NS   ?= $(word 10,$(RULES))
HBM_WR_LATENCY_NS   ?= $(word 11,$(RULES))
TOL_REL             := $(word 12,$(RULES))
TOL_ABS             := $(word 13,$(RULES))

# ---------------- test selection ----------------
TEST  ?= hello
TESTS := $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard $(REPO)/sw/tests/*/main.c)))))

.DEFAULT_GOAL := help

include $(REPO)/sw/sw.mk
include $(REPO)/sim/sim.mk
include $(REPO)/hw/synth/synth.mk

.PHONY: help clean
help:
	@echo "Targets:"
	@echo "  sw       TEST=<t>   build the host program + kernel for one test"
	@echo "  sw-all              build every test program"
	@echo "  run      TEST=<t>   build and simulate one test (logs in build/runs/...)"
	@echo "  regress             simulate every test and print a summary"
	@echo "  unit                FP-unit test: RTL bf16/fp32 functions vs C reference"
	@echo "  lint                VCS lint of the RTL only"
	@echo "  verdi    TEST=<t>   open Verdi on a run that used WAVES=1"
	@echo "  synth               synthesize accel_top with Design Compiler (PDK=asap7|freepdk45)"
	@echo "  limits              check the synthesis result against your clock and area target"
	@echo "  score    TEST=<t>   run a test and print its score: area x energy x time^2"
	@echo "  asap7               download + compile the ASAP7 cell libraries (done by synth)"
	@echo "  sram                generate + compile the ASAP7 SRAM macros     (done by synth)"
	@echo "  clean               remove build/"
	@echo ""
	@echo "Tests: $(TESTS)"
	@echo ""
	@echo "Knobs (current value):"
	@echo "  VLEN=$(VLEN) MAT_DIM=$(MAT_DIM) NUM_TREGS=$(NUM_TREGS) NUM_ACCS=$(NUM_ACCS)"
	@echo "  MXU_ROWS=$(MXU_ROWS) HBM_DATA_W=$(HBM_DATA_W) ICACHE_LINES=$(ICACHE_LINES)"
	@echo "  NUM_CORES=$(NUM_CORES) NUM_VPUS=$(NUM_VPUS) NUM_MXUS=$(NUM_MXUS) SPAD_KB=$(SPAD_KB) FP_PIPE=$(FP_PIPE)"
	@echo "  WAVES=$(WAVES)  (1 = dump FSDB waveforms)   SIM_ARGS='$(SIM_ARGS)'   SIM_SRAM=$(SIM_SRAM) (behav|macro)"
	@echo "  PDK=$(PDK) CLK_PERIOD=$(CLK_PERIOD) ns ASAP7_CORNER=$(ASAP7_CORNER) ASAP7_VT=$(ASAP7_VT) SRAM=$(SRAM) (synthesis)"
	@echo ""
	@echo "Settings (competition.json; any of them can be overridden on the command line):"
	@echo "  design   CLK_PERIOD=$(CLK_PERIOD) ns  MAX_AREA_UM2=$(MAX_AREA_UM2)"
	@echo "  synth    SYNTH_TIME_LIMIT_MIN=$(SYNTH_TIME_LIMIT_MIN) SYNTH_EXTRA_PASSES=$(SYNTH_EXTRA_PASSES) SYNTH_RETIME=$(SYNTH_RETIME)"
	@echo "           SYNTH_CLOCK_GATING=$(SYNTH_CLOCK_GATING) SYNTH_MAX_FANOUT=$(SYNTH_MAX_FANOUT) SYNTH_BUFFER_PORTS=$(SYNTH_BUFFER_PORTS) SYNTH_TAG=$(SYNTH_TAG)"
	@echo "  platform (fixed) link delay $(LINK_DELAY_NS) ns, HBM latency $(HBM_RD_LATENCY_NS)/$(HBM_WR_LATENCY_NS) ns read/write,"
	@echo "           result tolerance $(TOL_ABS) + $(TOL_REL) x |ref|"

clean:
	rm -rf $(REPO)/build
