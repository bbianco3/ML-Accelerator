#==============================================================================
# sim/sim.mk -- VCS simulation flow
#
#   build/sim/<hw-cfg>[_waves]/simv        one simulator per hardware config
#   build/runs/<hw-cfg>/<test>/sim.log     one run directory per test
#
# See docs/simulation.md for the plusargs that SIM_ARGS can carry.
#==============================================================================
VCS   ?= vcs
VERDI ?= verdi

WAVES    ?= 0
SIM_ARGS ?=
# From competition.json (top-level Makefile): CLK_PERIOD, the real duration
# of one accelerator clock (the same value synthesis targets, so that host
# time and accelerator time line up), and LINK_DELAY_NS, the one-way latency
# of the host <-> accelerator link (register accesses, irq).
PLATFORM_ARGS = +clk_period_ns=$(CLK_PERIOD) +link_delay_ns=$(LINK_DELAY_NS)
# behav: SRAMs are behavioral arrays.  macro: build the scratchpads out of the
# generated ASAP7 macro models exactly as synthesis does (needs python3).
SIM_SRAM ?= behav

SIM_CFG  := $(HW_CFG)$(if $(filter macro,$(SIM_SRAM)),_sram)$(if $(filter 1,$(WAVES)),_waves)
SIM_DIR  := $(BUILD)/sim/$(SIM_CFG)
SIMV     := $(SIM_DIR)/simv
RUN_CFG  := $(HW_CFG)$(if $(filter macro,$(SIM_SRAM)),_sram)
RUN_DIR   = $(BUILD)/runs/$(RUN_CFG)/$(TEST)

# RTL_DIR is set in the top-level Makefile (default hw/rtl)
RTL_SRCS  := $(addprefix $(RTL_DIR)/,$(shell grep -v -e '^[[:space:]]*\#' -e '^[[:space:]]*$$' $(RTL_DIR)/filelist.f))
TB_SRCS   := $(REPO)/sim/tb/hbm_model.sv $(REPO)/sim/tb/host_bfm.sv $(REPO)/sim/tb/tb_top.sv
SIM_CSRCS := $(REPO)/sim/csrc/platform.c $(REPO)/sim/csrc/rv64_iss.c $(REPO)/sim/csrc/host_model.c
SIM_CDEPS := $(SIM_CSRCS) $(wildcard $(REPO)/sim/csrc/*.h) $(REPO)/sw/common/memory_map.h

HW_DEFINES := +define+VLEN=$(VLEN) +define+MAT_DIM=$(MAT_DIM) +define+NUM_TREGS=$(NUM_TREGS) \
              +define+NUM_ACCS=$(NUM_ACCS) +define+MXU_ROWS=$(MXU_ROWS) \
              +define+HBM_DATA_W=$(HBM_DATA_W) +define+ICACHE_LINES=$(ICACHE_LINES) \
              +define+NUM_CORES=$(NUM_CORES) +define+SPAD_KB=$(SPAD_KB) \
              +define+NUM_VPUS=$(NUM_VPUS) +define+NUM_MXUS=$(NUM_MXUS) +define+FP_PIPE=$(FP_PIPE)

SRAM_V_DIR := $(ASAP7_DIR)/sram/verilog
ifeq ($(SIM_SRAM),macro)
  HW_DEFINES += +define+ACCEL_SRAM_MACROS
  SRAM_V_SRCS = $(wildcard $(SRAM_V_DIR)/*.v)
  SRAM_V_DEP := $(ASAP7_DIR)/sram/datasheet_$(ASAP7_CORNER).md
else ifneq ($(SIM_SRAM),behav)
  $(error SIM_SRAM must be behav or macro)
endif

SIM_CFLAGS := -O2 -std=gnu99 -frounding-math -fno-fast-math -I$(REPO)/sw/common -I$(REPO)/sim/csrc

VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps -kdb -lca \
             -CFLAGS "$(SIM_CFLAGS)" -LDFLAGS "-lm" \
             +lint=TFIPC-L -error=IWNF \
             -top tb_top
ifeq ($(WAVES),1)
  VCS_FLAGS += -debug_access+all +define+WAVES
endif

.PHONY: sim run regress lint unit verdi

sim: $(SIMV)

$(SIMV): $(GEN_SRCS) $(RTL_SRCS) $(TB_SRCS) $(SIM_CDEPS) $(RTL_DIR)/filelist.f $(SRAM_V_DEP)
	@command -v $(VCS) >/dev/null || { echo "ERROR: vcs not found -- did you 'source setup_env.sh'?"; exit 1; }
	@mkdir -p $(SIM_DIR)
	cd $(SIM_DIR) && $(VCS) $(VCS_FLAGS) $(HW_DEFINES) $(GEN_SRCS) $(RTL_SRCS) $(SRAM_V_SRCS) $(TB_SRCS) $(SIM_CSRCS) \
	    -o simv -l compile.log > /dev/null || { tail -40 $(SIM_DIR)/compile.log; exit 1; }
	@echo "built $(SIMV)"

# Verilog models of the SRAM macros (no lc_shell needed for these).
$(ASAP7_DIR)/sram/datasheet_$(ASAP7_CORNER).md: $(REPO)/hw/sram/sram_gen.py
	SRAM_MODELS_ONLY=1 ASAP7_DIR=$(ASAP7_DIR) ASAP7_CORNER=$(ASAP7_CORNER) $(REPO)/hw/sram/sram_setup.sh

# Per-test default plusargs live in sw/tests/<test>/plusargs (optional).
TEST_PLUSARGS = $(shell cat $(REPO)/sw/tests/$(TEST)/plusargs 2>/dev/null)

run: $(SIMV) $(ELF)
	@mkdir -p $(RUN_DIR)
	cd $(RUN_DIR) && $(SIMV) -no_save +elf=$(ELF) $(PLATFORM_ARGS) $(TEST_PLUSARGS) $(SIM_ARGS) -l sim.log
	@grep -q "TEST PASSED" $(RUN_DIR)/sim.log && echo "PASS: $(TEST)  (log: $(RUN_DIR)/sim.log)" \
	  || { echo "FAIL: $(TEST)  (log: $(RUN_DIR)/sim.log)"; exit 1; }

regress: $(SIMV) sw-all
	@pass=0; fail=0; failed=""; \
	for t in $(TESTS); do \
	  if $(MAKE) --no-print-directory run TEST=$$t > /dev/null 2>&1; then \
	    printf "  PASS  %s\n" $$t; pass=$$((pass+1)); \
	  else \
	    printf "  FAIL  %s   (see $(BUILD)/runs/$(RUN_CFG)/$$t/sim.log)\n" $$t; fail=$$((fail+1)); failed="$$failed $$t"; \
	  fi; \
	done; \
	echo "regress [$(RUN_CFG)]: $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

verdi:
	cd $(RUN_DIR) && $(VERDI) -dbdir $(SIM_DIR)/simv.daidir -ssf waves.fsdb &

# Lint the synthesizable RTL on its own (no testbench).
lint: $(GEN_SRCS)
	@mkdir -p $(BUILD)/lint
	cd $(BUILD)/lint && $(VCS) -full64 -sverilog +lint=all,noVCDE,noNS -top accel_top \
	    $(GEN_SRCS) $(RTL_SRCS) -l lint.log > /dev/null; \
	grep -E "^(Error|Warning|Lint)-" -A4 lint.log || echo "lint: clean"

#------------------------------------------------------------------------------
# FP unit test: RTL functions in accel_fp_pkg vs the C reference (bf16.h)
#------------------------------------------------------------------------------
UNIT_DIR  := $(BUILD)/unit/fp
UNIT_SIMV := $(UNIT_DIR)/simv
UNIT_N    ?= 200000

$(UNIT_SIMV): $(RTL_DIR)/accel_fp_pkg.sv $(REPO)/sim/unit/fp/fp_unit_tb.sv $(REPO)/sim/unit/fp/fp_ref_dpi.c $(REPO)/sw/common/bf16.h
	@mkdir -p $(UNIT_DIR)
	cd $(UNIT_DIR) && $(VCS) -full64 -sverilog -timescale=1ns/1ps \
	    -CFLAGS "-O2 -std=gnu99 -ffp-contract=off -fno-fast-math -I$(REPO)/sw/common" \
	    $(RTL_DIR)/accel_fp_pkg.sv $(REPO)/sim/unit/fp/fp_unit_tb.sv $(REPO)/sim/unit/fp/fp_ref_dpi.c \
	    -top fp_unit_tb -o simv -l compile.log > /dev/null || { tail -40 $(UNIT_DIR)/compile.log; exit 1; }

unit: $(UNIT_SIMV)
	cd $(UNIT_DIR) && ./simv -no_save +n=$(UNIT_N) $(SIM_ARGS) -l sim.log
	@grep -q "UNIT PASSED" $(UNIT_DIR)/sim.log && echo "PASS: fp unit test" || { echo "FAIL: fp unit test"; exit 1; }
