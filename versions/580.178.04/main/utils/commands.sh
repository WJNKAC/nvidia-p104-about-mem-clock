# utils/commands.sh —— 六个命令的实现
#
# 主入口 main/scripts/p104-switch.sh 与顶层编号脚本 01..06 都调这里，
# 保证「命令行」和「顺序脚本」走的是同一份实现，不会各写一遍走样。
#
# 安装后只有 bin/p104-switch.sh + share/mclk-p104/{utils,output}，
# 顶层的 0N.*.sh 不进安装（它们是开发期用的顺序别名）。

# ── 提权 ────────────────────────────────────────────────────────
# 关键：sudo 默认把 HOME 改成 /root，不显式传目录，重入后就找不到产物。
p104_need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    if [ "${P104_NO_SUDO:-0}" = "1" ]; then
        p104_bad "需要 root（P104_NO_SUDO=1 已禁止提权）"; exit 1
    fi
    command -v sudo >/dev/null 2>&1 || { p104_bad "需要 root，但没有 sudo"; exit 1; }
    echo "（需要 root，正在提权重入…）"
    exec sudo -E env \
        P104_NO_SUDO=0 \
        P104_ALLOW_ANY="${P104_ALLOW_ANY:-0}" \
        P104_TARGET_NAME="${P104_TARGET_NAME:-P104}" \
        P104_SHARE_DIR="$P104_SHARE_DIR" \
        P104_BIN_DIR="$P104_BIN_DIR" \
        P104_STATE_DIR="$P104_STATE_DIR" \
        "$P104_SWITCH" "$@"
}

# ── 01 install ──────────────────────────────────────────────────
p104_cmd_install() {
    p104_build || return 1
    echo
    p104_install || return 1
    echo
    p104_hr; p104_ok "完成"; p104_hr
    cat <<EOF

  用法：
      p104-switch.sh on         # 切到 5005（自动提权）
      p104-switch.sh off        # 切回 405
      p104-switch.sh status
      p104-switch.sh unload     # 卸内核模块
      p104-switch.sh uninstall  # 删已安装文件

  ⚠ 改了 main/src/ 的 C 代码要重新跑本命令（重新编译并覆盖 .ko）
  ⚠ 改了 main/utils/ 或脚本不用重装（安装时已复制，需重跑 install 才同步）
EOF
}

# ── 02 on ───────────────────────────────────────────────────────
# 完整时序（每步的必要性见 utils/seqtick.sh 注释）：
#   校验身份 → 加载模块 → 解除锁定（内部会归零到 P8 并整轮重试）
p104_cmd_on() {
    echo "── 检查 ──"
    p104_gpu_check || return 1

    if [ "$(p104_mode)" = "5005" ]; then
        p104_ok "已经是 5005，无需操作"
        p104_inf "$(p104_line)"
        p104_warn "注意：perfmon 已停摆，util 恒 0、pstate 恒 P0、空闲约 69W"
        return 0
    fi

    echo "── 加载模块 ──"
    p104_mod_load || return 1

    echo "── 解除时钟锁定 ──"
    if p104_escalate; then
        echo
        echo "── 结果 ──"
        p104_inf "$(p104_line)"
        p104_ok "MCLK=5005（已解锁）"
        local bw; bw=$(p104_bw 8 2>/dev/null)
        [ -n "$bw" ] && p104_inf "带宽 ${bw} GB/s（>200 才算真的）"
        echo
        p104_inf "副作用：utilization 恒 0、pstate 恒 P0、空闲约 69W"
        p104_inf "用完记得：p104-switch.sh off"
        return 0
    fi

    echo
    p104_bad "MCLK 仍未到 5005"
    [ -n "${P104_ESCALATE_TRIED:-}" ] && p104_inf "各轮落点：${P104_ESCALATE_TRIED}"
    p104_inf "这是 D-state 下的竞态，多试几次通常能中"
    p104_inf "或加长：P104_RETRY=8 P104_LOAD_SECS=15 p104-switch.sh on"
    return 1
}

# ── 03 off ──────────────────────────────────────────────────────
# 比 on 更危险：没真正回到 405 就 rmmod，GPU 会常驻 P0/5005/70W 且 reset 不了。
p104_cmd_off() {
    echo "── 检查 ──"
    p104_gpu_check || return 1

    if ! p104_mod_loaded; then
        p104_ok "模块未加载 —— 本来就是原生 405 行为"
        p104_inf "$(p104_line)"
        return 0
    fi

    # 幂等：已是 405 就直接返回，不能再跑负载"触发 changeseq"
    # （否则 unload 里再调一次 off 会把刚空闲的 GPU 撑到 P0/33W，像卸载失败）
    if [ "$(p104_mode)" = "405" ]; then
        p104_ok "MCLK 已经是 405，无需切换"
        p104_inf "$(p104_line)"
        return 0
    fi

    echo "── 恢复 PERFMON_ENABLED ──"
    p104_perfmon_on || return 1

    echo "── 触发一次 changeseq 然后等降档 ──"
    if p104_descend; then
        echo
        echo "── 结果 ──"
        p104_inf "$(p104_line)"
        p104_ok "已回到 405（原生功耗）"
        return 0
    fi

    echo
    p104_warn "MCLK 仍高：$(p104_line)"
    p104_inf "再多等一会，或手动跑一次负载触发 changeseq"
    p104_bad "⚠ 此时不要 rmmod，否则 GPU 会常驻高功耗"
    return 1
}

# ── 04 status ───────────────────────────────────────────────────
p104_cmd_status() {
    echo "════ P104 显存频率开关 ════"
    echo

    echo "── 组件 ──"
    if p104_mod_loaded; then
        p104_ok "模块 ${P104_KO_NAME} 已加载"
        p104_inf "override=$(p104_perfmon_get)   0=清(→5005)  2=置回(→405)  -1=不干预"
    else
        p104_bad "模块 ${P104_KO_NAME} 未加载"
    fi

    echo
    echo "── GPU ──"
    p104_inf "$(p104_line)"

    echo
    echo "── 判定 ──"
    case "$(p104_mode)" in
    5005) p104_ok "当前 5005（perfmon 停摆：util 恒 0、pstate 恒 P0、空闲约 69W）"
          p104_inf "切回：p104-switch.sh off" ;;
    405)  p104_ok "当前 405（原生功耗）"
          p104_mod_loaded && p104_inf "切到 5005：p104-switch.sh on" ;;
    *)    p104_warn "无法判定" ;;
    esac

    echo
    echo "── 位置 ──"
    p104_inf "入口   $P104_SWITCH"
    p104_inf "模块   $P104_UTILS_DIR（utils）"
    p104_inf "产物   $P104_OUTPUT_DIR"
    p104_inf "已装   $P104_SHARE_DIR"
}

# ── 05 unload ───────────────────────────────────────────────────
# 顺序不能变：先确认回到 405，再 rmmod。
p104_cmd_unload() {
    if ! p104_mod_loaded; then
        p104_ok "模块本就未加载，无需操作"
        p104_inf "$(p104_line)"
        return 0
    fi

    p104_cmd_off || return 1

    # 硬保险：没确认到 405 就绝不卸载
    if [ "$(p104_mode)" != "405" ]; then
        p104_bad "未回到 405，拒绝卸载（否则 GPU 会常驻高功耗）"
        p104_inf "等它自然回落后再执行 unload"
        return 1
    fi

    echo
    echo "── 卸载模块 ──"
    p104_mod_unload || return 1
    sleep 3
    p104_inf "$(p104_line)"
    p104_inf "注：卸载后可能短暂停在 P0/33W，约 30 秒自然回 P8/8W，不是卡死"
}

# ── 06 uninstall ────────────────────────────────────────────────
p104_cmd_uninstall() {
    if p104_mod_loaded; then
        echo "── 先卸载模块 ──"
        p104_cmd_unload || {
            p104_bad "模块仍在运行，拒绝删除文件"
            p104_inf "等 GPU 回到 405 后重试"
            return 1
        }
    fi
    echo
    echo "── 删除安装的文件 ──"
    p104_uninstall
}
