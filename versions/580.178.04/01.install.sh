#!/bin/bash
# 01.install.sh —— 构建 + 安装
#
# 薄别名：实现全在 main/utils/commands.sh 里，与 p104-switch.sh install 完全同一份。
# 保留编号脚本是为了在源码树里能按顺序、单独地跑某一步。
#
# 直接跑即可（需要 root 的步骤会自己提权）。

set -u
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
_self_dir=$(cd "$(dirname "$SELF")" && pwd)

# 源码树布局：本文件在版本根，utils 在 main/utils
P104_UTILS_DIR="$_self_dir/main/utils"
if [ ! -f "$P104_UTILS_DIR/init.sh" ]; then
    echo "✗ 找不到 $_self_dir/main/utils/init.sh" >&2
    echo "  本脚本要在源码树的版本根目录运行" >&2
    exit 1
fi
P104_SWITCH="$_self_dir/main/scripts/p104-switch.sh"
export P104_UTILS_DIR P104_SWITCH

# shellcheck disable=SC1091
. "$P104_UTILS_DIR/init.sh" || exit 1

case "install" in
on|off|unload|uninstall)
    [ "$(id -u)" -ne 0 ] && p104_need_root install "$@"
    ;;
esac

p104_cmd_install "$@"
