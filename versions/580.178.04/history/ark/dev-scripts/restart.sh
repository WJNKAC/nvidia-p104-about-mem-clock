#!/bin/bash
# restart.sh — 按 KDE 正常流程重启（保留会话，避免下次启动复活已关闭的窗口）
#
# ⚠ 本脚本**不需要 root**，而且用 root 直接跑会失败：
#     session bus（/run/user/<uid>/bus）虽有 0666 权限，
#     但 dbus-daemon 的安全策略会拒绝 root 连接，报
#       "Could not connect to D-Bus server: ... NoReply"
#   所以要以**桌面用户**身份运行。若确实用 sudo 启动了，脚本会自动降权。
#
# 为什么不能直接 sudo reboot：
#   KDE 的窗口记忆由 ksmserver 在**正常注销流程**里写盘（saveYourself）。
#   直接 `reboot` / `systemctl reboot` 只发 SIGTERM，ksmserver 来不及（或不保证）
#   走完整保存 ⇒ 会话文件停留在上一次正常注销时的状态
#   ⇒ 下次登录会把「上次正常注销时还开着、后来早已关掉」的窗口全部复活。
#
#   实测反例（2026-11-13）：sudo reboot 后
#       uptime -s                              = 2026-11-13 14:51:39
#       kwin_saved at previous logout_ 的 mtime = 2026-11-12 10:00   ← 停在 28 小时前
#
# 正确路径（Plasma 6）：
#   org.kde.Shutdown.saveSession()        — 可选，显式落盘
#   org.kde.Shutdown.logoutAndReboot()    — 注销并重启
#
# 用法：
#   ./restart.sh              # 保存会话 → KDE 注销并重启
#   ./restart.sh --no-save    # 不显式 saveSession
#   ./restart.sh --dry-run    # 只检查环境，不真重启

set -u

UID_TARGET="${RESTART_UID:-1000}"
TARGET_USER=$(id -nu "$UID_TARGET" 2>/dev/null || echo "")
BUS="unix:path=/run/user/${UID_TARGET}/bus"
DO_SAVE=1
DRY=0

for a in "$@"; do
    case "$a" in
    --no-save)  DO_SAVE=0 ;;
    --dry-run)  DRY=1 ;;
    -h|--help)
        sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }

# ── 关键：会话总线只能由桌面用户自己连 ──
qdbus_session() {
    if [ "$(id -u)" -eq "$UID_TARGET" ]; then
        DBUS_SESSION_BUS_ADDRESS="$BUS" qdbus6 "$@"
    elif [ -n "$TARGET_USER" ]; then
        sudo -u "$TARGET_USER" env DBUS_SESSION_BUS_ADDRESS="$BUS" qdbus6 "$@"
    else
        return 1
    fi
}

say "── 环境检查 ──"

if [ -z "$TARGET_USER" ]; then
    say "✗ UID $UID_TARGET 不存在；用 RESTART_UID=<uid> 指定桌面用户"
    exit 1
fi

if [ ! -S "/run/user/${UID_TARGET}/bus" ]; then
    say "✗ 找不到会话总线 /run/user/${UID_TARGET}/bus"
    say "  → $TARGET_USER 没有活动的图形会话"
    say "    若只是要重启，请等用户登录桌面后用 KDE 菜单里的「重启」。"
    exit 1
fi
say "✓ 会话总线 $BUS（属主 $TARGET_USER）"

CUR_UID=$(id -u)
if [ "$CUR_UID" -eq "$UID_TARGET" ]; then
    say "✓ 当前身份 = 桌面用户（最佳）"
elif [ "$CUR_UID" -eq 0 ]; then
    say "ℹ 当前是 root —— session bus 会拒绝 root 直连，将自动降权到 $TARGET_USER"
else
    say "ℹ 当前 UID $CUR_UID ≠ $UID_TARGET，将通过 sudo -u $TARGET_USER 调用"
fi

if ! qdbus_session org.kde.Shutdown /Shutdown 2>/dev/null | grep -q logoutAndReboot; then
    say "✗ 取不到 org.kde.Shutdown.logoutAndReboot"
    say "  → 不是 KDE 会话，或 Plasma 版本接口不同"
    say "    退路：请用户在 KDE 菜单里手动选「重启」（不要 sudo reboot）"
    exit 1
fi
say "✓ org.kde.Shutdown.logoutAndReboot 可用"

if pgrep -x ksmserver >/dev/null 2>&1; then
    say "✓ ksmserver 在运行（会话保存的执行者）"
else
    say "⚠ ksmserver 未运行 —— 会话记忆本来就不会被保存"
fi

# ── 关键前置检查：dbus 激活环境（2026-11-13 实测故障点）──
# ksmserver-logout-greeter 是被 dbus 激活的，它继承 **dbus-daemon 的激活环境**。
# 若那个环境里没有 WAYLAND_DISPLAY，greeter 连不上合成器 → 起来就退
# → 名字释放 → 下次点击再激活再退 → 表现为"点重启完全没反应"。
#
# 判断方式：greeter 能否常驻。已在跑 = 环境 OK。
say ""
GREETER_UP=0
if pgrep -f "ksmserver-logout-greeter" >/dev/null 2>&1; then
    say "✓ logout-greeter 已在运行（dbus 激活环境正常）"
    GREETER_UP=1
else
    say "· logout-greeter 未运行，尝试激活以验证环境…"
    qdbus_session org.kde.LogoutPrompt /LogoutPrompt >/dev/null 2>&1
    sleep 2
    if pgrep -f "ksmserver-logout-greeter" >/dev/null 2>&1; then
        say "✓ 激活成功并常驻（环境正常）"
        GREETER_UP=1
    else
        say "✗ greeter 激活后立即退出 —— dbus 激活环境缺 WAYLAND_DISPLAY"
        say "  这就是「点重启没反应」的原因。修复："
        say "    dbus-update-activation-environment --systemd \\"
        say "        WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP"
        say "  或装持久化修复：scripts/fix-kde-dbus-env.desktop → ~/.config/autostart/"
        say ""
        say "  仍要继续的话，可退化为 logind 重启（**会丢窗口记忆**）："
        say "    sudo systemctl reboot"
        exit 1
    fi
fi

if grep -q "MaxPerfWithPerfMon" /etc/modprobe.d/nvidia-gen2.conf 2>/dev/null; then
    say ""
    say "ℹ 当前仍配置了 MaxPerfWithPerfMon（方案 A）"
    say "  若目的是验证方案 D，应先跑 ./revert-regkey.sh 再重启"
fi

say ""
if [ "$DRY" -eq 1 ]; then
    say "── dry-run：检查全部通过，未执行任何动作 ──"
    exit 0
fi

# ── 执行 ──
if [ "$DO_SAVE" -eq 1 ]; then
    say "── 1/2 显式保存会话（saveSession）──"
    if qdbus_session org.kde.Shutdown /Shutdown org.kde.Shutdown.saveSession 2>&1; then
        say "✓ saveSession 已调用"
    else
        say "⚠ saveSession 失败（继续，logoutAndReboot 通常自己也会保存）"
    fi
    sleep 1
else
    say "── 跳过 saveSession（--no-save）──"
fi

say "── 2/2 KDE 注销并重启（logoutAndReboot）──"
say "   ⚠ 桌面会话将被注销，SSH 连接随即断开属正常"
say "   ℹ 若 KDE 开了「确认注销」，桌面会弹确认框 —— 需点「注销」"
say "     （Plasma 6 已移除 KSMServerInterface.logout，只剩 resetLogout，"
say "       脚本无法绕过确认）"
say ""
qdbus_session org.kde.Shutdown /Shutdown org.kde.Shutdown.logoutAndReboot 2>&1

sleep 30
say ""
say "⚠ 30 秒后仍未重启 —— 可能弹出确认框且被取消，或接口未生效。"
say "  请让用户在 KDE 菜单里手动选「重启」。"
say "  不要改用 sudo reboot：那正是本次要避开的方式。"
exit 3
