#!/bin/bash
# deploy.sh —— 把控制器放到 ~/.local/bin（**只做这一件事**）
#
# 明确不做：
#   · 不写 systemd unit
#   · 不加 modules-load.d / modprobe.d
#   · 不改 rc.local / cron / xdg-autostart
#   · 不碰 /usr、/etc
#
# 后果：开机不会加载任何模块。要用就手动 `p104-mclk start`。
#
# 用法：
#   ./deploy.sh              编译 + 装到 ~/.local/bin
#   ./deploy.sh uninstall    停掉并删除 ~/.local/bin/p104-mclk
#
# ⚠ 为什么不自启：这个模块 hook nvidia.ko 并直接改它的内部结构。
#   2026-11-13 因定时器写野指针导致整机 panic，而当时配了开机自启，
#   差点变成"每次开机都 panic、连 rmmod 的机会都没有"。
#   会 panic 的东西不该有任何自动启动路径 —— 连验证稳定后也不该有，
#   因为内核/驱动升级都可能让它突然失效，而失效形式是 panic。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KDIR=$(cd "$HERE/../src/polarity-hook" && pwd)
BINDIR="$HOME/.local/bin"
BIN="$BINDIR/p104-mclk"
SW="$BINDIR/p104-switch"
DATADIR="$HOME/.local/share/mclk-p104"

if [ "${1:-}" = "uninstall" ]; then
    echo "── 卸载 ──"
    [ -x "$SW" ] && { "$SW" unload || true; }
    [ -x "$BIN" ] && { "$BIN" stop || true; }
    rm -f "$BIN" "$SW" && echo "  ✓ 已删除 $BIN $SW"
    rm -rf "$DATADIR" && echo "  ✓ 已删除 $DATADIR（ko + mclkctl）"
    echo "  模块若仍在运行，手动：sudo rmmod arbhook"
    exit 0
fi

echo "── 1. 编译 ──"
( cd "$KDIR" && make >/dev/null 2>&1 ) || { echo "  ✗ make 失败，看 $KDIR 的报错"; exit 1; }
( cd "$KDIR" && make ctl >/dev/null 2>&1 ) \
    || gcc -O2 -Wall -o "$KDIR/mclkctl" "$KDIR/mclkctl.c" -ldl \
    || { echo "  ✗ mclkctl 编译失败"; exit 1; }
echo "  ✓ arbhook.ko / mclkctl"

echo "── 2. 装产物到 ~/.local/share/mclk-p104 ──"
# 关键：ko 和 mclkctl 跟脚本一起搬走。否则脚本被复制到 ~/.local/bin 后
# 会去 ~/.local/bin 里找 arbhook.ko（那里没有），或者到处猜路径。
mkdir -p "$DATADIR"
install -m 0644 "$KDIR/arbhook.ko"      "$DATADIR/arbhook.ko"
install -m 0644 "$KDIR/polarity_hook.ko" "$DATADIR/polarity_hook.ko"
install -m 0755 "$KDIR/mclkctl"          "$DATADIR/mclkctl"
echo "  ✓ $DATADIR/arbhook.ko   ($(stat -c%s "$DATADIR/arbhook.ko") B)"
echo "  ✓ $DATADIR/mclkctl"

echo "── 3. 装入口到 ~/.local/bin ──"
mkdir -p "$BINDIR"
install -m 0755 "$KDIR/p104-mclk"   "$BIN"
install -m 0755 "$KDIR/p104-switch" "$SW"
echo "  ✓ $BIN"
echo "  ✓ $SW"

echo
echo "════════════════════════════════════════"
echo " 完成。**没有配置任何开机自启。**"
echo "════════════════════════════════════════"
echo
echo "  确保 $BINDIR 在 PATH 里（多数发行版默认已包含）："
echo "      echo \$PATH | grep -q \"\$HOME/.local/bin\" && echo OK"
echo
echo "  用法（手动开关，推荐）："
echo "      p104-switch on       # 切到 5005（会自动提权）"
echo "      p104-switch off      # 切回 405"
echo "      p104-switch status"
echo "      p104-switch unload   # off + 卸载模块"
echo
echo "  另有 p104-mclk（kretprobe 方案，当前打不动 MCLK，仅留作实验）："
echo "      p104-mclk start      # 加载模块 + 起 daemon（会自动提权）"
echo "      p104-mclk status"
echo "      p104-mclk stop"
echo "      p104-mclk log"
echo
echo "  装了什么（全部在 HOME 里）："
echo "      $BIN                    入口脚本"
echo "      $DATADIR/        arbhook.ko + mclkctl"
echo "      ~/.local/state/mclk-p104/           pid + 日志"
echo
echo "  改了源码要重新生效：再跑一次本脚本（会把新 ko 覆盖过去）"
echo
echo "  ⚠ 模块会改 nvidia.ko 内部结构，出问题可能 panic。"
echo "    确认稳定前不要配开机自启。"
