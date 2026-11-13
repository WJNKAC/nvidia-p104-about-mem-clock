# utils/module.sh —— 内核模块的加载 / 卸载 / 状态
#
# @ver    v1
# @since  2026-11-13
# @fix    2026-11-13 临时文件从固定 /tmp/.p104-*.err 改为 mktemp
#         （固定路径一旦被 root 建过，普通用户就写不进去 / 删不掉）
# @exports p104_mod_loaded p104_mod_load p104_mod_unload
#
# ⚠ 三条硬纪律
#
#   ① **不写 systemd / modules-load.d / rc.local**
#      这个模块 hook nvidia.ko 并改它的内部结构。2026-11-13 因定时器写野指针
#      导致过整机 panic，而当时配了开机自启 —— 差点变成"每次开机都 panic、
#      连 rmmod 的机会都没有"。会 panic 的东西不该有任何自动启动路径，
#      连验证稳定后也不该有：内核/驱动升级都可能让它突然失效，失效形式是 panic。
#
#   ② **产物放 ~/.local/share/mclk-p104，不放 /usr /etc**
#      来源是 main/output/，由 utils/install.sh 复制过去
#      系统目录是发行版的地盘，出了事难回收。
#
#   ③ **不能直接 rmmod**（极性模块）
#      实测：直接 rmmod polarity_hook 后 GPU 常驻 P0/5005/70W 达 90 秒不回落，
#      `nvidia-smi --gpu-reset` 也因 X server 占用而失败。
#      必须先把 perfmon 置回、确认回到 405 之后再卸。
#      （polarity_hook 的 __exit 里虽有恢复逻辑，但实测常常来不及生效。）

P104_KO_NAME=polarity_hook
P104_KO="$P104_SHARE_DIR/$P104_KO_NAME.ko"

p104_mod_loaded() { lsmod | grep -q "^$P104_KO_NAME "; }

p104_mod_load() {
    if p104_mod_loaded; then
        p104_ok "模块 $P104_KO_NAME 已加载，复用"
        return 0
    fi
    [ -f "$P104_KO" ] || {
        p104_bad "找不到模块 $P104_KO"
        p104_inf "先安装：p104-switch deploy   （或 ./01.install.sh）"
        return 1
    }
    local err; err=$(mktemp /tmp/.p104-ins.XXXXXX)
    if ! insmod "$P104_KO" 2>"$err"; then
        p104_bad "insmod 失败"
        sed 's/^/    /' "$err"; rm -f "$err"
        p104_inf "常见原因：内核升级后 vermagic 不匹配 → 重新 make"
        return 1
    fi
    rm -f "$err"

    local i=0
    while [ ! -e "$P104_SYS/override" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -e "$P104_SYS/override" ] || { p104_bad "sysfs 未就绪"; dmesg | tail -5 | sed 's/^/    /'; return 1; }
    p104_ok "模块已加载"
}

p104_mod_unload() {
    if ! p104_mod_loaded; then
        p104_ok "模块未加载"
        return 0
    fi
    local err; err=$(mktemp /tmp/.p104-rm.XXXXXX)
    if rmmod "$P104_KO_NAME" 2>"$err"; then
        rm -f "$err"
        p104_ok "模块已卸载"
        return 0
    fi
    p104_bad "rmmod 失败"
    sed 's/^/    /' "$err"; rm -f "$err"
    p104_inf "查持有者（refcnt）：lsmod | grep $P104_KO_NAME"
    return 1
}
