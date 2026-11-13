# Documentation

| Document | Read it when you want to... |
|---|---|
| [project-guide.md](project-guide.md) | plan the project: what is fixed, milestones from the empty shell to a scored design, optimization ideas |
| [architecture.md](architecture.md) | understand the hardware blocks, execution model and performance |
| [isa.md](isa.md) | look up an instruction, its encoding or the error codes |
| [writing-kernels.md](writing-kernels.md) | write a kernel and a host program, and debug them |
| [memory-formats.md](memory-formats.md) | store large matrices (row-major, column-major, blocked) |
| [numerics.md](numerics.md) | know exactly what bits a bf16 operation produces |
| [memory-map.md](memory-map.md) | find an address, a register or an alignment rule |
| [simulation.md](simulation.md) | know what the simulator models, and every plusarg and make knob |
| [competition.md](competition.md) | know the rules: limits in `competition.json`, result tolerance, and how the score is computed |
| [host-model.md](host-model.md) | understand how host CPU time and energy are measured, the region of interest, and the host link delay |
| [parameters.md](parameters.md) | change VLEN, MAT_DIM, ... and see what it costs |
| [synthesis.md](synthesis.md) | run Design Compiler and read the reports |
| [sram.md](sram.md) | understand the scratchpad SRAM: the macro generator, its model, the wrapper |
| [design-decisions.md](design-decisions.md) | see why things are the way they are (MMIO vs custom instructions, SRAM, ...) |

Source-of-truth files (the docs describe them, and the code wins if they
disagree. Please fix the doc):

* `hw/rtl/accel_pkg.sv`: encodings, register offsets, error codes
* `sw/common/accel_isa.h`: assembler syntax
* `sw/common/bf16.h`: numerics
* `sw/common/memory_map.h`: addresses
* `hw/sram/sram_gen.py` (catalog) and `hw/rtl/accel_sram_1rw.sv`: SRAM macro sizes
