#!/bin/bash
# pm1_profile.sh — PM1 稳态画像 + one-shot 判定
#
# 背景（2026-11-13 15:58 实测）：
#   不写 PM1 的情况下，负载刚停止时出现过一次
#       P0 / 1202 MHz / 5005 MHz / 53.33 W
#   持续约 1 秒后回到 P8/139/405。这与 212 号报告的 "P0/1075/5005/53.3W"
#   高度相似 ⇒ 212 的 "PM1 空闲稳态" 可能只是这个瞬态被采到。
#
# 本脚本要回答：
#   Q1 写 PM1 后，是否稳定在 P0/~/5005/~53W（而不是 1 秒瞬态）？
#   Q2 PM1 是持续有效，还是 one-shot（只作用一次 8→0）？
#   Q3 负载期间 MEM 是 405 还是 5005？
#   Q4 空闲 GPC 钳制值到底是 1075 还是 1202（212 里两处不一致）？
#
# 用法: sudo ./pm1_profile.sh
# 输出: out/pm1-<ts>.csv

set -u
A=/data/labs/nvidia/analysis
OUT=/tmp
OUTDIR=$(cd "$(dirname "$0")/../out" 2>/dev/null && pwd || echo /tmp)
TS=$(date +%Y%m%d-%H%M%S)
CSV="$OUT/pm1-$TS.csv"
mkdir -p "$OUT" 2>/dev/null || OUT=/tmp

q() {
    nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}
row() {  # $1=phase
    local v; v=$(q)
    [ -n "$v" ] && echo "$1,$(date +%s),$v" >> "$CSV"
    printf "  %-14s %s\n" "$1" "$(echo "$v" | awk -F, '{printf "%-4s SM=%-5s MEM=%-5s %-7s util=%s%%",$1,$2,$3,$4,$5}')"
}
sample() {  # $1=phase  $2=秒数  $3=间隔
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$end" ]; do row "$1"; sleep "${3:-1}"; done
}

echo "phase,epoch,pstate,sm,mem,power,util" > "$CSV"

echo "════════════════════════════════════════════"
echo " 0 · 前置检查"
echo "════════════════════════════════════════════"
if ! command -v nvidia-settings >/dev/null; then
    echo "✗ 没有 nvidia-settings"; exit 1
fi
CUR=$(nvidia-settings -q "[gpu:0]/GPUPowerMizerMode" -t 2>/dev/null | tr -d ' ')
echo "  当前 GPUPowerMizerMode = ${CUR:-?}"
if [ "${CUR:-0}" != "0" ]; then
    echo "  ⚠ 不是 0，先复位"
    nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=0" >/dev/null 2>&1
    sleep 3
fi
echo

echo "════════════════════════════════════════════"
echo " 1 · P8 基线（30s）"
echo "════════════════════════════════════════════"
sample baseline 30 2
BASE_MEM=$(awk -F, '$1=="baseline"{print $5}' "$CSV" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "  >> 基线 MEM 众数 = $BASE_MEM"
echo

echo "════════════════════════════════════════════"
echo " 2 · 写 PM1，等 5s（纪律：reload 后先等再采）"
echo "════════════════════════════════════════════"
nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1" >/dev/null 2>&1
echo "  已写 PM1，等待 5s…"
sleep 5
echo

echo "════════════════════════════════════════════"
echo " 3 · PM1 空闲稳态（60s，1s 间隔）"
echo "════════════════════════════════════════════"
sample pm1_idle 60 1
echo

echo "════════════════════════════════════════════"
echo " 4 · 第一轮负载（25s，0.5s 间隔，抓 0→8）"
echo "════════════════════════════════════════════"
"$A/clburn" 25 2048 >/dev/null 2>&1 &
LOOP1=$!
sleep 5
sample load1 20 0.5
kill -9 $LOOP1 2>/dev/null; wait $LOOP1 2>/dev/null
echo

echo "════════════════════════════════════════════"
echo " 5 · 负载停止后（30s，0.5s 间隔，抓 8→0 瞬态）"
echo "════════════════════════════════════════════"
sample post1 30 0.5
echo

echo "════════════════════════════════════════════"
echo " 6 · 第二轮负载（25s）—— 判定 one-shot"
echo "════════════════════════════════════════════"
"$A/clburn" 25 2048 >/dev/null 2>&1 &
LOOP2=$!
sleep 5
sample load2 20 0.5
kill -9 $LOOP2 2>/dev/null; wait $LOOP2 2>/dev/null
echo

echo "════════════════════════════════════════════"
echo " 7 · 收尾（20s）+ 复位"
echo "════════════════════════════════════════════"
sample post2 20 1
echo "  复位 GPUPowerMizerMode=0"
nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=0" >/dev/null 2>&1
sleep 3
row final

echo
echo "════════════════════════════════════════════"
echo " 汇总"
echo "════════════════════════════════════════════"
echo " 各阶段 MEM 取值分布:"
awk -F, 'NR>1{print $1"|"$5}' "$CSV" | sort | uniq -c | awk '{printf "   %-14s MEM=%-5s  %s 次\n",substr($2,1,index($2,"|")-1),substr($2,index($2,"|")+1),$1}'
echo
echo " 各阶段 P-State 分布:"
awk -F, 'NR>1{print $1"|"$3}' "$CSV" | sort | uniq -c | awk '{printf "   %-14s %-4s  %s 次\n",substr($2,1,index($2,"|")-1),substr($2,index($2,"|")+1),$1}'
echo
echo " PM1 空闲期 SM 取值（判 1075 vs 1202）:"
awk -F, '$1=="pm1_idle"{print $4}' "$CSV" | sort -n | uniq -c | sort -rn | head -4 | awk '{printf "   SM=%-6s %s 次\n",$2,$1}'
echo
echo " PM1 空闲期 MEM 取值:"
awk -F, '$1=="pm1_idle"{print $5}' "$CSV" | sort -n | uniq -c | sort -rn | head -3 | awk '{printf "   MEM=%-6s %s 次\n",$2,$1}'
echo
cp -f "$CSV" "$OUTDIR"/ 2>/dev/null && echo " 原始数据: $OUTDIR/$(basename "$CSV")" || echo " 原始数据: $CSV"
