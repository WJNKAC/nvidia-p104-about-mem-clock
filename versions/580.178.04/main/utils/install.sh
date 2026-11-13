# utils/install.sh —— 构建与安装
#
# @exports p104_build p104_install p104_uninstall
#
# 安装只动两个地方（全部在 $HOME，/usr /etc /var 一个不碰）：
#
#   ~/.local/bin/p104-switch.sh            入口（单个脚本，**复制**而非软链）
#   ~/.local/share/mclk-p104/
#       ├── utils/*.sh                     函数库
#       ├── polarity_hook.ko               内核模块
#       └── clburn / mclkwatch / mclkctl   工具
#
# 为什么入口要复制而不是软链：
#   软链指回源码树的话，"安装"就名不副实 —— 源码树一删入口就废，
#   而且一说"装了什么"就得扯上项目目录。复制成独立文件后，
#   入口只依赖 share 里的 utils，与源码树完全解耦。
#
# 代价：改了 utils 要重新 install 才同步（在源码树里直接跑不受影响）。

p104_build() {
    if [ -z "${P104_SRC_DIR:-}" ] || [ ! -d "$P104_SRC_DIR" ]; then
        p104_bad "找不到源码目录（已安装布局下不编译）"
        p104_inf "本命令要在源码树里跑：<版本>/main/scripts/p104-switch.sh install"
        return 1
    fi
    command -v make >/dev/null 2>&1 || { p104_bad "没有 make"; return 1; }
    p104_inf "构建 $P104_SRC_DIR …"

    # mktemp 而不是固定路径：固定路径一旦被 root 建过，普通用户就写不进去
    local log; log=$(mktemp /tmp/.p104-build.XXXXXX)
    if ! ( cd "$P104_SRC_DIR" && make ) >"$log" 2>&1; then
        p104_bad "make 失败（日志 $log）"
        grep -iE "error|错误" "$log" | tail -12 | sed 's/^/    /'
        return 1
    fi
    rm -f "$log"

    local ko="$P104_SRC_DIR/polarity_hook.ko"
    [ -f "$ko" ] || { p104_bad "没产出 polarity_hook.ko"; return 1; }

    mkdir -p "$P104_OUTPUT_DIR"
    install -m 0644 "$ko" "$P104_OUTPUT_DIR/polarity_hook.ko"
    local t
    for t in clburn mclkwatch mclkctl; do
        [ -f "$P104_SRC_DIR/$t" ] && \
            install -m 0755 "$P104_SRC_DIR/$t" "$P104_OUTPUT_DIR/$t"
    done
    p104_ok "产物 → $P104_OUTPUT_DIR/"
    ls -1 "$P104_OUTPUT_DIR" | sed 's/^/    /'
}

p104_install() {
    # 1. 构建（若还没产物）
    local ko="$P104_OUTPUT_DIR/polarity_hook.ko"
    [ -f "$ko" ] || p104_build || return 1

    # 2. share：utils + 产物
    mkdir -p "$P104_SHARE_DIR/utils" "$P104_BIN_DIR" "$P104_STATE_DIR"
    local f n=0
    for f in "$P104_UTILS_DIR"/*.sh; do
        [ -f "$f" ] || continue
        install -m 0644 "$f" "$P104_SHARE_DIR/utils/$(basename "$f")"
        n=$((n+1))
    done
    p104_ok "$P104_SHARE_DIR/utils/（${n} 个模块）"

    for f in "$P104_OUTPUT_DIR"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in *.c|Makefile) continue ;; esac
        install -m 0755 "$f" "$P104_SHARE_DIR/$(basename "$f")"
        p104_ok "$P104_SHARE_DIR/$(basename "$f")"
    done

    # 3. bin：入口（复制，不软链）
    install -m 0755 "$P104_SCRIPTS_DIR/p104-switch.sh" "$P104_BIN"
    p104_ok "$P104_BIN"

    p104_inf "没有配置任何开机自启（刻意）：systemd / modules-load.d / rc.local 一概不写"
    case ":$PATH:" in
    *":$P104_BIN_DIR:"*) p104_inf "$P104_BIN_DIR 已在 PATH" ;;
    *) p104_warn "$P104_BIN_DIR 不在 PATH，请自行加入" ;;
    esac
}

p104_uninstall() {
    # 先卸模块（用已安装的那份入口，不依赖源码树）
    if [ -x "$P104_BIN" ]; then
        "$P104_BIN" unload 2>/dev/null || true
    fi
    rm -f "$P104_BIN" && p104_ok "已删除 $P104_BIN"
    rm -rf "$P104_SHARE_DIR" && p104_ok "已删除 $P104_SHARE_DIR"
    rm -rf "$P104_STATE_DIR" && p104_ok "已删除 $P104_STATE_DIR"
    p104_inf "模块若仍在运行：sudo rmmod polarity_hook"
}
