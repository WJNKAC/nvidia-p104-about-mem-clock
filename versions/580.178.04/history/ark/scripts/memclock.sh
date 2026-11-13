#!/bin/bash
# memclock — p104-set-mem-clock 的便捷封装
#
#   memclock on        后台 acquire，常驻（写 pid 文件）
#   memclock off       释放并停止
#   memclock status    显示当前 P-State / 时钟 / 是否持有
#   memclock probe     同步跑一次 acquire→release，看通道是否通
#
# 必须 root（内核侧有 osIsAdministrator() 检查）。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/../src/p104-set-mem-clock"
PIDFILE="${MEMCLOCK_PIDFILE:-/run/p104-memclock.pid}"
LOGFILE="${MEMCLOCK_LOGFILE:-/run/p104-memclock.log}"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root：sudo $0 $*" >&2
        exit 1
    fi
}

[ -x "$BIN" ] || { echo "找不到 $BIN，先在 src/ 里 make" >&2; exit 1; }

status_show() {
    echo "── GPU 状态 ──"
    nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw,utilization.gpu \
        --format=csv,noheader 2>/dev/null | sed 's/^/  /'
    echo
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "  perfmon: 已持有（pid $(cat "$PIDFILE")）"
    else
        echo "  perfmon: 未持有"
    fi
}

case "${1:-}" in
on)
    need_root "$@"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "已经在运行（pid $(cat "$PIDFILE")）"
        exit 0
    fi
    echo "acquire …"
    nohup "$BIN" >> "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 4
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "已启动（pid $(cat "$PIDFILE")），日志 $LOGFILE"
        status_show
    else
        echo "启动失败，日志：" >&2
        tail -20 "$LOGFILE" >&2
        rm -f "$PIDFILE"
        exit 1
    fi
    ;;
off)
    need_root "$@"
    if [ -f "$PIDFILE" ]; then
        P=$(cat "$PIDFILE")
        if kill -0 "$P" 2>/dev/null; then
            kill -TERM "$P"
            for _ in $(seq 1 20); do
                kill -0 "$P" 2>/dev/null || break
                sleep 0.25
            done
            kill -0 "$P" 2>/dev/null && kill -KILL "$P"
            echo "已停止（pid $P）—— 驱动侧 client 销毁时会自动 release"
        fi
        rm -f "$PIDFILE"
    else
        echo "没有 pid 文件，尝试直接 release 一次"
        "$BIN" --release
    fi
    sleep 2
    status_show
    ;;
status)
    status_show
    ;;
probe)
    need_root "$@"
    "$BIN" --probe
    ;;
*)
    cat <<EOF
用法: sudo $0 {on|off|status|probe}

  on      后台 acquire perfmon，使 MCLK 取 range.max = 5005
  off     释放并退出（MCLK 回到 405）
  status  查看当前状态与是否持有
  probe   同步验证通道（acquire → release），不常驻

环境变量: MEMCLOCK_PIDFILE / MEMCLOCK_LOGFILE
EOF
    exit 1
    ;;
esac
