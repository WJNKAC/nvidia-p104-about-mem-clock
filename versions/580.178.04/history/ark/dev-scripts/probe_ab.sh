#!/bin/bash
# probe_ab.sh —— A/B 对比：同一个负载，唯一变量 = PERFMON_ENABLED
# 目的：看哪些函数的调用次数在两种状态下不同 ⇒ 那就是锁时钟路径
set -u
P=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
S=/sys/kernel/p104_polarity
SYS=/sys/kernel/p104_probe
CLB=/home/union/p104-probe-clburn

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

q() { nvidia-smi --query-gpu=pstate,clocks.mem --format=csv,noheader | tr -d ' '; }
bw() { local B; B=$( { "$CLB" 8 triad 2>&1 | tail -1; } ); echo "${B##*BANDWIDTH = }"; }

# 加载探针（纯计数，安全）
rmmod p104_probe 2>/dev/null
insmod "$P/p104_probe.ko" || { echo "探针装载失败"; exit 1; }
sleep 1
echo "探针已挂："; cat "$SYS/stat" | sed 's/^/    /'

run_set() {  # run_set <标签> <bit0目标: 1|0>
    local tag=$1 v=$2
    echo
    echo "════════ $tag （bit0=$v）════════"
    echo 0 > "$SYS/stat"        # 清零
    local b m
    b=$(bw); m=$(q)
    echo "    载荷: $(nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader)"
    echo "    带宽: $b"
    echo "    ── 计数 ──"
    cat "$SYS/stat" | sed 's/^/      /'
}

# ---- 先确保空闲 ----
if [ -e "$S/override" ]; then echo 2 > "$S/override"; fi
"$CLB" 3 triad >/dev/null 2>&1
sleep 8

# ===== A 组：bit0 = 1（默认，MCLK 会被压 405）=====
rmmod polarity_hook 2>/dev/null
sleep 2
run_set "A 组：PERFMON_ENABLED=1" 1

sleep 12

# ===== B 组：bit0 = 0（MCLK 5005）=====
insmod "$P/polarity_hook.ko" || { echo "polarity_hook 失败"; exit 1; }
sleep 1
echo 0 > "$S/override"
sleep 1
run_set "B 组：PERFMON_ENABLED=0" 0

# ===== 收尾 =====
echo
echo "════ 收尾 ════"
echo 2 > "$S/override" 2>/dev/null
"$CLB" 3 triad >/dev/null 2>&1
sleep 8
rmmod polarity_hook 2>/dev/null && echo "  polarity_hook 已卸"
rmmod p104_probe 2>/dev/null && echo "  探针已卸"
echo "  $(nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader)"
