# Builds every program into build/sw/<name>/<name>.{elf,bin,hex,dis}.
#   make -C sw              all ISA tests and C programs
#   make -C sw isa | c      one group
#   make -C sw hello        one program
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

ISA_PROGS = $(basename $(notdir $(wildcard $(SW)/isa/*.S)))
C_PROGS   = $(basename $(notdir $(wildcard $(SW)/c/*.c)))

.PHONY: all isa c asm clean $(ISA_PROGS) $(C_PROGS)
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
FORCE:

clean:
	rm -rf $(BUILD)
