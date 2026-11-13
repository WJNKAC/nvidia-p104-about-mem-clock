# utils/seqtick_v1.sh —— 制造 / 等待 changeseq（这套东西最难的部分）
#
# @ver    v1
# @since  2026-11-13
# @exports p104_wait_idle p104_load p104_kick p104_escalate
#
# ── 为什么需要这层 ───────────────────────────────────────────────
#   清/置回 bit0 只是改了标志位；RM 要到**下一次仲裁**（changeseq）
#   才会按新状态重新下发时钟。没有 changeseq，flag 改了也白改。
#
#   能产生 changeseq 的只有一次**真实的 P-State 跃迁**（P8↔P0）。
#   而 _nv050524rm（仲裁函数）**只在跃迁瞬间被调用**，
#   稳态负载期间 calls 是冻结的 —— 这点用探针实测过（报告 238）。
#
# ── 两个方向的火候（都踩过，改动前必读）────────────────────────
#
#   【ON 方向】清 bit0 → 要 MCLK 变 5005
#     必须先回 P8 再清 flag，且要重试。
#     因为清 flag 后 GPU_IS_IDLE 失效 ⇒ 常驻 P0 ⇒ **P0 下不再有跃迁**
#     ⇒ 没有 changeseq ⇒ MCLK 永远不会被重新下发。
#     所以"清了 flag 卡在 P0 再拼命跑负载"是徒劳的（实测连续 6 次失败）。
#     重试的最小单位必须是「回 P8 + 清 flag + 长负载」一整轮。
#
#   【OFF 方向】置回 bit0 → 要 MCLK 回 405
#     只跑**一次**短负载，然后**纯静置**。
#       · 完全静置：卡 P0/5005/69W，20 秒都不动
#       · 循环里反复跑负载：负载把 GPU 撑住，永远等不到降档
#     正确：跑一次 5s → 停手 → 等它自己降（实测 5 秒内回 P8/405/8W）。
#
#   ⚠ 还有一条：off 必须**幂等**。已是 405 时要直接返回，
#     不能再跑负载 —— 否则 unload 里再调一次 off 会把刚空闲的 GPU
#     重新撑到 P0/33W，看起来像卸载失败。

# 等 GPU 真正回到空闲（P8 + MCLK 405）。默认 20 秒超时。
p104_wait_idle() {
    local t=${1:-20} i=0
    while [ $i -lt "$t" ]; do
        if [ "$(p104_mode)" = "405" ] && [ "$(p104_pstate)" = "P8" ]; then
            return 0
        fi
        sleep 1; i=$((i+1))
    done
    return 1
}

# 跑一次负载（用于制造 P8→P0 跃迁）
p104_load() {
    local secs=${1:-10} l
    if l=$(p104_loader_path); then
        "$l" "$secs" triad >/dev/null 2>&1
    else
        # 兜底：完整查询也会驱动 D-state 转换
        nvidia-smi -q >/dev/null 2>&1
        sleep 2
    fi
}

# 短促负载（4s），用于"促回落"
p104_kick() { p104_load 4; }

# ── 向上跃迁：把 MCLK 顶到 5005 ──────────────────────────────────
# 调用前需已 p104_perfmon_off。
# 返回 0 = 成功到 5005；1 = 失败
p104_escalate() {
    local max_try=${P104_RETRY:-4} secs=${P104_LOAD_SECS:-10} n=0

    while [ $n -lt "$max_try" ]; do
        n=$((n+1))
        [ $n -gt 1 ] && p104_inf "── 第 $n 轮 ──"

        # (a) 回到 P8。这是清 flag 的前提，不是可选优化。
        p104_perfmon_on >/dev/null 2>&1      # 先置回，让 GPU_IS_IDLE 复活
        if ! p104_wait_idle; then
            p104_kick                          # 卡住了就跑一次促它回落
            if ! p104_wait_idle; then
                p104_warn "无法回到 P8（$(p104_line)），跳过本轮"
                continue
            fi
        fi
        p104_ok "P8 就绪：$(p104_line)"

        # (b) 趁空闲清 flag
        p104_perfmon_off >/dev/null || return 1

        # (c) 立刻长负载，让那次 P8→P0 的 changeseq 看到清掉的 flag
        p104_load "$secs"

        [ "$(p104_mode)" = "5005" ] && return 0
        p104_warn "本轮未命中（$(p104_line)）"
    done
    return 1
}

# ── 向下回落：把 MCLK 退回 405 ──────────────────────────────────
# 调用前需已 p104_perfmon_on。
p104_descend() {
    local t=${1:-25} i=0

    p104_load 5          # 只跑一次，制造一次跃迁
    # 然后纯静置 —— 再跑负载会把 GPU 撑住，永远等不到降档
    while [ $i -lt "$t" ]; do
        [ "$(p104_mode)" = "405" ] && return 0
        sleep 1; i=$((i+1))
        [ $((i % 5)) -eq 0 ] && p104_inf "  ${i}s… $(p104_line)"
    done
    return 1
}
