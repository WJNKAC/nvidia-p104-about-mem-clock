#!/bin/bash
# probe_ab2.sh —— 修正版 A/B：两组都从 P8 起步，唯一变量 = PERFMON_ENABLED
#
# v1 的缺陷：B 组清 flag 时 GPU 已在 P0 ⇒ 没有 P-State 跃迁 ⇒ 没有仲裁
#            ⇒ _nv050524rm 只被调 1 次，A/B 不可比。
# 本版强制：每组都先回 P8/405，再切 bit0，再跑负载。
set -u
P=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook
S=/sys/kernel/p104_polarity
SYS=/sys/kernel/p104_probe
CLB=/home/union/p104-probe-clburn

[ "$(id -u)" -eq 0 ] || { echo "需要 root"; exit 1; }

q()  { nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader; }
mem(){ nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits | tr -d ' '; }
ps() { nvidia-smi --query-gpu=pstate --format=csv,noheader | tr -d ' '; }

to_idle() {  # 回 P8/405
    local i=0
    while [ $i -lt 25 ]; do
        [ "$(ps)" = "P8" ] && [ "$(mem)" = "405" ] && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

do_group() {  # do_group <标签> <bit0: 1|0>
    local tag=$1 v=$2
    echo
    echo "════════ $tag ════════"
    # 1. 归零到 P8
    if [ -e "$S/override" ]; then echo 2 > "$S/override"; fi
    "$CLB" 3 triad >/dev/null 2>&1
    if to_idle; then echo "    ✓ 已回空闲: $(q)"; else echo "    ! 未能回空闲: $(q)"; fi

    # 2. 设 bit0
    case "$v" in
    1) rmmod polarity_hook 2>/dev/null; sleep 1 ;;
    0) [ -e "$S/override" ] || insmod "$P/polarity_hook.ko"
       sleep 1; echo 0 > "$S/override" ;;
    esac
    echo "    bit0=$v 已设，当前: $(q)"

    # 3. 清零探针，跑负载
    echo 0 > "$SYS/stat"
    local B; B=$( { "$CLB" 10 triad 2>&1 | tail -1; } )
    echo "    负载: $(q)"
    echo "    带宽: ${B##*BANDWIDTH = }"
    echo "    ── 计数 ──"
    cat "$SYS/stat" | sed 's/^/      /'
}

# 装探针
rmmod p104_probe 2>/dev/null
insmod "$P/p104_probe.ko" || { echo "探针装载失败"; exit 1; }
sleep 1
echo "探针:"; cat "$SYS/stat" | sed 's/^/    /'

rmmod polarity_hook 2>/dev/null; sleep 2
do_group "A 组：PERFMON_ENABLED=1（MCLK 被压 405）" 1
sleep 14
do_group "B 组：PERFMON_ENABLED=0（MCLK 应 5005）" 0

# 收尾
echo
echo "════ 收尾 ════"
echo 2 > "$S/override" 2>/dev/null
"$CLB" 3 triad >/dev/null 2>&1
sleep 10
rmmod polarity_hook 2>/dev/null && echo "  polarity_hook 已卸"
rmmod p104_probe 2>/dev/null && echo "  探针已卸"
echo "  $(q)"
