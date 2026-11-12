#==============================================================================
# sw/sw.mk -- build host programs (RV64G) together with their kernels (RV32)
#
# Each directory sw/tests/<name>/ containing a main.c is one test program,
# built in two stages because host and accelerator have different ISAs:
#
#   1. kernels: every *.S file is accelerator code. They are assembled for
#      the control core (KERNEL_MARCH) and linked with sw/common/kernel.ld
#      into build/sw/<name>/kernel.elf (+ kernel.bin, kernel.dis).
#   2. host: every *.c file is compiled for the RV64G host together with
#      sw/common/{crt0.S,runtime.c}, the kernel image (kernel_blob.S) and the
#      kernels' global symbols (kernel_syms.ld), and linked with
#      sw/common/link.ld into build/sw/<name>/<name>.elf (+ <name>.dis).
#==============================================================================
RISCV_PREFIX ?= riscv64-unknown-elf-
RV_CC        := $(RISCV_PREFIX)gcc
RV_OBJDUMP   := $(RISCV_PREFIX)objdump
RV_OBJCOPY   := $(RISCV_PREFIX)objcopy
RV_NM        := $(RISCV_PREFIX)nm

# Host ISA: the ISS executes RV64G (RV64IMAFD + Zicsr + Zifencei), no C.
# LIBGCC_MARCH names the multilib whose libgcc is linked (the EWS toolchain
# has no multilib with A, which libgcc does not need anyway).
HOST_MARCH   ?= rv64imafd_zicsr_zifencei
HOST_MABI    ?= lp64d
LIBGCC_MARCH ?= rv64imfd_zicsr

# Kernel ISA: what the assembler accepts in kernels. The custom vector/matrix
# instructions are .insn macros (accel_isa.h), so this only limits the scalar
# part. If you add scalar instructions to the control core (e.g. M), add the
# extension here.
KERNEL_MARCH ?= rv32i_zicsr
KERNEL_MABI  ?= ilp32

SW_COMMON    := $(REPO)/sw/common
SW_RT_SRCS   := $(SW_COMMON)/crt0.S $(SW_COMMON)/runtime.c
SW_RT_DEPS   := $(wildcard $(SW_COMMON)/*.h) $(SW_COMMON)/link.ld $(SW_RT_SRCS) $(RULES_FILE)
SW_K_DEPS    := $(wildcard $(SW_COMMON)/*.h) $(SW_COMMON)/kernel.ld

SW_CFLAGS ?= -O2 -g
SW_FLAGS   = -march=$(HOST_MARCH) -mabi=$(HOST_MABI) -mcmodel=medany \
             -ffreestanding -fno-builtin -nostdlib -nostartfiles -static \
             -ffp-contract=off -fno-common -Wall -Wextra -Wno-unused-parameter \
             -DCHECK_REL_TOL=$(TOL_REL) -DCHECK_ABS_TOL=$(TOL_ABS) \
             -I$(SW_COMMON) -T $(SW_COMMON)/link.ld -Wl,--no-warn-rwx-segments $(SW_CFLAGS)
KERNEL_FLAGS = -march=$(KERNEL_MARCH) -mabi=$(KERNEL_MABI) -g \
             -ffreestanding -nostdlib -nostartfiles -static \
             -I$(SW_COMMON) -T $(SW_COMMON)/kernel.ld -Wl,--no-warn-rwx-segments

LIBGCC = $(shell $(RV_CC) -march=$(LIBGCC_MARCH) -mabi=$(HOST_MABI) -print-libgcc-file-name 2>/dev/null)

# $(1) = test name
define SW_TEST_RULES
SW_KSRCS_$(1) := $(wildcard $(REPO)/sw/tests/$(1)/*.S)
SW_KPART_$(1) := $$(if $$(SW_KSRCS_$(1)),$(BUILD)/sw/$(1)/kernel_syms.ld)

$(BUILD)/sw/$(1)/kernel_syms.ld: $$(SW_KSRCS_$(1)) $(wildcard $(REPO)/sw/tests/$(1)/*.h) $(SW_K_DEPS)
	@command -v $(RV_CC) >/dev/null || { echo "ERROR: $(RV_CC) not found -- did you 'source setup_env.sh'?"; exit 1; }
	@mkdir -p $$(@D)
	$(RV_CC) $(KERNEL_FLAGS) -I$(REPO)/sw/tests/$(1) -o $$(@D)/kernel.elf $$(SW_KSRCS_$(1))
	$(RV_OBJCOPY) -O binary $$(@D)/kernel.elf $$(@D)/kernel.bin
	$(RV_OBJDUMP) -d $$(@D)/kernel.elf > $$(@D)/kernel.dis
	$(RV_NM) -g $$(@D)/kernel.elf | sed -E 's/^([0-9a-fA-F]+) +[A-Za-z] +(.+)/\2 = 0x\1;/' > $$@

$(BUILD)/sw/$(1)/$(1).elf: $(wildcard $(REPO)/sw/tests/$(1)/*.[ch]) $$(SW_KPART_$(1)) $(SW_RT_DEPS) $(SW_COMMON)/kernel_blob.S
	@command -v $(RV_CC) >/dev/null || { echo "ERROR: $(RV_CC) not found -- did you 'source setup_env.sh'?"; exit 1; }
	@mkdir -p $$(@D)
	$(RV_CC) $(SW_FLAGS) -I$(REPO)/sw/tests/$(1) -I$$(@D) -o $$@ \
	    $(SW_RT_SRCS) $(wildcard $(REPO)/sw/tests/$(1)/*.c) \
	    $$(if $$(SW_KPART_$(1)),$(SW_COMMON)/kernel_blob.S $$(SW_KPART_$(1))) $$(LIBGCC)
	$(RV_OBJDUMP) -d $$@ > $$(@:.elf=.dis)
endef
$(foreach t,$(TESTS),$(eval $(call SW_TEST_RULES,$(t))))

ELF = $(BUILD)/sw/$(TEST)/$(TEST).elf

.PHONY: sw sw-all
sw: $(ELF)
sw-all: $(foreach t,$(TESTS),$(BUILD)/sw/$(t)/$(t).elf)
