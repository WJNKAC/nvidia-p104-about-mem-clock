#!/bin/bash
# perfmon_gate.sh —— 判决实验：405 是"硬件审查"还是"软件 limit 树"
#
# 核心问题（用户提出）：如果 PMU 真的严苛审查电压/时序，
# 为什么一句 `MaxPerfWithPerfMon=0` 就能让 MCLK 到 5005？
#
# 若答案是"限制纯粹是软件策略"，则：
#   · 硬件对任意写入值都接受（实测写 3000000 → 真跑到 2999 MHz）
#   · 405 来自 RM 里一棵"依赖 util 把 range 压成单点"的 limit 树
#   · PERFMON_ENABLED 就是那棵树的开关
#
# 本实验唯一的变量 = PERFMON_ENABLED，其余全相同。
#
# ⚠ dump 的抓取纪律（踩过的坑）：
#   `_nv050524rm` 只在 P-State 切换期被调用，稳态负载期 calls 是冻结的。
#   所以必须在**起负载之前**就挂上 dump 请求，且 dump_n 要够大，
#   才能覆盖升档那十几次调用。事后 echo dump 只会抓到下一次空闲仲裁。
set -u
PH=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
S_ARB=/sys/kernel/p104_arb
CLB=/home/union/p104-probe-clburn
cd "$PH" || exit 1

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

q()  { nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw --format=csv,noheader; }
bw() { local B; B=$( { "$CLB" 10 triad 2>&1 | tail -1; } ); echo "${B##*BANDWIDTH = }"; }

# 正确的抓法：先挂请求 + 设够大的 dump_n，再起负载，最后读
probe_load() {   # probe_load <标签>
    local tag=$1
    echo 24 > "$S_ARB/dump_n" 2>/dev/null
    echo 1  > "$S_ARB/dump"   2>/dev/null
    "$CLB" 10 triad >/dev/null 2>&1 &
    local cb=$!
    sleep 4
    echo "      负载态: $(q)"
    wait $cb 2>/dev/null
    echo "      ── 升档期间逐次仲裁（mclk 那列才是关键）──"
    grep mclk "$S_ARB/dump" 2>/dev/null | head -10 | sed 's/^/        /'
}

echo "════ 准备 ════"
rmmod polarity_hook 2>/dev/null; rmmod arbhook 2>/dev/null; sleep 1
insmod arbhook.ko || { echo "arbhook 失败"; exit 1; }
echo 0 > "$S_ARB/mode"

echo
echo "════════ A 组：PERFMON_ENABLED = 1（默认）════════"
sleep 22
echo "  [A1] 空闲: $(q)"
echo 8 > "$S_ARB/dump_n"; echo 1 > "$S_ARB/dump"; sleep 3
echo "      空闲 range:"; grep mclk "$S_ARB/dump" | head -3 | sed 's/^/        /'
echo "  [A2] 负载:"
probe_load A
echo "      带宽: $(bw)"
sleep 22

echo
echo "════════ B 组：清 PERFMON_ENABLED（方案 A 的运行时版）════════"
insmod polarity_hook.ko || { echo "polarity_hook 失败"; exit 1; }
sleep 1
# ⚠ 语义核对过：mode 2 = MODE_FORCE_MAX（1 反而是 FORCE_MIN）；
#   override -1=不覆盖 / 0=强制max / 1=强制min。这里一律用 mode=2 + override=0。
echo 2 > /sys/kernel/p104_polarity/mode 2>/dev/null
echo 0 > /sys/kernel/p104_polarity/override 2>/dev/null
echo "  已清 ENABLED（mode=2 FORCE_MAX, override=0）"
echo "  ⚠ 运行时清 flag 需要一次 changeseq 才生效，先跑一次负载催化"
"$CLB" 6 triad >/dev/null 2>&1
sleep 8
echo "  [B1] 催化后空闲: $(q)"
echo "      stat: $(grep -E '^flags_off|^keepalive' /sys/kernel/p104_polarity/stat 2>/dev/null | tr '\n' ' ')"
echo 8 > "$S_ARB/dump_n"; echo 1 > "$S_ARB/dump"; sleep 3
echo "      空闲 range:"; grep mclk "$S_ARB/dump" | head -3 | sed 's/^/        /'
echo "  [B2] 负载:"
probe_load B
echo "      带宽: $(bw)"

echo
echo "════ 收尾 ════"
rmmod polarity_hook 2>/dev/null && echo "  polarity_hook 已卸"
rmmod arbhook 2>/dev/null && echo "  arbhook 已卸"
sleep 3
echo "  $(q)"
