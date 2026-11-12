# Memory map and register map

## Platform address map (simulation)

One flat 32-bit physical address space, shared by the host CPU and the
accelerator. Defined once in
[`sw/common/memory_map.h`](../sw/common/memory_map.h), which is used by both
the host software and the simulator's C code.

| Range | Size | What | Host access | Accelerator access |
|---|---|---|---|---|
| `0x1000_0000 - 0x1000_0FFF` | 4 KiB | Accelerator control registers | AXI4-Lite through the RTL (timed) | -- |
| `0x1100_0000 - 0x1100_0FFF` | 4 KiB | Simulation control device | functional (C model) | -- |
| `0x2000_0000 - 0x20FF_FFFF` | `SPAD_KB` KiB used of 16 MiB | **Scratchpad** of the core making the access (private per core) | -- | 1-cycle SRAM |
| `0x4000_0000 - 0x7FFF_FFFF` | 1 GiB | **HBM** | functional; memory-access time inside the region of interest | AXI4 master (timed) |
| `0x8000_0000 - 0x803F_FFFF` | 4 MiB | Host RAM (code, data, stack) | functional | -- |

Anything else is unmapped. A host access faults (and the simulation stops
with a diagnostic). An accelerator access gets AXI `DECERR`, which becomes
error cause `BUS`.

**Addresses are identical on both sides.** A pointer to an HBM buffer can be
passed to a kernel unchanged. The scratchpad window exists only inside the
accelerator: every core sees **its own** scratchpad at `SPAD_BASE =
0x2000_0000`, and the host cannot read or write it. Addresses past
`SPAD_KB` KiB in the window give a `BUS` error.

**Coherence:** there are no caches on the data path, but host accesses to HBM
are functional and bypass the AXI port. The rule is simple: the host must not
touch buffers a running kernel uses. Write inputs, then launch, then wait for
`DONE`, then read outputs.

### Simulation control device

| Address | Access | Function |
|---|---|---|
| `0x1100_0000` | W | `PUTCHAR`: append a character to the log (lines appear as `[host] ...`) |
| `0x1100_0004` | W | `EXIT`: end the simulation; the value is the exit code (0 = pass) |
| `0x1100_0008` | R | `CYCLE_LO`: testbench cycle counter, bits 31:0 |
| `0x1100_000C` | R | `CYCLE_HI`: bits 63:32 |
| `0x1100_0010` | RW | `ROI`: 1 = inside the region of interest: the host is timed as a 2 GHz core and its energy is counted ([host-model.md](host-model.md)). Use `roi_begin()` / `roi_end()` |

`crt0.S` writes `main()`'s return value to `EXIT`. These registers exist only
in simulation. On real silicon you would use a UART and a timer instead.

### Where program sections go

[`sw/common/link.ld`](../sw/common/link.ld) places:

| Section | Memory | How to use |
|---|---|---|
| `.text .rodata .data .bss` + stack | host RAM | normal C code and data |
| `.accel.text` | HBM | kernel code (`ACCEL_KERNEL(name)` in a `.S` file) |
| `.hbm.data` | HBM | initialised shared data: `int x[4] HBM_DATA = {...};` |
| `.hbm.bss` | HBM | zero-initialised shared buffers: `bf16_t buf[N] HBM_BUF;` |
| after `.hbm.bss` | HBM | `hbm_alloc(bytes, align)` bump allocator |

The simulator's ELF loader copies every segment to its memory before reset,
so kernels and `.hbm.data` are already in HBM when `main()` starts.

## Accelerator register map (AXI4-Lite)

Offsets from `ACCEL_CSR_BASE` (`0x1000_0000`). All registers are 32 bits and
accessed as whole words (`WSTRB` is ignored). Unmapped reads return 0.
Constants: [`hw/rtl/accel_pkg.sv`](../hw/rtl/accel_pkg.sv) (RTL) and
[`sw/common/accel.h`](../sw/common/accel.h) (software).

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x000` | `ID` | RO | `0xACCE0200`: magic + version 2.0 (multi-core, scratchpads) |
| `0x004` | `CTRL` | WO | bit 0 `START`: launch cores `0 .. CORES-1` at `START_PC` (ignored while busy). Also clears DONE/ERROR. |
| `0x008` | `STATUS` | RO / W1C | bit 0 `BUSY`, bit 1 `DONE`, bit 2 `ERROR`, bits 15:8 `ERR_CAUSE`. Write 1 to bit 1/2 to clear. |
| `0x00C` | `IRQ_EN` | RW | bit 0: drive `irq` while `DONE` or `ERROR` is set |
| `0x010` | `START_PC` | RW | entry point of the kernel (an HBM address) |
| `0x014` | `ERR_PC` | RO | PC of the faulting instruction (first core to fault), or of core 0's final `ecall` |
| `0x018` | `ERR_INSN` | RO | encoding of the faulting instruction (0 for `ebreak`/fetch faults) |
| `0x020` / `0x024` | `CYCLES_LO/HI` | RO | cycles of the current / last run (start until the last core stops) |
| `0x028` / `0x02C` | `INSTRET_LO/HI` | RO | instructions retired in the current / last run, summed over cores |
| `0x030` | `CORES` | RW | number of cores the next `START` launches; writes are clamped to `1 .. NUM_CORES`. Reset value 1 |
| `0x034` | `ERR_CORE` | RO | core that reported `ERR_PC` / `ERR_INSN` |
| `0x040` | `CFG0` | RO | `VLEN` |
| `0x044` | `CFG1` | RO | `{MXU_ROWS, NUM_ACCS, NUM_TREGS, MAT_DIM}`, one byte each (MAT_DIM in bits 7:0) |
| `0x048` | `CFG2` | RO | `{ICACHE_LINES[31:16], HBM_DATA_W[15:0]}` |
| `0x04C` | `CFG3` | RO | `{SPAD_KB[31:16], NUM_MXUS[15:12], NUM_VPUS[11:8], NUM_CORES[7:0]}` |
| `0x080 - 0x09C` | `ARG0 - ARG7` | RW | copied into `a0 - a7` at launch |

Every error sets both `DONE` and `ERROR`. A successful kernel sets only
`DONE`.

### Launch sequence

```c
for (i = 0; i < n; i++) ACCEL[ARG(i)] = args[i];   // accel_launch_cores()
ACCEL[START_PC] = (uint32_t)kernel;
ACCEL[CORES]    = ncores;                           // accel_launch() uses 1
ACCEL[CTRL]     = START;
while (ACCEL[STATUS] & BUSY || !(ACCEL[STATUS] & (DONE|ERROR))) ;   // accel_wait()
```

`accel_wait_irq()` does the same with `IRQ_EN = 1` and the host sleeping in
`wfi`. `accel_run()` / `accel_run_cores()` = launch + wait + print
diagnostics on error.

## Alignment rules (accelerator side, HBM and scratchpad alike)

| Access | Alignment |
|---|---|
| `lw/sw`, `lh/sh`, `lb/sb` | natural (4 / 2 / 1) |
| `vle16` / `vse16` | `VLEN/8` bytes |
| `mld` / `mst` / `msta` base **and** stride | `MAT_DIM*2` bytes |
| kernel code | 4 bytes |

`HBM_BUF` / `HBM_DATA` align to `HBM_ALIGN` = 512 bytes, enough for every
legal configuration up to VLEN = 4096 and MAT_DIM = 256.
