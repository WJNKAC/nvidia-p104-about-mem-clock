#!/bin/bash
# pm1_repro.sh — 验证「负载停止的 8→0 翻转极性并记忆到下一轮」是否可重复
#
# 背景（2026-11-13 16:06 实测，无 PM1 参与的对照组）：
#   baseline      P8/139/405
#   load1         P0/1911/405      ← 第一轮 405
#   post1         P0/1202/5005/53.5W 约 2.5s，然后 P8/139/405
#   load2         P0/1911/5005     ← 第二轮 5005
#
# 假说 H-MEM：负载停止（1→0 / 8→0）时的仲裁会把极性翻成 max，
#            该极性被"记忆"住，于是**下一轮负载**取 range.max=5005。
#
# 若成立，则：
#   - N 轮连续负载里，第 1 轮 405，第 2..N 轮全 5005
#   - 每轮之间的空闲若足够长把 P-State 拉到 P8 并触发回落，极性可能被重置
#
# 用法: sudo ./pm1_repro.sh [轮数]
# 输出: /tmp/repro-<ts>.csv

set -u
A=/data/labs/nvidia/analysis
ROUNDS=${1:-5}
TS=$(date +%Y%m%d-%H%M%S)
CSV=/tmp/repro-$TS.csv

q() {
    nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}
rec() {
    local v; v=$(q)
    [ -n "$v" ] && echo "$1,$(date +%s),$v" >> "$CSV"
    printf "  %-10s %s\n" "$1" "$(echo "$v" | awk -F, '{printf "%-4s SM=%-5s MEM=%-5s %-7s util=%s%%",$1,$2,$3,$4,$5}')"
}
halt() {  # $1=phase $2=secs $3=interval
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$end" ]; do rec "$1"; sleep "${3:-1}"; done
}

echo "phase,epoch,pstate,sm,mem,power,util" > "$CSV"

echo "════════════════════════════════════════"
echo " 连续 $ROUNDS 轮负载，每轮：负载 20s → 停 12s"
echo " 关注：每轮 load 阶段的 MEM 众数"
echo "════════════════════════════════════════"

echo
echo "── 前置：确保是干净 P8 基线（等 10s）──"
halt pre 10 2
PRE=$(awk -F, '$1=="pre"{print $5}' "$CSV" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "  基线 MEM=$PRE（若已是 5005，说明上次残留，本结果要打折扣）"

for R in $(seq 1 "$ROUNDS"); do
    echo
    echo "── 第 $R 轮 ──"
    "$A/clburn" 20 2048 >/dev/null 2>&1 &
    P=$!
    sleep 5
    halt "load$R" 13 0.5
    kill -9 $P 2>/dev/null; wait $P 2>/dev/null
    # 停 12 秒，用 0.5s 间隔抓 8→0 瞬态
    halt "post$R" 40 0.5
done

echo
echo "════════════════════════════════════════"
echo " 汇总：各轮 MEM 众数（判定核心）"
echo "════════════════════════════════════════"
for R in $(seq 1 "$ROUNDS"); do
    M=$(awk -F, -v p="load$R" '$1==p{print $5}' "$CSV" | sort | uniq -c | sort -rn | head -1)
    N=$(awk -F, -v p="load$R" '$1==p' "$CSV" | wc -l)
    V=$(echo "$M" | awk '{print $2}')
    C=$(echo "$M" | awk '{print $1}')
    printf "  load%-2s  MEM=%-5s  (%s/%s 样本)\n" "$R" "${V:-?}" "${C:-0}" "$N"
done

echo
echo " 各 post 阶段是否出现 5005 瞬态:"
for R in $(seq 1 "$ROUNDS"); do
    C=$(awk -F, -v p="post$R" '$1==p && $5==5005' "$CSV" | wc -l)
    printf "  post%-2s  MEM=5005 出现 %s 次\n" "$R" "$C"
done

echo
echo " 原始数据: $CSV"
cp -f "$CSV" /tmp/repro-latest.csv 2>/dev/null
