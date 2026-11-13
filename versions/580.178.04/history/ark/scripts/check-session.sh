#!/bin/bash
# check-session.sh — 一眼看出"这次重启有没有正确保存 KDE 会话"
#
# 判据（本项目实测得出）：
#   ~/.config/session/kwin_saved at previous logout_
#       ← 这个文件的 mtime = 最后一次**正常注销**的时刻
#   若它比 `uptime -s`（本次开机时间）**老**，说明本次开机前那次关机
#   没有走 KDE 注销流程 ⇒ 会话没保存 ⇒ 下次登录会复活旧窗口。
#
#   反例（2026-11-13 实测）：直接 sudo reboot 后
#       uptime -s = 14:51:39
#       kwin_saved at previous logout_ = 11-12 10:00   ← 停在两天前
#   即：重启了，但会话状态没更新。
#
# 用法: ./check-session.sh

set -u
UID_TARGET="${RESTART_UID:-1000}"
SESSDIR="/home/$(id -nu "$UID_TARGET" 2>/dev/null || echo union)/.config/session"
KSMSERVERRC="/home/$(id -nu "$UID_TARGET" 2>/dev/null || echo union)/.config/ksmserverrc"

echo "════════════════════════════════════════════"
echo " KDE 会话保存状态"
echo "════════════════════════════════════════════"

BOOT=$(uptime -s)
BOOT_TS=$(date -d "$BOOT" +%s)
echo "  本次开机      : $BOOT"

KEY="$SESSDIR/kwin_saved at previous logout_"
echo
echo "── 会话文件 ──"
if [ -d "$SESSDIR" ]; then
    ls -la --time-style=long-iso "$SESSDIR" 2>/dev/null | sed 's/^/  /'
else
    echo "  (无 $SESSDIR)"
fi

echo
echo "── 判定 ──"
if [ -f "$KEY" ]; then
    MTIME=$(stat -c %Y "$KEY")
    MSTR=$(stat -c %y "$KEY" | cut -d. -f1)
    if [ "$MTIME" -ge "$BOOT_TS" ]; then
        echo "  ✓ 会话在本次开机前被写过（$MSTR）"
        echo "    → 那次关机走了 KDE 注销流程，窗口记忆是新的"
    else
        AGE=$(( (BOOT_TS - MTIME) / 3600 ))
        echo "  ✗ 会话文件停在 $MSTR，比本次开机（$BOOT）老 ${AGE} 小时"
        echo "    → 那次关机**没有**走 KDE 注销流程（直接 reboot / 断电 / 崩溃）"
        echo "    → 下次登录会复活「上次正常注销时还开着、后来早已关掉」的窗口"
        echo
        echo "    修法：以后关机/重启用 ./restart.sh，别用 sudo reboot"
    fi
else
    echo "  ? 找不到 \"kwin_saved at previous logout_\""
    echo "    可能：从未正常注销过，或该 Plasma 版本用了别的文件名"
fi

echo
echo "── 会话里记了哪些程序 ──"
if [ -f "$KSMSERVERRC" ]; then
    grep -E "^program[0-9]+=" "$KSMSERVERRC" 2>/dev/null | sed 's/^/  /' || echo "  (无)"
    N=$(grep -cE "^program[0-9]+=" "$KSMSERVERRC" 2>/dev/null || echo 0)
    echo "  共 $N 个"
else
    echo "  (无 $KSMSERVERRC)"
fi
