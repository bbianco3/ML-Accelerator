// memory_map.h -- the simulated platform's physical address map.
//
// This header is the single source of truth for addresses and is included by
// BOTH the host software (compiled for RV64) and the simulator's C code
// (compiled natively by VCS). Keep it plain C with no dependencies.
// See docs/memory-map.md for the full description.
#ifndef MEMORY_MAP_H
#define MEMORY_MAP_H

// MM_U(x): unsigned constant in C, plain number in assembly (crt0.S).
#ifdef __ASSEMBLER__
#define MM_U(x) x
#else
#define MM_U(x) x##u
#endif

// ---- Accelerator host-control registers (AXI4-Lite, 4 KiB) -----------------
#define ACCEL_CSR_BASE   MM_U(0x10000000)
#define ACCEL_CSR_SIZE   MM_U(0x00001000)

// ---- Simulation control device (implemented in sim/csrc, not in RTL) -------
#define SIMCTRL_BASE     MM_U(0x11000000)
#define SIMCTRL_SIZE     MM_U(0x00001000)
#define SIMCTRL_PUTCHAR  (SIMCTRL_BASE + MM_U(0x00))  // W : write a character to the log
#define SIMCTRL_EXIT     (SIMCTRL_BASE + MM_U(0x04))  // W : end simulation, value = exit code
#define SIMCTRL_CYCLE_LO (SIMCTRL_BASE + MM_U(0x08))  // R : testbench cycle counter [31:0]
#define SIMCTRL_CYCLE_HI (SIMCTRL_BASE + MM_U(0x0C))  // R : testbench cycle counter [63:32]
#define SIMCTRL_ROI      (SIMCTRL_BASE + MM_U(0x10))  // RW: 1 = inside the region of interest (host timed + energy counted)

// ---- Accelerator scratchpads (accelerator side ONLY) ------------------------
// Inside a kernel, addresses SPAD_BASE .. SPAD_BASE + SPAD_WINDOW - 1 go to the
// running core's private scratchpad SRAM instead of HBM (every core sees its
// own scratchpad at the same address). Only the first SPAD_KB KiB exist
// (accel_get_config().spad_bytes). The host cannot access scratchpads.
#define SPAD_BASE        MM_U(0x20000000)
#define SPAD_WINDOW      MM_U(0x01000000)             // 16 MiB decode window

// ---- HBM: shared between host (functional access) and accelerator (AXI4) ---
// Addresses are identical from both sides: a pointer into HBM can be handed
// to the accelerator unchanged.
#define HBM_BASE         MM_U(0x40000000)
#define HBM_SIZE         MM_U(0x40000000)             // 1 GiB window (sparse in sim)

// ---- Host-private RAM: host code, data, stack -------------------------------
#define HOST_RAM_BASE    MM_U(0x80000000)
#define HOST_RAM_SIZE    MM_U(0x00400000)             // 4 MiB

#endif // MEMORY_MAP_H
