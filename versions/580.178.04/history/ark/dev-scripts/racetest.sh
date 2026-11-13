#!/bin/bash
# racetest.sh —— 无模块，连续短负载，统计 MCLK 命中 5005 的比例
# 目的：MCLK 能否上 5005 是**确定性**还是**竞态**？
set -u
CLB=/home/union/p104-probe-clburn
q() { nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits | tr -d ' '; }

echo "======== 无模块，连续 8 次短负载（每次 8s，间隔 30s 静置）========"
echo "  判据：带宽 > 200 GB/s 才算真的 5005"
echo
hit=0; miss=0
for r in $(seq 1 8); do
    sleep 30
    before=$(q)
    B=$( { "$CLB" 8 triad 2>&1 | tail -1; } )
    bw=${B##*BANDWIDTH = }; bw=${bw%% *}
    after=$(q)
    if [ "${bw%.*}" -gt 200 ] 2>/dev/null; then
        hit=$((hit+1)); tag="✓ HIT "
    else
        miss=$((miss+1)); tag="· miss"
    fi
    printf "  第%d次  idle前=%-5s  %s %6s GB/s  idle后=%s\n" \
           "$r" "$before" "$tag" "$bw" "$after"
done
echo
echo "  ── 汇总：命中 $hit / 未命中 $miss （共 8 次）──"
echo "  若全 miss 或全 hit ⇒ 确定性；混合 ⇒ 竞态"
