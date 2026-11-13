#!/bin/bash
#
# main/scripts/p104-switch.sh —— P104-100 显存频率手动开关（主入口）
#
#   p104-switch install   构建 + 安装（switch→bin, 产物→share）
#   p104-switch on        → MCLK 5005
#   p104-switch off       → MCLK 405（安全恢复）
#   p104-switch status
#   p104-switch unload    off + 卸载模块
#   p104-switch uninstall 卸载已安装的文件
#
# 不需要写 sudo —— 本脚本会自己递归提权。
#
# ── 定位 ─────────────────────────────────────────────────────────
# 本文件是**主入口**：只做「提权 + 分发」。
# 真正的动作在版本根目录的编号脚本（01.install.sh / 02.on.sh …）与 main/utils/ 里。

set -u

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
# SELF = <版本>/main/scripts/p104-switch.sh ⇒ utils 在 ../utils
P104_UTILS_DIR=$(cd "$(dirname "$SELF")/../utils" && pwd)
export P104_UTILS_DIR

. "$P104_UTILS_DIR/init.sh" || exit 1

# ── 提权：递归调用自己 ───────────────────────────────────────────
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
        P104_BIN_DIR="$P104_BIN_DIR" \
        P104_SHARE_DIR="$P104_SHARE_DIR" \
        P104_STATE_DIR="$P104_STATE_DIR" \
        "$SELF" "$@"
}

usage() {
    cat <<EOF
用法: $(basename "$0") {install|on|off|status|unload|uninstall}

  install   构建 + 安装（switch→~/.local/bin, 产物→~/.local/share）
  on        切到 5005（清 PERFMON_ENABLED，带重试）
  off       切回 405（置回 PERFMON_ENABLED，安全恢复）
  status    当前状态
  unload    off 之后再卸载内核模块
  uninstall 删除已安装的文件（先 unload）

环境变量：
  P104_RETRY=4         on 的重试轮数（每轮 回P8+清flag+长负载）
  P104_LOAD_SECS=10    每轮负载秒数
  P104_ALLOW_ANY=1     允许非 P104 显卡（危险）
  P104_NO_SUDO=1       禁止自动提权（调试用）

不需要写 sudo。**开机不会自动加载任何东西**（刻意不写 systemd/modules-load.d）。

⚠ on 状态下 perfmon 停摆 ⇒ utilization 恒 0、pstate 恒 P0、空闲约 69W。
  这是「时钟锁定」的代价，regkey 方案（MaxPerfWithPerfMon=0）同样避不开。
EOF
}

[ $# -eq 0 ] && { usage; exit 1; }

CMD=$1; shift

# ⚠ 重入时必须把 CMD 一起带上：上面已经 shift 掉了，
#   只传 "$@" 会让提权后的自己收到空参数、直接打印用法。
#
# ⚠ deploy **不提权**：编译和安装到 $HOME 都是普通用户操作。
#   以 root 跑会有两个实际问题：
#     ① HOME 变成 /root，装错地方；
#     ② 源码在 NFS 上时 root 写不了对象文件（实测报 .o.d 权限不够）。
case "$CMD" in
on|off|unload)
    p104_need_root "$CMD" "$@"
    ;;
esac

# ── 分发到编号应用脚本 ───────────────────────────────────────────
case "$CMD" in
install)   exec "$P104_ROOT/01.install.sh"  "$@" ;;
on)        exec "$P104_ROOT/02.on.sh"       "$@" ;;
off)       exec "$P104_ROOT/03.off.sh"      "$@" ;;
status)    exec "$P104_ROOT/04.status.sh"   "$@" ;;
unload)    exec "$P104_ROOT/05.unload.sh"   "$@" ;;
uninstall) exec "$P104_ROOT/06.uninstall.sh" "$@" ;;
-h|--help|help) usage ;;
*) p104_bad "未知命令: $CMD"; echo; usage; exit 1 ;;
esac
