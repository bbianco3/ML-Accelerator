// crt0.S -- reset entry point for host programs.
// Sets up the stack and FPU, clears .bss, calls main() and reports main's
// return value to the testbench as the simulation exit code (0 = pass).
#include "memory_map.h"

  .section .text.init, "ax"
  .globl _start
_start:
  la    sp, _stack_top

  // mstatus.FS = Initial (the ISS does not enforce FS, but real cores do)
  li    t0, (1 << 13)
  csrs  mstatus, t0
  csrw  fcsr, zero

  // zero .bss
  la    t0, __bss_start
  la    t1, __bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:
  call  main

  // exit(main())
  li    t0, SIMCTRL_EXIT
  sw    a0, 0(t0)
3:
  j     3b
