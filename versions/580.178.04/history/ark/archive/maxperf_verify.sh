#!/bin/bash
# maxperf_verify.sh — 方案 A（MaxPerfWithPerfMon=0）重启后验证
#
# 判据表（先看这张表再看数据）：
#   空闲 mem = 5005   → PERFMON_ENABLED 已被清零 ⇒ 极性恒 FALSE ⇒ 方案 A 已生效
#   空闲 mem = 405    → 键未被读到（regkey 拼写/位置/覆盖）⇒ 方案 A 未生效
#   负载 mem = 5005   → 修复成功
#   负载 mem = 405    → range.maxValue 被某条 limit 压住 ⇒ 转方案 C（guard）
#
# 用法: ./maxperf_verify.sh [轮数] [每轮秒数]
# 输出: ./out/maxperf_<ts>.csv  +  终端摘要

set -u
A=/data/labs/nvidia/analysis
CL=$A/clburn
ROUNDS=${1:-5}
SECS=${2:-25}
TS=$(date +%Y%m%d-%H%M%S)
OUT=$A/out
mkdir -p "$OUT"
CSV=$OUT/maxperf_$TS.csv

q() { nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw,utilization.gpu,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' '; }

echo "phase,round,t_sec,pstate,sm_mhz,mem_mhz,power_w,util_pct,temp_c" > "$CSV"

# ---------- 阶段 0：空闲基线 ----------
echo "=============================================="
echo " 阶段 0 · 空闲基线（10 秒）"
echo "=============================================="
printf "  %-3s %-6s %-6s %-6s %-7s %-5s\n" "#" "PState" "SM" "MEM" "Power" "Util"
i=0
while [ $i -lt 10 ]; do
  v=$(q); [ -z "$v" ] && { echo "  nvidia-smi 无输出，中止"; exit 1; }
  echo "idle,$i,$i,$v" >> "$CSV"
  printf "  %-3s %s\n" "$i" "$(echo "$v" | awk -F, '{printf "%-6s %-6s %-6s %-7s %-5s",$1,$2,$3,$4,$5}')"
  i=$((i+1)); sleep 1
done

IDLE_MEM=$(awk -F, '$1=="idle"{print $6}' "$CSV" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
IDLE_SM=$(awk -F, '$1=="idle"{print $5}' "$CSV" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
IDLE_PW=$(awk -F, '$1=="idle"{s+=$7;n++}END{if(n)printf "%.2f",s/n}' "$CSV")
echo
echo "  >> 空闲众数: SM=${IDLE_SM} MHz  MEM=${IDLE_MEM} MHz  平均功耗=${IDLE_PW} W"
if [ "$IDLE_MEM" = "5005" ]; then
  echo "  >> 判定: ✅ PERFMON_ENABLED=0（极性恒 FALSE），方案 A 已生效"
else
  echo "  >> 判定: ⚠ MEM 非 5005 —— 键可能未生效，仍需看负载阶段"
fi

# ---------- 阶段 1：多循环负载 ----------
echo
echo "=============================================="
echo " 阶段 1 · 多循环负载（${ROUNDS} 轮 × ${SECS}s，FMA + triad 交替）"
echo "=============================================="
pkill -9 -x clburn 2>/dev/null
sleep 2
R=1
while [ $R -le $ROUNDS ]; do
  if [ $((R % 2)) -eq 1 ]; then MODE="fma"; ARGS="$SECS 2048"
  else MODE="triad"; ARGS="$SECS triad 512"; fi
  echo "--- 轮 $R/$ROUNDS · $MODE ---"
  $CL $ARGS >/dev/null 2>&1 &
  CPID=$!
  sleep 6                      # 给升频留出时间，避开切换瞬态
  j=0
  while [ $j -lt 6 ]; do
    v=$(q)
    echo "load,$R,$j,$v" >> "$CSV"
    printf "   t+%-2ss %s\n" "$((6+j*2))" "$(echo "$v" | awk -F, '{printf "%-5s SM=%-6s MEM=%-6s %-6sW util=%-4s %sC",$1,$2,$3,$4,$5,$6}')"
    j=$((j+1)); sleep 2
  done
  kill -9 $CPID 2>/dev/null; wait $CPID 2>/dev/null
  sleep 4
  R=$((R+1))
done

# ---------- 汇总 ----------
echo
echo "=============================================="
echo " 汇总"
echo "=============================================="
echo " 空闲:  SM=${IDLE_SM}  MEM=${IDLE_MEM}  功耗=${IDLE_PW} W"
echo
echo " 负载中各轮 MEM 取值分布:"
awk -F, '$1=="load"{print "轮"$2": "$6}' "$CSV" | sort | uniq -c | sort -k2 | sed 's/^/   /'
echo
echo " 负载中各轮 SM 取值分布:"
awk -F, '$1=="load"{print "轮"$2": "$5}' "$CSV" | sort | uniq -c | sort -k2 | sed 's/^/   /'
echo
LOAD_MEM_5005=$(awk -F, '$1=="load" && $6==5005' "$CSV" | wc -l)
LOAD_MEM_TOT=$(awk -F, '$1=="load"' "$CSV" | wc -l)
LOAD_MEM_405=$(awk -F, '$1=="load" && $6==405' "$CSV" | wc -l)
LOAD_PW=$(awk -F, '$1=="load"{s+=$7;n++}END{if(n)printf "%.1f",s/n}' "$CSV")
LOAD_SM_MAX=$(awk -F, '$1=="load"{if($5>m)m=$5}END{print m}' "$CSV")

echo " 负载样本: 共 ${LOAD_MEM_TOT}，MEM=5005 有 ${LOAD_MEM_5005}，MEM=405 有 ${LOAD_MEM_405}"
echo " 负载平均功耗: ${LOAD_PW} W    负载 SM 最高: ${LOAD_SM_MAX} MHz"
echo
if [ "$LOAD_MEM_5005" -eq "$LOAD_MEM_TOT" ] && [ "$LOAD_MEM_TOT" -gt 0 ]; then
  echo " ✅ 负载下 MEM 全程 5005 —— 方案 A 修复成功"
elif [ "$LOAD_MEM_405" -gt 0 ]; then
  echo " ❌ 负载下仍出现 405 —— range.maxValue 被压，需转方案 C"
else
  echo " ⚠ 混合 —— 存在切换瞬态，需看逐轮明细"
fi
echo
echo " PCIe: gen=$(nvidia-smi --query-gpu=pcie.link.gen.current --format=csv,noheader) width=$(nvidia-smi --query-gpu=pcie.link.width.current --format=csv,noheader)  (应仍为 2 / 4)"
echo " 原始数据: $CSV"
