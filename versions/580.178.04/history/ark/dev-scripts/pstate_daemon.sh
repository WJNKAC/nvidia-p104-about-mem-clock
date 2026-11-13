#!/bin/bash
# pstate_daemon.sh —— 用 P-State 作判据驱动 polarity_hook 的 MODE_AUTO
#
# 为什么不用 utilization 作判据：
#   MODE_AUTO 一旦清掉 PERFMON_ENABLED，perfmon 停摆 ⇒ NVML util 恒为 0
#   ⇒ 判据自毁，永远回不到"不忙"。这正是一切 util 判据方案失败的根因。
#
# 为什么 P-State 可靠：
#   P0/P8 由 SM（GPC）侧决定，与 MCLK / perfmon 无关，清 flag 后仍然准确。
#
# 机理（本轮实测）：
#   ENABLED=1 → MCLK 被"perfmon 测量期锁时钟"钉在 405（硬件不跟随任何目标值）
#   ENABLED=0 → 锁解除   → MCLK 跟随 curValueToSet
#   两者 range/cur 完全相同（都是 [5005,5005] / c5005000），差别只在锁。
set -u
S=/sys/kernel/p104_polarity
PH=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
PIDF=/run/p104-pstate.pid
IV=${IV:-300}          # 轮询间隔 ms
WIN=${WIN:-4000}       # busy 窗口 ms

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }
[ -e "$S/mode" ] || { echo "polarity_hook 未加载"; exit 1; }

case "${1:-run}" in
stop)
    [ -f "$PIDF" ] && kill -TERM "$(cat "$PIDF")" 2>/dev/null && rm -f "$PIDF"
    echo 0 > "$S/mode" 2>/dev/null
    echo "已停止"; exit 0 ;;
esac

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "已在运行 pid $(cat "$PIDF")"; exit 1
fi

echo "$WIN" > "$S/busy_window_ms" 2>/dev/null
echo 3 > "$S/mode"        # MODE_AUTO
echo $$ > "$PIDF"
trap 'echo 0 > '"$S"'/mode 2>/dev/null; rm -f '"$PIDF"'; exit 0' TERM INT

echo "启动：P-State 判据，轮询 ${IV}ms，busy 窗口 ${WIN}ms"
was=""
while :; do
    ps=$(nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null | tr -d ' ')
    case "$ps" in
        P0|P1|P2|P3)
            echo 1 > "$S/busy" 2>/dev/null
            cur="busy" ;;
        *)
            cur="idle" ;;
    esac
    if [ "$cur" != "$was" ]; then
        printf "[%s] pstate=%-3s → %s   %s\n" "$(date +%H:%M:%S)" "$ps" "$cur" \
               "$(nvidia-smi --query-gpu=clocks.mem,power.draw --format=csv,noheader | tr -d ' ')"
        was="$cur"
    fi
    sleep "$(awk "BEGIN{print $IV/1000}")"
done
