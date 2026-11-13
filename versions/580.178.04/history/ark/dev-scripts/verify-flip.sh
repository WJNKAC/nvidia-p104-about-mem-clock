#!/bin/bash
# verify-flip.sh — 验证 p104-set-mem-clock 是否真的翻转了极性
#
# 前提：MaxPerfWithPerfMon=0 已回退且已重启（否则极性本来就恒 max，看不出差异）
#
# 判据：
#   阶段1 空闲        期望 MEM=405
#   阶段2 acquire 后  期望 MEM=5005   ← 核心证据
#   阶段3 release 后  期望 MEM=405    ← 证明可逆
#
# 若阶段1 就是 5005，说明 regkey 没退干净，本次结果无效。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/../src/p104-set-mem-clock"
OUT="$HERE/../out"
mkdir -p "$OUT"
CSV="$OUT/flip-$(date +%Y%m%d-%H%M%S).csv"

[ -x "$BIN" ] || { echo "先 cd src && make" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0" >&2; exit 1; }

q() {
    nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
}

sample() {  # $1=phase  $2=秒数
    local phase=$1 n=$2 i=0
    while [ $i -lt "$n" ]; do
        echo "$phase,$i,$(q)" >> "$CSV"
        printf "  %-12s %s\n" "$phase" "$(q | awk -F, '{printf "%-4s SM=%-5s MEM=%-5s %sW",$1,$2,$3,$4}')"
        i=$((i+1)); sleep 1
    done
}

echo "══════════════════════════════════════════"
echo " 阶段 1 · 基线（应为 405）"
echo "══════════════════════════════════════════"
sample baseline 6
BASE=$(awk -F, '$1=="baseline"{print $5}' "$CSV" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

if [ "$BASE" = "5005" ]; then
    echo
    echo "❌ 基线就是 5005 —— MaxPerfWithPerfMon=0 还没退掉（或未重启）"
    echo "   先跑 sudo ./scripts/revert-regkey.sh"
    echo "   然后用 ./scripts/restart.sh 重启（别用 sudo reboot，也别加 sudo）"
    exit 2
fi

echo
echo "══════════════════════════════════════════"
echo " 阶段 2 · acquire（期望跳到 5005）"
echo "══════════════════════════════════════════"
"$BIN" --seconds 25 > "$OUT/flip-run.log" 2>&1 &
BPID=$!
sleep 5
sample acquired 14

echo
echo "══════════════════════════════════════════"
echo " 阶段 3 · release 后（期望回 405）"
echo "══════════════════════════════════════════"
wait $BPID
sleep 3
sample released 8

echo
echo "══════════════════════════════════════════"
echo " 判定"
echo "══════════════════════════════════════════"
A5005=$(awk -F, '$1=="acquired" && $5==5005' "$CSV" | wc -l)
ATOT=$(awk -F, '$1=="acquired"' "$CSV" | wc -l)
R405=$(awk -F, '$1=="released" && $5==405' "$CSV" | wc -l)
RTOT=$(awk -F, '$1=="released"' "$CSV" | wc -l)

echo "  基线      MEM=$BASE"
echo "  acquire   MEM=5005 的样本 $A5005/$ATOT"
echo "  release   MEM=405  的样本 $R405/$RTOT"
echo

if [ "$A5005" -gt 0 ] && [ "$A5005" -eq "$ATOT" ] && [ "$R405" -gt 0 ]; then
    echo " ✅ 方案 D 成立：acquire → 5005，release → 405，可逆"
    echo "    建议用法：sudo ./scripts/memclock.sh on / off"
elif [ "$A5005" -gt 0 ]; then
    echo " ⚠ 部分生效（可能有切换延迟），看 $CSV 明细"
elif [ "$A5005" -eq 0 ]; then
    echo " ❌ acquire 后仍是 405 —— 极性未被翻转"
    echo "    排查：1) acquire 是否 ok（看 $OUT/flip-run.log）"
    echo "          2) 是否有别的 profiler 占着 perfmon"
    echo "          3) dmesg | tail 看 NVRM 报错"
fi
echo "  原始数据: $CSV"
