#!/bin/bash
# inject_sites.sh —— 逐个单点注入，看哪个闸门能被单点绕过
#
# 判据：
#   在某个 site 注入 enable=1 后，跑负载
#     MCLK→5005 (带宽>200) ⇒ 该函数就是 perfmon 的闸门（单点即可绕过）
#     仍 405              ⇒ 该函数不是闸门
#   全部无效 ⇒ 影响在更底层（pstate table / clock domain target 计算）
set -u
P=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
SYS=/sys/kernel/p104_inject
CLB=/home/union/p104-probe-clburn

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

q()   { nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader; }
ps()  { nvidia-smi --query-gpu=pstate --format=csv,noheader | tr -d ' '; }
mem() { nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits | tr -d ' '; }
bw()  { local B; B=$( { "$CLB" 9 triad 2>&1 | tail -1; } ); echo "${B##*BANDWIDTH = }"; }

to_idle() { local i=0; while [ $i -lt 22 ]; do
    [ "$(ps)" = "P8" ] && [ "$(mem)" = "405" ] && return 0; sleep 1; i=$((i+1)); done; return 1; }

try_site() {   # try_site <site>
    local s=$1 nm
    case $s in
    1) nm=_nv050963rm;; 2) nm=_nv050965rm;; 3) nm=_nv050962rm;;
    4) nm=_nv050771rm;; 5) nm=_nv058409rm;;
    esac
    echo
    echo "──────── site=$s  $nm ────────"

    rmmod p104_inject 2>/dev/null
    if ! insmod "$P/p104_inject.ko" site=$s 2>/dev/null; then
        echo "    挂载失败"; return
    fi
    sleep 1

    # 先从干净空闲起步
    to_idle || "$CLB" 3 triad >/dev/null 2>&1
    to_idle
    echo "    起点: $(q)"

    echo 1 > "$SYS/enable"       # 开始注入
    sleep 1
    B=$( { "$CLB" 9 triad 2>&1 | tail -1; } )
    V=${B##*BANDWIDTH = }
    echo "    注入后负载: $(q)"
    echo "    带宽: $V"
    echo "    stat: $(tr '\n' ' ' < "$SYS/stat")"

    echo 0 > "$SYS/enable"       # 停止（会置回 bit0）
    rmmod p104_inject 2>/dev/null
    sleep 8
    echo "    复位后: $(q)"
}

echo "════ 单点注入实验：谁能让 MCLK 单点变 5005 ════"
for s in 1 2 3 5 4; do
    try_site $s
    sleep 6
done

echo
echo "════ 收尾 ════"
rmmod p104_inject 2>/dev/null
rmmod polarity_hook 2>/dev/null
sleep 12
echo "  $(q)"
