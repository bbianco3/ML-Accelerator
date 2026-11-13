#==============================================================================
# hw/synth/synth.mk -- Synopsys Design Compiler flow for accel_top
#
#   make synth                      ASAP7 (default PDK), 2.5 ns (400 MHz) clock
#   make synth CLK_PERIOD=2.0 VLEN=128 MXU_ROWS=2
#   make synth PDK=freepdk45 CLK_PERIOD=10
#   make synth SRAM=flops           scratchpads as flip-flops (for comparison)
#
# The first ASAP7 synthesis downloads + compiles the cell libraries into
# pdk/asap7/ (`make asap7`, ~1 minute, once) and generates the SRAM macros
# (`make sram`, seconds).
#
# Results: build/synth/<pdk>/<hw-cfg>_<clk>ns/{reports/*.rpt, accel_top.v, .ddc, .sdc}
# See docs/synthesis.md.
#==============================================================================
DC_SHELL     ?= dc_shell
PDK          ?= asap7
ASAP7_DIR    ?= $(REPO)/pdk/asap7
ASAP7_CORNER ?= TT
ASAP7_VT     ?= RVT
# SRAM=macro: scratchpads use the generated ASAP7 SRAM macros; SRAM=flops: flip-flops
SRAM         ?= macro
ifeq ($(PDK),asap7)
  # the competition clock (competition.json); override to explore
  CLK_PERIOD ?= $(RULE_CLK_PERIOD)
  PDK_TAG    := asap7_$(ASAP7_CORNER)_$(ASAP7_VT)
  PDK_DEP    := asap7 $(if $(filter macro,$(SRAM)),sram)
else
  CLK_PERIOD ?= 10
  PDK_TAG    := $(PDK)
  PDK_DEP    :=
  # no SRAM macros for other PDKs (see docs/sram.md)
  override SRAM := flops
endif
SYN_DIR := $(BUILD)/synth/$(PDK_TAG)/$(HW_CFG)$(if $(filter flops,$(SRAM)),_flops)_$(CLK_PERIOD)ns

.PHONY: synth asap7 sram limits score
synth: $(PDK_DEP) $(GEN_SRCS)
	@command -v $(DC_SHELL) >/dev/null || { echo "ERROR: dc_shell not found -- did you 'source setup_env.sh'?"; exit 1; }
	@mkdir -p $(SYN_DIR)/reports
	cd $(SYN_DIR) && \
	  ACCEL_RTL_DIR=$(RTL_DIR) ACCEL_GEN_SRCS="$(GEN_SRCS)" CLK_PERIOD=$(CLK_PERIOD) PDK=$(PDK) SRAM=$(SRAM) \
	  ASAP7_DIR=$(ASAP7_DIR) ASAP7_CORNER=$(ASAP7_CORNER) ASAP7_VT=$(ASAP7_VT) \
	  VLEN=$(VLEN) MAT_DIM=$(MAT_DIM) NUM_TREGS=$(NUM_TREGS) NUM_ACCS=$(NUM_ACCS) \
	  MXU_ROWS=$(MXU_ROWS) HBM_DATA_W=$(HBM_DATA_W) ICACHE_LINES=$(ICACHE_LINES) \
	  NUM_CORES=$(NUM_CORES) SPAD_KB=$(SPAD_KB) \
	  NUM_VPUS=$(NUM_VPUS) NUM_MXUS=$(NUM_MXUS) FP_PIPE=$(FP_PIPE) \
	  $(DC_SHELL) -f $(REPO)/hw/synth/synthesis.tcl 2>&1 | tee synth.log
	@echo "Reports are in $(SYN_DIR)/reports/"
	@python3 $(REPO)/tools/competition.py limits $(SYN_DIR) || true

# Check the synthesis result of this configuration against competition.json.
limits:
	@python3 $(REPO)/tools/competition.py limits $(SYN_DIR)

# Run TEST and score its region of interest: area x energy x time^2, with
# area and accelerator power from this configuration's synthesis reports.
score: run
	@python3 $(REPO)/tools/competition.py score $(RUN_DIR)/sim.log $(SYN_DIR)

# Generate the ASAP7 SRAM macro catalog and compile it to .db (idempotent).
sram:
	@ASAP7_DIR=$(ASAP7_DIR) ASAP7_CORNER=$(ASAP7_CORNER) $(REPO)/hw/sram/sram_setup.sh

# Fetch the ASAP7 standard-cell libraries and compile them to .db (idempotent).
asap7:
	@ASAP7_DIR=$(ASAP7_DIR) ASAP7_CORNER=$(ASAP7_CORNER) ASAP7_VT=$(ASAP7_VT) \
	  $(REPO)/hw/synth/pdk/asap7_setup.sh
