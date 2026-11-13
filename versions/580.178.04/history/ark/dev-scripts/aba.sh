#!/bin/bash
# aba.sh —— A/B/A 交替，排除"机器热了"的混淆
#   A = 无模块    B = 有模块但 mode=0（零写入）
set -u
S=/sys/kernel/p104_arb
KO=/data/labs/nvidia/nvidia-p104-set-mem-clock/src/polarity-hook/arbhook.ko
CLB=/home/union/p104-probe-clburn

q()  { nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader | tr -d ' '; }
stat() { grep -E "^calls|^patched|^flip" "$S/stat" 2>/dev/null | tr '\n' ' '; }

run_phase() {   # run_phase <A|B> <轮数>
    local ph=$1 n=$2 r
    if [ "$ph" = "B" ]; then
        # 必须以 root 运行，否则 insmod 静默失败，A/B 就退化成 A/A
        # （这个坑真踩过：v1 忘了 sudo，整轮实验白跑）
        if [ "$(id -u)" -ne 0 ]; then echo "!! 需要 root：sudo $0"; exit 1; fi
        insmod "$KO" 2>/dev/null || true
        sleep 2
        [ -e "$S/mode" ] && echo 0 > "$S/mode"
    else
        if [ "$(id -u)" -eq 0 ]; then rmmod arbhook 2>/dev/null || true; fi
        sleep 1
    fi
    echo "──── 阶段 $ph（模块 $([ -e "$S/stat" ] && echo 在 || echo 不在)）────"
    for r in $(seq 1 "$n"); do
        printf "  [%s#%s] 前 %-28s" "$ph" "$r" "$(q)"
        B=$( { "$CLB" 10 triad 2>&1 | tail -1; } )
        echo " | ${B##*BANDWIDTH = }"
        printf "        后 %-28s | %s\n" "$(q)" "$(stat)"
        sleep 18
    done
}

echo "======== A/B/A 交替测试（A=无模块, B=有模块mode=0）========"
echo "  判据：若 A 段恒 405/18.8，B 段出现 5005/>=250，则因果成立"
echo
run_phase A 2
run_phase B 2
run_phase A 2
run_phase B 2
run_phase A 2

echo
echo "======== 收尾：卸载模块 ========"
rmmod arbhook 2>/dev/null || true
sleep 3
echo "  最终 $(q)"
