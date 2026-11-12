/*
 * link.ld -- linker script for host programs on the simulated platform.
 *
 *   HOST_RAM : host code, data, bss, stack          (host-private)
 *   HBM      : accelerator kernels (.accel.text: the RV32 kernel image built
 *              with kernel.ld, embedded by kernel_blob.S) and shared buffers
 *              (.hbm.data initialised, .hbm.bss zero-initialised)
 *
 * The simulator's ELF loader copies every loadable segment to the right
 * memory, so kernels and initialised HBM data are already in HBM at reset.
 * Keep in sync with memory_map.h.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  HBM      (rwx) : ORIGIN = 0x40000000, LENGTH = 1024M
  HOST_RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}

SECTIONS
{
  /* ---------------- host-private ---------------- */
  .text : {
    *(.text.init)
    *(.text .text.*)
  } > HOST_RAM

  .rodata : ALIGN(8) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > HOST_RAM

  .data : ALIGN(8) {
    *(.data .data.* .sdata .sdata.*)
  } > HOST_RAM

  .bss (NOLOAD) : ALIGN(8) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(8);
    __bss_end = .;
  } > HOST_RAM

  _stack_top = ORIGIN(HOST_RAM) + LENGTH(HOST_RAM);

  /* ---------------- shared HBM ---------------- */
  .accel.text : ALIGN(64) {
    __accel_text_start = .;
    *(.accel.text .accel.text.*)
    __accel_text_end = .;
  } > HBM

  .hbm.data : ALIGN(64) {
    *(.hbm.data .hbm.data.*)
  } > HBM

  .hbm.bss (NOLOAD) : ALIGN(64) {
    *(.hbm.bss .hbm.bss.*)
  } > HBM

  ASSERT(__accel_text_start == ORIGIN(HBM), "the kernel image must be the first thing in HBM (see kernel.ld)")

  /* first free HBM address, for hbm_alloc() */
  __hbm_free_start = ALIGN(4096);

  /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) }
}
