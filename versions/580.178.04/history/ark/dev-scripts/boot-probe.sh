#!/bin/bash
# p104-boot-probe.sh —— 一次性开机探针
#
# 要回答的一个问题：
#   刚开机、**完全没跑过负载**时，MCLK 的 freq range 是
#       [405, 405]    ← 出厂即单点锁死
#   还是 [405, 5005]   ← 初始完整，跑过负载之后才塌缩
#
# 为什么必须开机就跑：
#   range 一旦被塌缩，本会话内无法还原（除 toggle PERFMON_ENABLED 的短窗口）。
#   所以必须在「第一次 changeseq 之前」挂上 kretprobe。
#
# 安全性：
#   mode 默认 0（apply_override 直接 return，只 dump 不写任何时钟）。
#   全程不写 curValueToSet，不改 P-State，最后 rmmod。
#
# 判读：
#   阶段 1（零负载静置）如果 calls 涨 → 那是 nvidia 初始化/自然回落引起的
#   changeseq，它给出的 range 就是「没跑过负载」的答案。
#   阶段 1 若 calls 一直为 0 → 说明零负载不产生 changeseq，只能看阶段 2 第 1 轮。
#
# 用法：
#   p104-boot-probe.sh [零负载静置秒数，默认 90]
# 输出：/home/union/p104-boot-probe.log

LOG=/home/union/p104-boot-probe.log
KO=/home/union/.local/share/mclk-p104/arbhook.ko
CLB=/home/union/p104-probe-clburn
S=/sys/kernel/p104_arb
IDLE_WAIT=${1:-90}

exec >>"$LOG" 2>&1

up()   { cut -d. -f1 /proc/uptime; }
gpu()  { nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw \
             --format=csv,noheader 2>/dev/null | head -1; }
stat() { grep -E "^(mode|calls|patched|busy)" "$S/stat" 2>/dev/null | tr '\n' ' '; }
dumpf() { sed 's/^/      /' "$S/dump" 2>/dev/null; }

echo
echo "################ $(date -Is) probe start ################"
echo "  uptime=$(up)s   since=$(uptime -s 2>/dev/null)"

# ────────── 0. 等 nvidia 就绪 ──────────
n=0
while [ $n -lt 150 ]; do
    if [ -c /dev/nvidiactl ] && grep -q " _nv050524rm" /proc/kallsyms 2>/dev/null; then
        break
    fi
    sleep 1; n=$((n + 1))
done
echo "[$(up)s] nvidia 就绪（等了 ${n}s）"
echo "        GPU=$(gpu)"

# ────────── 1. insmod（失败重试）──────────
echo "[$(up)s] == 挂 hook =="
ins=0
while [ $ins -lt 10 ]; do
    if insmod "$KO" 2>&1; then echo "[$(up)s] insmod OK"; break; fi
    echo "[$(up)s] insmod 失败，重试 #$((ins + 1))"; sleep 2; ins=$((ins + 1))
done
if [ ! -e "$S/stat" ]; then
    echo "!! sysfs $S/stat 未出现，放弃"; dmesg | tail -5 | sed 's/^/    /'; exit 1
fi
echo "[$(up)s] insmod 后立刻  $(stat)"
echo "        GPU=$(gpu)"
CALLS0=$(grep -m1 '^calls' "$S/stat" | awk '{print $3}')

# ────────── 2. 阶段 1：零负载静置 ──────────
echo
echo "======== 阶段 1：零负载静置 ${IDLE_WAIT}s（等自然 changeseq）========"
echo "  关键：这里**不跑任何负载**。若 calls 从 ${CALLS0:-0} 涨起来，"
echo "        说明 nvidia 初始化/自然回落自己产生了一次 changeseq ——"
echo "        它给出的 range 就是「刚开机、没跑过负载」的答案。"
T=0; GOT_IDLE=0
while [ $T -lt "$IDLE_WAIT" ]; do
    echo 1 > "$S/dump" 2>/dev/null       # 先挂请求，等下一次调用就填
    sleep 5; T=$((T + 5))
    C=$(grep -m1 '^calls' "$S/stat" | awk '{print $3}')
    echo "[$(up)s] t=${T}s calls=$C  $(gpu)"
    if [ "$C" != "${CALLS0:-0}" ]; then
        D=$(head -1 "$S/dump" 2>/dev/null)
        case "$D" in
        pArbOutput2x*)
            echo "  >>>>>> 零负载下的 changeseq 抓到了（calls $CALLS0 -> $C）"
            dumpf
            GOT_IDLE=1
            echo 1 > "$S/dump"           # 清掉，避免重复打印
            ;;
        esac
    fi
done
if [ "$GOT_IDLE" = "0" ]; then
    echo "  >> 零负载期间没有 changeseq（dump 始终未填）"
fi

# ────────── 3. 阶段 2：主动触发，看第 1..N 轮 ──────────
echo
echo "======== 阶段 2：主动制造 changeseq，记录第 1..5 轮 ========"
R=1
while [ $R -le 5 ]; do
    # 3a. 进负载
    echo 1 > "$S/dump" 2>/dev/null
    "$CLB" 2 triad >/dev/null 2>&1
    sleep 1
    echo "--- 第 $R 轮 · 进负载 ---"
    echo "      GPU=$(gpu)"
    echo "      $(stat)"
    dumpf
    echo 1 > "$S/dump" 2>/dev/null        # 清掉，为回落抓取做准备

    # 3b. 回落
    sleep 18
    echo 1 > "$S/dump" 2>/dev/null
    sleep 4
    echo "--- 第 $R 轮 · 回落 ---"
    echo "      GPU=$(gpu)"
    echo "      $(stat)"
    dumpf
    R=$((R + 1))
done

# ────────── 4. 收尾 ──────────
echo
echo "======== 汇总 ========"
echo "[$(up)s] 最终  $(stat)"
echo "        GPU=$(gpu)"
if rmmod arbhook 2>&1; then echo "  已卸载 arbhook"; else echo "  !! rmmod 失败"; fi
echo "################ $(date -Is) probe end ################"
