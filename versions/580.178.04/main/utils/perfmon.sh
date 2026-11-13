# utils/perfmon.sh —— 开关 PERFMON_ENABLED（本项目唯一的实质动作）
#
# @ver    v1
# @since  2026-11-13
# @exports p104_perfmon_off p104_perfmon_on p104_perfmon_get
#
# ── 原理（报告 237，A/B 判决得出，改动前必读）────────────────────
#
#   405 不是硬件限制，是 RM 在 PERFMON_ENABLED=1 期间施加的「时钟锁定」：
#     PMU 要计数准确，前提是时钟稳定；MCLK 一变，计数就没法换算回时间。
#   所以这是**纯软件行为**，关掉 perfmon 锁就解除。
#
#   这解释了为什么一行 `MaxPerfWithPerfMon=0` 就能满速 ——
#   它只做了一件事：清掉 pPerf+0x8e100 的 bit0。
#
#   铁证（A/B 唯一变量 = bit0，两组 range 与 curValueToSet **完全相同**）：
#     bit0=1 → 405 MHz /  19.3 GB/s
#     bit0=0 → 5005 MHz / 254.5 GB/s
#   ⇒ 改 curValueToSet 是无效方向（前两轮都错在这里）。
#
#   硬件零审查：写 3000000（3 GHz）它就真跑 2999 MHz，不做电压/时序校验。
#
# ── 两个已知副作用（清 bit0 之后）──────────────────────────────
#   ① utilization 恒 0 —— 不是"被限制"，是数据源没了：
#      _nv051004rm 从 perfmon 的采样缓冲读数算百分比（报告 239），
#      perfmon 停了缓冲不更新，算出来自然是 0。
#   ② pstate 恒 P0 —— GPU_IS_IDLE 依赖 util，util=0 就判不出空闲。
#   ⇒ 任何基于 util/pstate/功耗的运行时判据都会自毁。这是"空闲 7W + 负载 5005
#     自动切换"至今做不成的真正原因（不是找不到闸门）。

P104_SYS=/sys/kernel/p104_polarity

# 写 override：0=强制max(清bit0)  2=强制置回bit0  -1=不干预
p104_perfmon_off() {
    [ -e "$P104_SYS/override" ] || { p104_bad "sysfs 未就绪（模块没加载？）"; return 1; }
    echo 0 > "$P104_SYS/override" 2>/dev/null || { p104_bad "写 override 失败"; return 1; }
    p104_ok "override=0（清 PERFMON_ENABLED → MCLK 跟随 target）"
}

p104_perfmon_on() {
    [ -e "$P104_SYS/override" ] || { p104_bad "sysfs 未就绪"; return 1; }
    echo 2 > "$P104_SYS/override" 2>/dev/null || { p104_bad "写 override 失败"; return 1; }
    p104_ok "override=2（置回 PERFMON_ENABLED → 恢复原生 405）"
}

p104_perfmon_get() {
    [ -e "$P104_SYS/override" ] && cat "$P104_SYS/override" 2>/dev/null || echo "-"
}
