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
VLEN         ?= 256
MAT_DIM      ?= 16
NUM_TREGS    ?= 4
NUM_ACCS     ?= 2
MXU_ROWS     ?= 4
HBM_DATA_W   ?= 256
ICACHE_LINES ?= 16
NUM_CORES    ?= 2
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

# (A suffix for the units appears only when they differ from NUM_CORES, FP_PIPE=0
# has none, and another RTL_DIR adds its directory name.)
HW_CFG := v$(VLEN)_m$(MAT_DIM)_t$(NUM_TREGS)_a$(NUM_ACCS)_r$(MXU_ROWS)_d$(HBM_DATA_W)_i$(ICACHE_LINES)_c$(NUM_CORES)_s$(SPAD_KB)$(if $(filter-out $(NUM_CORES)x$(NUM_CORES),$(NUM_VPUS)x$(NUM_MXUS)),_u$(NUM_VPUS)x$(NUM_MXUS))$(if $(filter-out 0,$(FP_PIPE)),_p$(FP_PIPE))$(if $(filter-out $(REPO)/hw/rtl,$(RTL_DIR)),_$(notdir $(RTL_DIR)))

# ---------------- PDK location (synthesis, SRAM macro models) ----------------
ASAP7_DIR    ?= $(REPO)/pdk/asap7
ASAP7_CORNER ?= TT

# ---------------- competition rules ----------------
# competition.json holds the limits shared by simulation, synthesis and
# scoring: clock period, area limit, host link delay, result tolerance.
RULES_FILE := $(REPO)/competition.json
RULES      := $(shell python3 $(REPO)/tools/competition.py make)
ifneq ($(words $(RULES)),5)
  $(error cannot read $(RULES_FILE): run 'python3 tools/competition.py make' to see why)
endif
RULE_CLK_PERIOD := $(word 1,$(RULES))
MAX_AREA_UM2    := $(word 2,$(RULES))
LINK_DELAY_NS   ?= $(word 3,$(RULES))
TOL_REL         := $(word 4,$(RULES))
TOL_ABS         := $(word 5,$(RULES))

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
	@echo "  limits              check the synthesis result against competition.json (timing, area)"
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
	@echo "Rules (competition.json): clock $(RULE_CLK_PERIOD) ns, area <= $(MAX_AREA_UM2) um^2,"
	@echo "  host link delay $(LINK_DELAY_NS) ns, result tolerance $(TOL_ABS) + $(TOL_REL) x |ref|"

clean:
	rm -rf $(REPO)/build
