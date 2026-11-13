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
    # 正确情形：会话在**关机前**几秒~几分钟写盘，所以 mtime 必然**早于**开机时间。
    # 判据是"差多久"，不是"谁更新"。
    #   0 <= BOOT - MTIME < WINDOW  → 就是这次关机前保存的 ✓
    #   BOOT - MTIME 很大            → 那次关机没保存 ✗
    #   MTIME > BOOT                 → 开机后又被人手动保存过（如 saveCurrentSession），
    #                                  这时它已不代表"上次注销"，需另看
    WINDOW=${SESSION_WINDOW_SECS:-600}
    DELTA=$(( BOOT_TS - MTIME ))
    if [ "$MTIME" -gt "$BOOT_TS" ]; then
        LATE=$(( MTIME - BOOT_TS ))
        echo "  ~ 会话文件（$MSTR）比本次开机晚 ${LATE} 秒"
        echo "    → 是开机后被手动保存的（saveCurrentSession），不代表上次注销"
        echo "    → 若想确认上次关机是否正规，需看重启前的记录"
    elif [ "$DELTA" -ge 0 ] && [ "$DELTA" -lt "$WINDOW" ]; then
        echo "  ✓ 会话在本次开机前 ${DELTA} 秒被写入（$MSTR）"
        echo "    → 那次关机**走了** KDE 注销流程，窗口记忆是新的"
    else
        if [ "$DELTA" -lt 7200 ]; then
            AGE="$(( DELTA / 60 )) 分钟"
        elif [ "$DELTA" -lt 172800 ]; then
            AGE="$(( DELTA / 3600 )) 小时"
        else
            AGE="$(( DELTA / 86400 )) 天"
        fi
        echo "  ✗ 会话文件停在 $MSTR，比本次开机（$BOOT）早 ${AGE}"
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
