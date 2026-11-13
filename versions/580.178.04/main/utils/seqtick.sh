# utils/seqtick.sh —— 制造 / 等待 changeseq
#
# @ver    v2
# @since  2026-11-13
# @replaces seqtick_v1（v1 已退役，移入 history/ark/utils/）
# @exports p104_wait_idle p104_load p104_kick p104_escalate p104_descend
#
# ── v2 相对 v1 的改动（接口完全不变，调用方无需修改）────────────
#
#   ① 轮间加冷却等待。v1 失败后**立刻**进下一轮，此时 GPU 还在
#      P0/5005 的残留状态里没稳定下来，实测会连着几轮都打不中
#      （一次连跑 4 轮全失败）。v2 每轮之间等 P104_COOLDOWN 秒（默认 2）。
#
#   ② 默认重试 4 → 6 轮。实测命中率不稳定（跨会话统计约 1/2 ~ 1/4），
#      4 轮偶尔不够。轮数多一点比失败一次省事。
#
#   ③ 失败时打印每轮的实际落点，便于判断是"完全不动"还是"动了又回落"。
#
# ── 为什么这个流程长这样（v1 起就成立，v2 沿用）────────────────
#
#   【ON】必须先回 P8 再清 flag，且要重试。
#     清 flag 后 GPU_IS_IDLE 失效 ⇒ 常驻 P0 ⇒ P0 下不再有 P-State 跃迁
#     ⇒ 没有 changeseq ⇒ MCLK 永远不会被重新下发。
#     所以"清了 flag 卡在 P0 再拼命跑负载"是徒劳的（实测连续 6 次失败）。
#     重试的最小单位必须是「回 P8 + 清 flag + 长负载」一整轮。
#
#   【OFF】只跑一次短负载，然后纯静置。
#     · 完全静置：卡 P0/5005/69W，20 秒都不动
#     · 循环里反复跑负载：负载把 GPU 撑住，永远等不到降档
#     正确：跑一次 5s → 停手 → 等它自己降（实测 5 秒内回 P8/405/8W）。
#
#   ⚠ off 必须幂等：已是 405 时直接返回，不能再跑负载
#     （否则 unload 里再调一次 off 会把刚空闲的 GPU 撑到 P0/33W）。

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
        nvidia-smi -q >/dev/null 2>&1      # 兜底：完整查询也会驱动 D-state
        sleep 2
    fi
}

# 短促负载（4s），用于"促回落"
p104_kick() { p104_load 4; }

# ── 向上跃迁：把 MCLK 顶到 5005 ──────────────────────────────────
# 调用前需已 p104_perfmon_off（或由本函数内部处理）。
# 返回 0 = 成功到 5005；1 = 失败
p104_escalate() {
    local max_try=${P104_RETRY:-6}
    local secs=${P104_LOAD_SECS:-10}
    local cool=${P104_COOLDOWN:-2}
    local n=0 tried=""

    while [ $n -lt "$max_try" ]; do
        n=$((n+1))
        [ $n -gt 1 ] && { p104_inf "── 第 $n 轮 ──"; sleep "$cool"; }

        # (a) 回到 P8 —— 这是清 flag 的前提，不是可选优化
        p104_perfmon_on >/dev/null 2>&1      # 先置回，让 GPU_IS_IDLE 复活
        if ! p104_wait_idle; then
            p104_kick                          # 卡住了就跑一次促它回落
            if ! p104_wait_idle; then
                p104_warn "无法回到 P8（$(p104_line)），跳过本轮"
                tried="$tried [第${n}轮:回不去P8]"
                continue
            fi
        fi
        p104_ok "P8 就绪：$(p104_line)"

        # (b) 趁空闲清 flag
        p104_perfmon_off >/dev/null || return 1

        # (c) 立刻长负载，让那次 P8→P0 的 changeseq 看到清掉的 flag
        p104_load "$secs"

        if [ "$(p104_mode)" = "5005" ]; then
            return 0
        fi
        p104_warn "本轮未命中（$(p104_line)）"
        tried="$tried [第${n}轮:$(p104_mode)]"
    done

    P104_ESCALATE_TRIED=${tried# }
    return 1
}

# ── 向下回落：把 MCLK 退回 405 ──────────────────────────────────
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
