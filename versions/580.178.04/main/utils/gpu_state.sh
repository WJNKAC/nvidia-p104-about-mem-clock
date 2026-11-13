# utils/gpu_state.sh —— 读 GPU 状态（pstate / mem / power / 带宽）
#
# @ver    v1
# @since  2026-11-13
# @exports p104_line p104_mem p104_pstate p104_mode p104_bw
#
# ── 判频率的铁律（血泪教训，改动前必读）──────────────────────────
#   `clocks.mem` 会**谎报**：它报的是 curValueToSet（目标值），不是硬件实测。
#   这个坑一天内被骗过 3 次：
#     · 看到 5005 实际带宽只有 18.8 GB/s
#     · 看到 405  实际带宽有 264 GB/s
#   ⇒ 判断频率真伪**只信带宽**（p104_bw）。
#
#   另一个坑：nvidia-smi 一次调用 100~300ms，1 秒采样会**漏掉短瞬态**。
#   实测过"写 3000000 后硬件确实到 2999 MHz，但只存活几十毫秒"，
#   用 5 秒采样完全看不见，于是误判成"值非法被拒绝"。
#   要看瞬态请用 src/mclkwatch.c（300 Hz）。

p104_line() {
    nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw \
        --format=csv,noheader 2>/dev/null | head -1
}

p104_mem() {
    nvidia-smi --query-gpu=clocks.mem --format=csv,noheader,nounits 2>/dev/null \
        | head -1 | tr -d ' '
}

p104_pstate() {
    nvidia-smi --query-gpu=pstate --format=csv,noheader 2>/dev/null \
        | head -1 | tr -d ' '
}

# 归一化状态：5005 / 405 / unknown
#   判据用 mem>=4000（此时 perfmon 停摆，pstate 恒 P0，不能靠 pstate 判断）
p104_mode() {
    local m; m=$(p104_mem)
    [ -z "$m" ] && { echo unknown; return; }
    if [ "$m" -ge 4000 ] 2>/dev/null; then echo 5005; else echo 405; fi
}

# 带宽（GB/s，纯数字）。找不到 clburn 就返回空。
p104_bw() {
    local secs=${1:-10} l B
    l=$(p104_loader_path) || return 1
    B=$( { "$l" "$secs" triad 2>&1 | tail -1; } )
    B=${B##*BANDWIDTH = }
    printf '%s' "${B%% *}"
}

# 找负载程序。顺序：显式指定 → 已部署的副本 → 分析目录 → 本版本 output
p104_loader_path() {
    local l
    for l in "${P104_LOADER:-}" \
             "$HOME/.local/share/mclk-p104/clburn" \
             /home/union/p104-probe-clburn \
             /data/labs/nvidia/analysis/clburn \
             "$P104_OUTPUT_DIR/clburn"; do
        [ -n "$l" ] && [ -x "$l" ] && { printf '%s' "$l"; return 0; }
    done
    return 1
}
