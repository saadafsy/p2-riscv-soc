// Shared macros for the core test programs. gp holds the current test number;
// the program writes 0 (pass) or that number to SIM_EXIT.
#define SIM_EXIT 0x1000F000
#define SIM_IRQ  0x1000F010
#define DATA     0x8000

#define TEST(n)       li gp, n
#define CHECK(r, v)   li t6, v; bne r, t6, fail

#define START         .section .text; .globl _start; _start: li gp, 0

#define END_TESTS \
  li gp, 0; \
fail: \
  li t5, SIM_EXIT; \
  sw gp, 0(t5); \
halt: \
  j halt
