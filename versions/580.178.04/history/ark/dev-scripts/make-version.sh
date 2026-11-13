#!/bin/bash
# make-version.sh — 派生一个新版本目录
#
# 每个 versions/<版本号>/ 都是**自包含**的：进去 make 就能出可执行文件，
# 不依赖上级目录。版本之间的差异只允许出现在 src/abi.h（以及 VERSION/README）。
#
# 用法：
#   ./make-version.sh 590.48.01              # 新版本，abi.h 用模板（需自己填）
#   ./make-version.sh 590.48.01 --from 580.178.04   # 以某版本为起点复制 abi.h
#   ./make-version.sh 580.178.04 --force     # 覆盖已存在（abi.h 会保留）

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VERDIR="$ROOT/versions"

VER=""
FROM=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
    --from)  FROM="$2"; shift 2 ;;
    --force) FORCE=1;  shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VER="$1"; shift ;;
    esac
done

if [ -z "$VER" ]; then
    echo "用法: $0 <版本号> [--from <已有版本>] [--force]" >&2
    echo "现有版本: $(ls -1 "$VERDIR" 2>/dev/null | grep -v '^_' | tr '\n' ' ')" >&2
    exit 2
fi

DEST="$VERDIR/$VER"

if [ -d "$DEST" ] && [ "$FORCE" -eq 0 ]; then
    echo "✗ $DEST 已存在（用 --force 覆盖，abi.h 会被保留）" >&2
    exit 1
fi

mkdir -p "$DEST/src" "$DEST/scripts" "$DEST/bin"

# ── 1. 共享源码（从 master src/ 拷，不含 abi.h）──
echo "── 拷贝共享源码 ──"
for f in p104-set-mem-clock.c sizes.c; do
    cp -f "$ROOT/src/$f" "$DEST/src/$f"
    echo "  src/$f"
done

# ── 2. abi.h：已存在就保留，否则从 --from 或模板生成 ──
if [ -f "$DEST/src/abi.h" ]; then
    echo "── 保留已有 src/abi.h ──"
elif [ -n "$FROM" ] && [ -f "$VERDIR/$FROM/src/abi.h" ]; then
    cp -f "$VERDIR/$FROM/src/abi.h" "$DEST/src/abi.h"
    # 自动改版本标识，否则新版本的二进制会打印 $FROM 的版本号（误导性极强）
    sed -i "s/^\(#define P104_ABI_DRIVER\).*/\1      \"$VER\"/" "$DEST/src/abi.h"
    sed -i "s/^\(#define P104_ABI_NOTE\).*/\1        \"TODO 从 $FROM 继承，须按本版本核对\"/" "$DEST/src/abi.h"
    echo "── src/abi.h ← 复制自 $FROM（版本标识已改为 $VER；**常量必须重新核对**）──"
else
    cp -f "$VERDIR/_template/src/abi.h" "$DEST/src/abi.h"
    echo "── src/abi.h ← 模板（含 TODO，必须填）──"
fi

# ── 3. 脚本 ──
echo "── 拷贝脚本 ──"
for f in "$ROOT"/scripts/*.sh; do
    b=$(basename "$f")
    [ "$b" = "make-version.sh" ] && continue
    [ "$b" = "sync-versions.sh" ] && continue
    cp -f "$f" "$DEST/scripts/$b"
    chmod +x "$DEST/scripts/$b"
    echo "  scripts/$b"
done

# ── 4. 版本内的 Makefile（在 src 里 make，产物落到 ../bin）──
cat > "$DEST/Makefile" <<'MK'
# 版本内构建：产物落在 ./bin/
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11
TARGET   = bin/p104-set-mem-clock
SRC      = src/p104-set-mem-clock.c

all: $(TARGET)

$(TARGET): $(SRC) src/abi.h
	@mkdir -p bin
	$(CC) $(CFLAGS) -Isrc -o $@ $(SRC)
	@echo
	@echo "构建完成: $(CURDIR)/$(TARGET)"
	@./$(TARGET) --help 2>/dev/null | head -1 || true

# 打印 ABI 指纹 —— 部署前必看，确认这份二进制对应哪套常量
abi: src/sizes.c $(SRC) src/abi.h
	@mkdir -p bin
	$(CC) -O0 -w -Isrc -o bin/sizes src/sizes.c
	@./bin/sizes

clean:
	rm -f bin/p104-set-mem-clock bin/sizes

.PHONY: all abi clean
MK

# ── 5. VERSION 元数据 ──
if [ ! -f "$DEST/VERSION" ]; then
    cat > "$DEST/VERSION" <<EOF
# 版本元数据 —— 安装到设备后请把实测值补全
version=$VER
status=unverified

# 驱动与内核
driver_version=$VER
kernel_verified=
gpu=

# ABI 指纹（make abi 可打印实际值，务必与这里核对）
abi_nvos64_bytes=
abi_nvos54_bytes=
cmd_reserve_perfmon=
ioctl_rm_alloc=
ioctl_rm_control=
need_open_gpu_node=

# 验证进度
verify_client=
verify_reserve=
verify_polarity_flip=
verified_date=
EOF
    echo "── 已生成 VERSION（字段待填）──"
fi

# ── 6. README ──
if [ ! -f "$DEST/README.md" ]; then
    cat > "$DEST/README.md" <<EOF
# $VER

> 状态：**未验证** —— 请按下面的清单逐项填完再改这一行。

## 构建

\`\`\`bash
make abi        # 先看 ABI 指纹
make            # 产出 bin/p104-set-mem-clock
sudo ./bin/p104-set-mem-clock --probe
\`\`\`

## 适配清单

- [ ] \`src/abi.h\` 里的 ABI 常量按本版本重新核对（见下）
- [ ] \`make abi\` 的 \`sizeof(NVOS64)\` 与 \`strace\` 观测一致
- [ ] \`--probe\` 能拿到三级 handle（subdevice ≠ 0）
- [ ] \`perfmon acquire\` 返回 NV_OK
- [ ] 独占互斥：A 持有时 B 拿 \`0x63\`
- [ ] 极性翻转：405 → 5005 → 405（需先清掉 \`MaxPerfWithPerfMon\`）

## 怎么核对 ABI

\`\`\`bash
# 1) alloc / control 的结构体字节数
strace -f -e trace=ioctl -o /tmp/smi.trace nvidia-smi -q -d PERFORMANCE
grep -E "0x46, 0x2[ab]" /tmp/smi.trace
#   0x2b(alloc)   的 size → abi_nvos64_bytes
#   0x2a(control) 的 size → abi_nvos54_bytes

# 2) 命令号：该版本 resman 源码的 ctrl2080perf.h
grep -n "NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW" ctrl2080perf.h

# 3) 是否要先 open GPU 节点：把 abi.h 的 ABI_NEED_OPEN_GPU_NODE 置 0 试，
#    若 alloc device 报 0x1B 就说明本版本需要它
\`\`\`

## 实测记录

（填这里：日期 / 设备 / 内核 / 观察到的现象）
EOF
    echo "── 已生成 README.md（待填）──"
fi

echo
echo "✓ 完成：$DEST"
echo "  下一步："
echo "    1) 编辑 $DEST/src/abi.h     ← 关键"
echo "    2) cd $DEST && make abi     ← 核对指纹"
echo "    3) 补 $DEST/VERSION 与 README.md"
