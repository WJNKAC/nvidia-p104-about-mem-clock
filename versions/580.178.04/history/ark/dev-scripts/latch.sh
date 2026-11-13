#!/bin/bash
# latch.sh —— 验证"5005 一旦锁存就长期保持"这个假设
#   若成立 ⇒ 目标态可达，只是需要一个"启动时把它点着"的动作
set -u
CLB=/home/union/p104-probe-clburn
q() { nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw --format=csv,noheader; }
bw() { local B; B=$( { "$CLB" 8 triad 2>&1 | tail -1; } ); echo "${B##*BANDWIDTH = }"; }

echo "======== 阶段 1：反复点火，直到锁存（最多 12 次）========"
latched=0
for r in $(seq 1 12); do
    B=$(bw); V=${B%% *}
    printf "  点火 %2d: %6s GB/s  %s\n" "$r" "$V" "$(q)"
    if [ "${V%.*}" -gt 200 ] 2>/dev/null; then latched=1; echo "  >>> 第 $r 次锁存成功"; break; fi
    sleep 12
done
[ "$latched" = "1" ] || { echo "  12 次全部失败，退出"; exit 1; }

echo
echo "======== 阶段 2：锁存后连续 6 轮 空闲(45s) → 负载 ========"
echo "  期望：空闲回 405/7~8W，负载仍 5005/>200GB/s（若成立即为目标态）"
echo
for R in $(seq 1 6); do
    sleep 45
    I=$(q); B=$(bw); V=${B%% *}; A=$(q)
    if [ "${V%.*}" -gt 200 ] 2>/dev/null; then tag="✓ 保持"; else tag="✗ 掉了"; fi
    printf "  轮%d 空闲 %-38s | %6s GB/s %s\n" "$R" "$I" "$V" "$tag"
    printf "      负载后 %s\n" "$A"
done

echo
echo "======== 阶段 3：长静置 90s，看空闲是否稳定在 405 ========"
sleep 90
q
