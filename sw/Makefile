# Builds every program into build/sw/<name>/<name>.{elf,bin,hex,dis}.
#   make -C sw              all ISA tests and C programs
#   make -C sw isa | c      one group
#   make -C sw hello        one program
#   make -C sw board        attn_test for the Basys 3 (prints on the UART)
#   make -C sw asm SRC=/abs/prog.S NAME=foo   any standalone assembly file
TOOLS  ?= $(HOME)/tools/riscv/bin
CC      = $(TOOLS)/riscv32-unknown-elf-clang
OBJCOPY = $(TOOLS)/riscv32-unknown-elf-objcopy
OBJDUMP = $(TOOLS)/llvm-objdump
PYTHON ?= python3

SW     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT   := $(abspath $(SW)/..)
BUILD  ?= $(ROOT)/build/sw
COMMON := $(SW)/common

MARCH  ?= rv32im_zicsr
ARCH    = -march=$(MARCH) -mabi=ilp32 -mcmodel=medlow -mno-relax
CFLAGS  = $(ARCH) -O2 -g -ffreestanding -fno-builtin -nostdlib -Wall -Wextra -Werror \
          -I$(COMMON)
ASFLAGS = $(ARCH) -g -I$(COMMON) -I$(SW)/isa
LDFLAGS = $(ARCH) -nostdlib -fuse-ld=lld -T$(COMMON)/link.ld -Wl,--no-relax

COMMON_SRC = $(COMMON)/crt0.S $(COMMON)/rt.S $(COMMON)/uart.c $(COMMON)/gpio.c \
             $(COMMON)/timer.c $(COMMON)/printf.c
COMMON_HDR = $(wildcard $(COMMON)/*.h)
# Extra sources per C program (the other programs stay byte-identical).
EXTRA_attn_test = $(COMMON)/accel.c
EXTRA_clkgate_test = $(COMMON)/accel.c

ISA_PROGS = $(basename $(notdir $(wildcard $(SW)/isa/*.S)))
C_PROGS   = $(basename $(notdir $(wildcard $(SW)/c/*.c)))

.PHONY: all isa c asm board speedup clean $(ISA_PROGS) $(C_PROGS)
all: isa c
isa: $(ISA_PROGS)
c: $(C_PROGS)

# elf -> bin (image from address 0), hex ($readmemh, 32-bit words), dis
define PRODUCTS
	$(OBJCOPY) -O binary $@ $(basename $@).bin
	$(PYTHON) $(ROOT)/scripts/bin2hex.py $(basename $@).bin $(basename $@).hex
	$(OBJDUMP) -d -S $@ > $(basename $@).dis
endef

define ISA_RULE
$(1): $(BUILD)/$(1)/$(1).elf
$(BUILD)/$(1)/$(1).elf: $(SW)/isa/$(1).S $(SW)/isa/isa.h $(COMMON)/soc.h $(COMMON)/link.ld
	@mkdir -p $$(dir $$@)
	$$(CC) $$(ASFLAGS) $$(LDFLAGS) -o $$@ $$<
	$$(PRODUCTS)
endef

define C_RULE
$(1): $(BUILD)/$(1)/$(1).elf
$(BUILD)/$(1)/$(1).elf: $(SW)/c/$(1).c $(COMMON_SRC) $(EXTRA_$(1)) $(COMMON_HDR) $(COMMON)/link.ld
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) $$(LDFLAGS) -o $$@ $(COMMON_SRC) $(EXTRA_$(1)) $$<
	$$(PRODUCTS)
endef

$(foreach p,$(ISA_PROGS),$(eval $(call ISA_RULE,$(p))))
$(foreach p,$(C_PROGS),$(eval $(call C_RULE,$(p))))

asm:
	@test -n "$(SRC)" -a -n "$(NAME)" || (echo "usage: make asm SRC=file.S NAME=name"; exit 1)
	@mkdir -p $(BUILD)/$(NAME)
	$(MAKE) -f $(SW)/Makefile $(BUILD)/$(NAME)/$(NAME).elf ASM_SRC=$(abspath $(SRC))

ifdef ASM_SRC
$(BUILD)/$(NAME)/$(NAME).elf: $(ASM_SRC) $(COMMON)/link.ld FORCE
	$(CC) $(ASFLAGS) $(LDFLAGS) -o $@ $<
	$(PRODUCTS)
endif
.PHONY: FORCE

# Accelerator vs software cycle counts (attn_test.c built with -DSPEEDUP).
speedup: $(BUILD)/speedup/speedup.elf
$(BUILD)/speedup/speedup.elf: $(SW)/c/attn_test.c $(COMMON_SRC) $(COMMON)/accel.c $(COMMON_HDR) $(COMMON)/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DSPEEDUP $(LDFLAGS) -o $@ $(COMMON_SRC) $(COMMON)/accel.c $<
	$(PRODUCTS)

# Board firmware for fpga/build.tcl: attn_test with its results on the UART
# (the simulation build prints only to SIMCTRL). -> build/sw/board/board.hex
board: $(BUILD)/board/board.elf
$(BUILD)/board/board.elf: $(SW)/c/attn_test.c $(COMMON_SRC) $(COMMON)/accel.c $(COMMON_HDR) $(COMMON)/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -DBOARD $(LDFLAGS) -o $@ $(COMMON_SRC) $(COMMON)/accel.c $<
	$(PRODUCTS)
FORCE:

# CoreMark (third_party/coremark + coremark/core_portme.*), kept out of build/sw so
# the default lockstep regression does not run it:
#   make -C sw coremark [CM_ITER=2] [MARCH=rv32i_zicsr]
#   -> build/coremark/<MARCH>_it<CM_ITER>/coremark.{elf,bin,hex,dis}
CM_DIR   = $(ROOT)/third_party/coremark
CM_ITER ?= 2
CM_OUT   = $(ROOT)/build/coremark/$(MARCH)_it$(CM_ITER)
CM_SRC   = $(addprefix $(CM_DIR)/,core_list_join.c core_main.c core_matrix.c core_state.c \
             core_util.c) $(SW)/coremark/core_portme.c
CM_OPT   = -O2
CM_FLAGS = $(ARCH) $(CM_OPT) -ffreestanding -nostdlib -I$(SW)/coremark -I$(CM_DIR) -I$(COMMON) \
           -DITERATIONS=$(CM_ITER) -DFLAGS_STR='"$(CM_OPT) -march=$(MARCH)"'

.PHONY: coremark
coremark: $(CM_OUT)/coremark.elf
$(CM_OUT)/coremark.elf: $(CM_SRC) $(SW)/coremark/core_portme.h $(COMMON_SRC) $(COMMON_HDR) \
                        $(COMMON)/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(CM_FLAGS) $(LDFLAGS) -o $@ $(COMMON)/crt0.S $(COMMON)/rt.S $(COMMON)/printf.c \
	  $(COMMON)/uart.c $(CM_SRC)
	$(PRODUCTS)

clean:
	rm -rf $(BUILD)
