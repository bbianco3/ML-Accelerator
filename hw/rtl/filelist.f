# RTL source list for the accelerator, in compile order (packages first).
# Paths are relative to this directory. Used by both the VCS flow
# (sim.mk) and the DC flow (hw/synth/synthesis.tcl).
# Add every module you write here. The SRAM wrapper accel_sram_1rw is
# generated (hw/sram/sram_gen.py) and compiled automatically: do not list it.
accel_pkg.sv
accel_fp_pkg.sv
accel_csr.sv
accel_axi_master.sv
accel_axi_arbiter.sv
accel_spad.sv
accel_vpu.sv
accel_mxu.sv
accel_icache.sv
accel_core.sv
accel_top.sv