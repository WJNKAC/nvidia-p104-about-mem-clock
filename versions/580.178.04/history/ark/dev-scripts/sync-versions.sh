#!/bin/bash
# sync-versions.sh — 把 master 的共享源码/脚本同步到各版本目录
#
# 铁律：**绝不覆盖 versions/*/src/abi.h**。那是每个版本唯一的差异点，
#       覆盖它等于抹掉该版本的适配依据。
#
# 用法：
#   ./sync-versions.sh            # 同步全部版本
#   ./sync-versions.sh --check    # 只检查差异，不写
#   ./sync-versions.sh --build    # 同步后逐个 make

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
VERDIR="$ROOT/versions"

CHECK=0
BUILD=0
for a in "$@"; do
    case "$a" in
    --check) CHECK=1 ;;
    --build) BUILD=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

SHARED_SRC="p104-set-mem-clock.c sizes.c"
SHARED_SCRIPTS="memclock.sh restart.sh check-session.sh revert-regkey.sh verify-flip.sh rsh.sh"

changed=0
same=0

for d in "$VERDIR"/*/; do
    v=$(basename "$d")
    [ "$v" = "_template" ] && continue
    echo "── $v ──"

    for f in $SHARED_SRC; do
        src="$ROOT/src/$f"; dst="$d/src/$f"
        if [ ! -f "$dst" ]; then
            [ "$CHECK" -eq 1 ] && echo "  ! src/$f 缺失" || { cp -f "$src" "$dst"; echo "  + src/$f"; }
            changed=$((changed+1)); continue
        fi
        if cmp -s "$src" "$dst"; then
            same=$((same+1))
        else
            if [ "$CHECK" -eq 1 ]; then
                echo "  ~ src/$f 与 master 不同"
                diff -u "$dst" "$src" | head -12 | sed 's/^/      /'
            else
                cp -f "$src" "$dst"; echo "  ~ src/$f 已同步"
            fi
            changed=$((changed+1))
        fi
    done

    for f in $SHARED_SCRIPTS; do
        src="$ROOT/scripts/$f"; dst="$d/scripts/$f"
        [ -f "$src" ] || continue
        if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
            if [ "$CHECK" -eq 1 ]; then
                echo "  ~ scripts/$f 与 master 不同"
            else
                cp -f "$src" "$dst"; chmod +x "$dst"; echo "  ~ scripts/$f 已同步"
            fi
            changed=$((changed+1))
        else
            same=$((same+1))
        fi
    done

    # abi.h 只看不改，提醒它与 master 是否相同（相同通常意味着没做适配）
    if [ -f "$d/src/abi.h" ]; then
        if cmp -s "$ROOT/src/abi.h" "$d/src/abi.h"; then
            echo "  = src/abi.h 与 master 相同（若本版本未适配，这是正常的）"
        else
            echo "  * src/abi.h 与 master 不同（本版本已适配过，保留）"
        fi
    else
        echo "  ✗ src/abi.h 缺失！"
        changed=$((changed+1))
    fi

    if [ "$BUILD" -eq 1 ] && [ "$CHECK" -eq 0 ]; then
        echo "  构建:"
        ( cd "$d" && make >/dev/null 2>&1 && echo "    ok  bin/p104-set-mem-clock" ) \
            || echo "    ✗ 构建失败"
    fi
done

echo
echo "差异 $changed 项，一致 $same 项"
[ "$CHECK" -eq 1 ] && [ "$changed" -gt 0 ] && { echo "（--check 模式，未写入）"; exit 1; }
exit 0
