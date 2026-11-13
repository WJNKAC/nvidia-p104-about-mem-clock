obj-m += polarity_hook.o
obj-m += arbhook.o
obj-m += p104_probe.o
obj-m += p104_inject.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
	@echo
	@echo "产物: $(PWD)/polarity_hook.ko"
	@echo "  验证 hook:  sudo insmod polarity_hook.ko && sudo ./phctl mode 2"
	@echo "  自动模式:   sudo ./phctl auto"

# 用户态控制器
ctl: mclkctl.c
	$(CC) $(CFLAGS) -o mclkctl mclkctl.c -ldl
	@echo "  ✓ mclkctl"

# 高频时钟监视（测瞬态寿命，nvidia-smi/nvitop 的 1s 刷新会漏）
watch: mclkwatch.c
	$(CC) $(CFLAGS) -o mclkwatch mclkwatch.c -ldl
	@echo "  ✓ mclkwatch"

tools: ctl watch

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

.PHONY: all clean install ctl watch tools
