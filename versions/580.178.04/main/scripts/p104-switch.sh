#!/bin/bash
#
# p104-switch.sh —— P104-100 显存频率手动开关
#
#   p104-switch.sh install    构建 + 安装
#   p104-switch.sh on         → MCLK 5005
#   p104-switch.sh off        → MCLK 405（安全恢复）
#   p104-switch.sh status
#   p104-switch.sh unload     off + 卸内核模块
#   p104-switch.sh uninstall  删已安装的文件
#
# ── 这个文件是自包含的 ───────────────────────────────────────────
# 安装后 `~/.local/bin` 里只有它一个，utils 在
# `~/.local/share/mclk-p104/utils/`。所以它**不 exec 任何外部脚本**，
# 命令实现全部来自 utils/commands.sh —— 顶层的 01..06 只是同一批
# 函数的薄别名，仅供源码树里逐个跑。
#
# 不需要写 sudo：on/off/unload/uninstall 会自己递归提权。

set -u

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
_self_dir=$(cd "$(dirname "$SELF")" && pwd)

# 找 init.sh：源码树（../utils）优先，其次安装位置（share/mclk-p104/utils）
if [ -f "$_self_dir/../utils/init.sh" ]; then
    P104_UTILS_DIR=$(cd "$_self_dir/../utils" && pwd)
elif [ -f "${P104_SHARE_DIR:-$HOME/.local/share/mclk-p104}/utils/init.sh" ]; then
    P104_UTILS_DIR="${P104_SHARE_DIR:-$HOME/.local/share/mclk-p104}/utils"
else
    echo "✗ 找不到 utils/init.sh" >&2
    echo "  试过：$_self_dir/../utils 和 \$HOME/.local/share/mclk-p104/utils" >&2
    exit 1
fi
P104_SWITCH="$SELF"
export P104_UTILS_DIR P104_SWITCH

# shellcheck disable=SC1091
. "$P104_UTILS_DIR/init.sh" || exit 1

usage() {
    cat <<EOF
用法: $(basename "$0") {install|on|off|status|unload|uninstall}

  install   构建 + 安装（本脚本→~/.local/bin，产物→~/.local/share）
  on        切到 5005（清 PERFMON_ENABLED，带重试）
  off       切回 405（置回 PERFMON_ENABLED，安全恢复）
  status    当前状态
  unload    off 之后再卸载内核模块
  uninstall 删除已安装的文件（先 unload）

环境变量：
  P104_RETRY=6         on 的重试轮数（每轮 回P8+清flag+长负载）
  P104_LOAD_SECS=10    每轮负载秒数
  P104_COOLDOWN=2      轮间冷却秒数
  P104_ALLOW_ANY=1     允许非 P104 显卡（危险）
  P104_NO_SUDO=1       禁止自动提权（调试用）

**开机不会自动加载任何东西**（刻意不写 systemd/modules-load.d）。

⚠ on 状态下 perfmon 停摆 ⇒ utilization 恒 0、pstate 恒 P0、空闲约 69W。
  这是「时钟锁定」的代价，regkey 方案（MaxPerfWithPerfMon=0）同样避不开。
EOF
}

[ $# -eq 0 ] && { usage; exit 1; }

CMD=$1; shift

case "$CMD" in
install)
    # install 必须用普通用户：装到 $HOME，且 NFS 上 root 无写权限
    if [ "$(id -u)" -eq 0 ]; then
        p104_bad "install 请用普通用户运行（不要 sudo）"
        p104_inf "它会编译并安装到当前用户的 ~/.local，root 下 HOME 是 /root"
        exit 1
    fi
    p104_cmd_install "$@" ;;
on|off|unload|uninstall)
    # 需要 root 的统一在这里提权（重入时带上 CMD —— 上一行已 shift 掉）
    [ "$(id -u)" -ne 0 ] && p104_need_root "$CMD" "$@"
    case "$CMD" in
    on)        p104_cmd_on        "$@" ;;
    off)       p104_cmd_off       "$@" ;;
    unload)    p104_cmd_unload    "$@" ;;
    uninstall) p104_cmd_uninstall "$@" ;;
    esac ;;
status)    p104_cmd_status "$@" ;;
-h|--help|help) usage ;;
*) p104_bad "未知命令: $CMD"; echo; usage; exit 1 ;;
esac
