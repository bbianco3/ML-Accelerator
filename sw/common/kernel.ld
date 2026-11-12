/*
 * kernel.ld -- linker script for the accelerator kernels of one test.
 *
 * Kernels are a separate RV32 program: every *.S file of a test is assembled
 * for the accelerator's control core and linked here into one image that
 * starts at the bottom of HBM. sw/sw.mk then embeds that image in the host
 * program (kernel_blob.S) and hands the kernels' global symbols to the host
 * link, so main.c can say `extern const char my_kernel[];`.
 * Keep the origin in sync with HBM_BASE (memory_map.h) and link.ld.
 */
OUTPUT_ARCH(riscv)
ENTRY(__kernel_image_start)

SECTIONS
{
  . = 0x40000000;
  .accel.text : {
    __kernel_image_start = .;
    *(.accel.text .accel.text.*)
    *(.text .text.*)
    . = ALIGN(64);
    *(.rodata .rodata.* .srodata .srodata.* .data .data.* .sdata .sdata.*)
    *(.hbm.data .hbm.data.*)
    *(.bss .bss.* .sbss .sbss.* COMMON .hbm.bss .hbm.bss.*)
    . = ALIGN(64);
    __kernel_image_end = .;
  }
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) }
}
