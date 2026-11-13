#!/bin/bash
# probe_ab3.sh —— A/B 计数对比（v3：保证 B 组真生效）
#
# 关键修正：用 p104-switch on 的完整逻辑（回 P8 → 清 flag → 长负载，带重试）
# 确保 B 组真的到 5005，否则 A/B 不可比。
set -u
P=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
S=/sys/kernel/p104_polarity
SYS=/sys/kernel/p104_probe
CLB=/home/union/p104-probe-clburn
SW=/home/union/.local/bin/p104-switch

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

q()  { nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader; }
mem(){ nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits | tr -d ' '; }
bw() { local B; B=$( { "$CLB" 10 triad 2>&1 | tail -1; } ); echo "${B##*BANDWIDTH = }"; }

snap() { echo "    ── 计数 ──"; cat "$SYS/stat" | sed 's/^/      /'; }

rmmod p104_probe 2>/dev/null
insmod "$P/p104_probe.ko" || { echo "探针失败"; exit 1; }
sleep 1
echo "探针:"; cat "$SYS/stat" | sed 's/^/    /'

# ───── A 组：bit0=1 ─────
echo
echo "════════ A 组：PERFMON_ENABLED=1 ════════"
rmmod polarity_hook 2>/dev/null
"$CLB" 3 triad >/dev/null 2>&1
sleep 10
echo "    起点: $(q)"
echo 0 > "$SYS/stat"
echo "    带宽: $(bw)"
echo "    结果: $(q)"
snap

sleep 14

# ───── B 组：bit0=0，用 p104-switch 确保生效 ─────
echo
echo "════════ B 组：PERFMON_ENABLED=0 ════════"
if [ -x "$SW" ]; then
    P104_RETRY=5 P104_LOAD_SECS=10 "$SW" on 2>&1 | grep -E "✓|✗|MCLK" | sed 's/^/    /'
else
    insmod "$P/polarity_hook.ko"; sleep 1; echo 2 > "$S/override"
    "$CLB" 4 triad >/dev/null 2>&1; sleep 6
    echo 0 > "$S/override"; "$CLB" 10 triad >/dev/null 2>&1
fi
sleep 3
A=$(mem)
echo "    bit0=0 后: $(q)   (mem=$A)"
echo 0 > "$SYS/stat"
echo "    带宽: $(bw)"
echo "    结果: $(q)"
snap

# ───── 收尾 ─────
echo
echo "════ 收尾 ════"
if [ -x "$SW" ]; then P104_NO_SUDO=1 "$SW" off 2>&1 | grep -E "✓|✗" | sed 's/^/    /'; fi
rmmod polarity_hook 2>/dev/null
rmmod p104_probe 2>/dev/null
sleep 10
echo "    $(q)"
