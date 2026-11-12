// kernel_blob.S -- places a test's kernel image (RV32 accelerator code, built
// with kernel.ld) at the start of HBM inside the host program. See sw/sw.mk.
  .section .accel.text, "ax"
  .incbin "kernel.bin"
