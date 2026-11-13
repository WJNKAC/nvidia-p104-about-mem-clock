#!/bin/bash
# revert-regkey.sh — 回退 MaxPerfWithPerfMon=0（为验证方案 D 做准备）
#
# 只改 /etc/modprobe.d/nvidia-gen2.conf，保留 Gen2 三键。
# 改完必须重启才生效（该键是 init-time 读取）。
set -eu

CONF=/etc/modprobe.d/nvidia-gen2.conf

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root：sudo $0" >&2
    exit 1
fi

if [ ! -f "$CONF" ]; then
    echo "找不到 $CONF" >&2
    exit 1
fi

echo "── 当前内容 ──"
grep -E "^options" "$CONF" || true

if ! grep -q "MaxPerfWithPerfMon" "$CONF"; then
    echo
    echo "✓ 配置里已无 MaxPerfWithPerfMon，无需改动"
    echo "  当前生效值：$(grep '^RegistryDwords' /proc/driver/nvidia/params 2>/dev/null || echo '?')"
    exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
cp -a "$CONF" "$CONF.bak-revert-$TS"
echo
echo "已备份 → $CONF.bak-revert-$TS"

# 只删 ";MaxPerfWithPerfMon=0" 这种分号连接项，保留其他键
sed -i 's/;MaxPerfWithPerfMon=0//g; s/MaxPerfWithPerfMon=0;//g; s/MaxPerfWithPerfMon=0//g' "$CONF"

echo "── 改后内容 ──"
grep -E "^options" "$CONF"

echo
echo "⚠ 需要重启才生效（MaxPerfWithPerfMon 是 init-time 键）"
echo
echo "  重启请用下面这条，**不要用 sudo reboot**："
echo "      ./scripts/restart.sh            （无需 sudo，root 连不上 session bus）"
echo "  （直接 reboot 不会保存 KDE 会话，下次登录会复活旧窗口）"
echo
echo "  重启后："
echo "    1) sudo mount -t nfs 192.168.1.15:/data/用户 /data/用户   # NFS 不在 fstab"
echo "    2) ./scripts/check-session.sh                            # 确认会话被正确保存"
echo "    3) sudo ./scripts/verify-flip.sh                         # 验证 405→5005→405"
