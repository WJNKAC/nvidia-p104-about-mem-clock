# utils/init.sh —— 环境初始化（路径 + 加载各模块）
#
# 同一份代码要跑在两种布局下，这里统一识别：
#
#   ① 源码树：  <版本>/main/{scripts,utils,src,output}
#               入口 <版本>/main/scripts/p104-switch.sh
#   ② 已安装：  ~/.local/bin/p104-switch.sh                （单个脚本）
#               ~/.local/share/mclk-p104/{utils,*.ko,clburn,...}
#
# 判别依据：init.sh 自己在 .../utils 下。
#   兄弟目录有 scripts/ ⇒ 源码树；否则 ⇒ 安装布局。
#
# 本文件是**唯一**定义路径的地方，其它脚本不许自己算。

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
P104_UTILS_DIR="$_self_dir"
P104_MAIN_DIR=$(cd "$_self_dir/.." && pwd)

P104_BIN_DIR="${P104_BIN_DIR:-$HOME/.local/bin}"
P104_SHARE_DIR="${P104_SHARE_DIR:-$HOME/.local/share/mclk-p104}"
P104_STATE_DIR="${P104_STATE_DIR:-$HOME/.local/state/mclk-p104}"
P104_BIN="$P104_BIN_DIR/p104-switch.sh"

if [ -d "$P104_MAIN_DIR/scripts" ]; then
    # ① 源码树
    P104_LAYOUT=source
    P104_ROOT=$(cd "$P104_MAIN_DIR/.." && pwd)
    P104_SRC_DIR="$P104_MAIN_DIR/src"
    P104_OUTPUT_DIR="$P104_MAIN_DIR/output"
    P104_SCRIPTS_DIR="$P104_MAIN_DIR/scripts"
    P104_SWITCH="$P104_SCRIPTS_DIR/p104-switch.sh"
    P104_ARK_DIR="$P104_ROOT/history/ark"
else
    # ② 已安装：产物（ko / 可执行）就在 share 根，与 utils 平级
    P104_LAYOUT=installed
    P104_ROOT="$P104_MAIN_DIR"
    P104_SRC_DIR=""
    P104_OUTPUT_DIR="$P104_MAIN_DIR"
    P104_SCRIPTS_DIR="$P104_MAIN_DIR"
    P104_SWITCH="$P104_BIN"
    P104_ARK_DIR=""
fi

export P104_LAYOUT P104_MAIN_DIR P104_ROOT P104_UTILS_DIR \
       P104_SRC_DIR P104_OUTPUT_DIR P104_SCRIPTS_DIR P104_SWITCH P104_ARK_DIR \
       P104_BIN_DIR P104_SHARE_DIR P104_STATE_DIR P104_BIN

# ── 加载模块（顺序有依赖：output 必须最先）──────────────────────
# shellcheck disable=SC1091
. "$P104_UTILS_DIR/output.sh"     || return 1
. "$P104_UTILS_DIR/gpu_ident.sh"  || return 1
. "$P104_UTILS_DIR/gpu_state.sh"  || return 1
. "$P104_UTILS_DIR/perfmon.sh"    || return 1
. "$P104_UTILS_DIR/seqtick.sh"    || return 1
. "$P104_UTILS_DIR/module.sh"     || return 1
. "$P104_UTILS_DIR/install.sh"    || return 1
. "$P104_UTILS_DIR/commands.sh"   || return 1
