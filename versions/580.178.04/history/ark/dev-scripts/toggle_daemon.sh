#!/bin/bash
# toggle_daemon.sh — 利用「toggle 窗口」实现 负载 5005 / 空闲 405
#
# ── 背景（2026-11-13 实测，必读）─────────────────────────────────
#
# 单独"清 PERFMON_ENABLED"或单独"改极性返回值"**都不能**让 MCLK 上 5005，
# 因为 MCLK 的 range 被 util 驱动的 limit 压成了单点 [405,405]。
#
# 但实测发现一个有效动作，称为 **toggle**：
#
#     清 PERFMON_ENABLED → 等几秒 → 恢复 ENABLED
#
# 恢复的那一刻，perfmon 重启、range 被放开，MCLK 真的上 5005：
#     带宽 18.8 → 263~271 GB/s，负载中 P0/1911/5005
#
# ⚠ 这个窗口**只维持 < 90 秒**（实测 T+1min 就退回 17.9）。
#
# 所以本脚本的做法：**周期性 toggle**，让窗口持续重叠。
#   每 TOGGLE_INTERVAL 秒做一次：mode 2 → 等 3s → mode 0
#
# ── 代价 ─────────────────────────────────────────────────────────
#   toggle 期间 perfmon 停摆 ⇒ NVML utilization 会短暂为 0
#   toggle 本身很轻（两次 sysfs 写），但会让 perfmon 反复重启
#
# 用法:
#   sudo ./toggle_daemon.sh            # 每 45 秒 toggle 一次
#   sudo ./toggle_daemon.sh 30         # 自定义间隔
#   sudo ./toggle_daemon.sh stop       # 停止

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PH=$HERE/../src/polarity-hook/phctl
SYS=/sys/kernel/p104_polarity
PIDF=/run/p104-phd.pid
LOG=/run/p104-phd.log

if [ "${1:-}" = "stop" ]; then
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        kill -TERM "$(cat "$PIDF")"
        echo "已停止（pid $(cat "$PIDF")）"
        rm -f "$PIDF"
    else
        echo "未在运行"
    fi
    # 确保回到 pass
    [ -w "$SYS/mode" ] && echo 0 > "$SYS/mode" 2>/dev/null
    exit 0
fi

INTERVAL=${1:-45}

if [ ! -w "$SYS/mode" ]; then
    echo "✗ $SYS/mode 不可写 —— 模块没加载？" >&2
    echo "  sudo insmod $HERE/../src/polarity-hook/polarity_hook.ko" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root：sudo $0 $*" >&2
    exit 1
fi

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "已在运行（pid $(cat "$PIDF")），先 stop"
    exit 1
fi

echo "启动 toggle 守护：每 ${INTERVAL}s 一次（日志 $LOG）"
nohup bash -c '
INTERVAL='"$INTERVAL"'
SYS='"$SYS"'
echo $$ > '"$PIDF"'
trap "echo 0 > $SYS/mode 2>/dev/null; exit 0" TERM INT
n=0
while true; do
    n=$((n+1))
    echo 2 > "$SYS/mode" 2>/dev/null
    sleep 3
    echo 0 > "$SYS/mode" 2>/dev/null
    printf "[%s] toggle #%d done\n" "$(date +%H:%M:%S)" "$n"
    sleep "$INTERVAL"
done
' >> "$LOG" 2>&1 &

sleep 2
echo "✓ 已启动（pid $(cat "$PIDF" 2>/dev/null)）"
echo
echo "验证：起负载后测带宽，应在 250+ GB/s"
echo "  /data/labs/nvidia/analysis/clburn 15 triad 512"
echo
echo "停止：sudo $0 stop"
