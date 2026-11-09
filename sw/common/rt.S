// Minimal runtime: integer multiply/divide helpers that clang calls for * / % when
// built without M (MARCH=rv32i_zicsr), plus memset/memcpy. Written in assembly so the
// compiler cannot turn them back into calls to themselves.
    .text

    .globl __mulsi3
__mulsi3:               // a0 = a0 * a1
    mv    a2, a0
    li    a0, 0
1:  andi  a3, a1, 1
    beqz  a3, 2f
    add   a0, a0, a2
2:  srli  a1, a1, 1
    slli  a2, a2, 1
    bnez  a1, 1b
    ret

    .globl __udivsi3
__udivsi3:              // a0 = a0 / a1 (unsigned); x / 0 = 0xFFFFFFFF
    mv    a2, a1
    mv    a1, a0
    li    a0, -1
    beqz  a2, 5f
    li    a3, 1
    bgeu  a2, a1, 2f
1:  blez  a2, 2f        // stop before the divisor's top bit is shifted out
    slli  a2, a2, 1
    slli  a3, a3, 1
    bgtu  a1, a2, 1b
2:  li    a0, 0
3:  bltu  a1, a2, 4f
    sub   a1, a1, a2
    or    a0, a0, a3
4:  srli  a3, a3, 1
    srli  a2, a2, 1
    bnez  a3, 3b
5:  ret

    .globl __umodsi3
__umodsi3:              // a0 = a0 % a1 (unsigned)
    mv    t0, ra
    jal   __udivsi3
    mv    a0, a1
    jr    t0

    .globl __divsi3
__divsi3:               // a0 = a0 / a1 (signed)
    mv    t1, ra
    xor   t2, a0, a1    // sign of the quotient
    bgez  a0, 1f
    neg   a0, a0
1:  bgez  a1, 2f
    neg   a1, a1
2:  jal   __udivsi3
    bgez  t2, 3f
    neg   a0, a0
3:  jr    t1

    .globl __modsi3
__modsi3:               // a0 = a0 % a1 (signed, sign of the dividend)
    mv    t1, ra
    mv    t2, a0
    bgez  a0, 1f
    neg   a0, a0
1:  bgez  a1, 2f
    neg   a1, a1
2:  jal   __udivsi3
    mv    a0, a1
    bgez  t2, 3f
    neg   a0, a0
3:  jr    t1

    .globl memset
memset:                 // (dst, byte, n) -> dst
    mv    t0, a0
    beqz  a2, 2f
1:  sb    a1, 0(t0)
    addi  t0, t0, 1
    addi  a2, a2, -1
    bnez  a2, 1b
2:  ret

    .globl memcpy
memcpy:                 // (dst, src, n) -> dst
    mv    t0, a0
    beqz  a2, 2f
1:  lbu   t1, 0(a1)
    sb    t1, 0(t0)
    addi  t0, t0, 1
    addi  a1, a1, 1
    addi  a2, a2, -1
    bnez  a2, 1b
2:  ret
