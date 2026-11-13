# Makefile —— 580.178.04 版本
#
# 两类产物：
#   modules : 内核模块（需要内核头文件，必须在本机对应内核上编）
#   tools   : 用户态工具（普通 gcc 即可）
#
# 目标：
#   make            = modules + tools
#   make modules    = polarity_hook.ko / p104_probe.ko / p104_inject.ko
#   make tools      = mclkctl / mclkwatch / clburn
#   make legacy     = p104-set-mem-clock（reserve perfmon，历史成果，已证伪）
#   make abi        = 打印 ABI 指纹
#   make clean
#
# ⚠ 内核模块必须在**目标机**上编。跨机编译会因 clang/gcc、vermagic 不一致失败
#   （实测：本机 82MS 内核是 clang 编的，用 gcc 编模块直接报
#    unrecognized command-line option '-mstack-alignment=8'）。

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)
CC   ?= cc
CFLAGS ?= -O2 -Wall

obj-m += polarity_hook.o
obj-m += p104_probe.o
obj-m += p104_inject.o

MODS = polarity_hook.ko p104_probe.ko p104_inject.ko
TOOLS = mclkctl mclkwatch clburn

all: modules tools
	@echo
	@echo "产物:"
	@for f in $(MODS) $(TOOLS); do [ -f $$f ] && echo "  $$f"; done
	@echo
	@echo "下一步: ./04.deploy.sh  （或通过主入口: p104-switch deploy）"

# ── 内核模块 ──────────────────────────────────────────────────────
modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# ── 用户态工具 ────────────────────────────────────────────────────
tools: $(TOOLS)

mclkctl: mclkctl.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

mclkwatch: mclkwatch.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

clburn: clburn.c
	$(CC) $(CFLAGS) -o $@ $< -lOpenCL

# ── 历史成果：reserve perfmon 工具（通道已验证，极性翻转已证伪）──
#   保留是为了可复现当时的实验，不是推荐用法。
legacy: p104-set-mem-clock

p104-set-mem-clock: p104-set-mem-clock.c abi.h
	$(CC) $(CFLAGS) -o $@ p104-set-mem-clock.c

abi: sizes.c abi.h
	$(CC) $(CFLAGS) -o /tmp/.p104-sizes sizes.c
	@/tmp/.p104-sizes
	@rm -f /tmp/.p104-sizes

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean 2>/dev/null
	rm -f $(TOOLS) p104-set-mem-clock

.PHONY: all modules tools legacy abi clean
