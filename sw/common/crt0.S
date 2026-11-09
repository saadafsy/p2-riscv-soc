// Startup: sp = top of RAM, clear .bss, mtvec = trap entry, main(), EXIT = return value.
#include "soc.h"

    .section .text.init, "ax"
    .globl _start
_start:
    la    sp, __stack_top
    la    t0, __bss_start
    la    t1, __bss_end
1:  bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b
2:  la    t0, _trap_entry
    csrw  mtvec, t0
    call  main
    li    t0, SIMCTRL_EXIT
    sw    a0, 0(t0)
3:  j     3b

// Saves caller-saved registers, calls trap_handler(mcause, mepc, mtval),
// resumes at the returned pc.
    .balign 4
    .globl _trap_entry
_trap_entry:
    addi  sp, sp, -64
    sw    ra,  0(sp)
    sw    t0,  4(sp)
    sw    t1,  8(sp)
    sw    t2, 12(sp)
    sw    a0, 16(sp)
    sw    a1, 20(sp)
    sw    a2, 24(sp)
    sw    a3, 28(sp)
    sw    a4, 32(sp)
    sw    a5, 36(sp)
    sw    a6, 40(sp)
    sw    a7, 44(sp)
    sw    t3, 48(sp)
    sw    t4, 52(sp)
    sw    t5, 56(sp)
    sw    t6, 60(sp)
    csrr  a0, mcause
    csrr  a1, mepc
    csrr  a2, mtval
    call  trap_handler
    csrw  mepc, a0
    lw    ra,  0(sp)
    lw    t0,  4(sp)
    lw    t1,  8(sp)
    lw    t2, 12(sp)
    lw    a0, 16(sp)
    lw    a1, 20(sp)
    lw    a2, 24(sp)
    lw    a3, 28(sp)
    lw    a4, 32(sp)
    lw    a5, 36(sp)
    lw    a6, 40(sp)
    lw    a7, 44(sp)
    lw    t3, 48(sp)
    lw    t4, 52(sp)
    lw    t5, 56(sp)
    lw    t6, 60(sp)
    addi  sp, sp, 64
    mret

// Default: an unexpected trap ends the run with 0xE000_0000 | mcause[7:0].
    .weak trap_handler
trap_handler:
    andi  a0, a0, 0xFF
    li    t0, 0xE0000000
    or    a0, a0, t0
    li    t0, SIMCTRL_EXIT
    sw    a0, 0(t0)
4:  j     4b
