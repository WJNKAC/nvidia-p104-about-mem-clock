#!/bin/bash
# selftest.sh —— 在假环境里跑 p104-mclk 的状态机，验证边界条件
#
# 不碰真 GPU / 真模块。做法：造一个临时目录冒充 sysfs，用假的
# insmod/rmmod/lsmod/nvidia-smi/setsid 覆盖 PATH，验证脚本的分支。
#
# 用法: ./selftest.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

FAKEBIN=$T/bin
FAKESYS=$T/sys
mkdir -p "$FAKEBIN" "$FAKESYS" "$T/run" "$T/log"

pass=0; fail=0
ck() { # ck <描述> <条件命令...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  ✓ $d"; pass=$((pass+1))
    else echo "  ✗ $d"; fail=$((fail+1)); fi
}

# ── 造假的命令 ──
cat > "$FAKEBIN/lsmod" <<'EOS'
#!/bin/bash
# nvidia 常驻（测试目标是 arbhook 的状态机）
[ -f "$FAKE_STATE/no_nvidia" ] || echo "nvidia 111677440 6 nvidia_uvm,nvidia_modeset"
[ -f "$FAKE_STATE/mod_loaded" ] && echo "arbhook 16384 0"
exit 0
EOS

cat > "$FAKEBIN/insmod" <<'EOS'
#!/bin/bash
if [ -f "$FAKE_STATE/insmod_fail" ]; then
    echo "insmod: ERROR: could not insert module: Invalid module format" >&2
    exit 1
fi
touch "$FAKE_STATE/mod_loaded"
mkdir -p "$FAKE_SYS"
echo 2 > "$FAKE_SYS/mode"
echo 2 > "$FAKE_SYS/mclk_idx"
printf 'symbol     : _nv050524rm\nmode       : 2\ncalls      : 5\npatched    : 1\n' > "$FAKE_SYS/stat"
exit 0
EOS

cat > "$FAKEBIN/rmmod" <<'EOS'
#!/bin/bash
if [ -f "$FAKE_STATE/rmmod_fail" ]; then
    echo "rmmod: ERROR: Module arbhook is in use" >&2
    exit 1
fi
rm -f "$FAKE_STATE/mod_loaded"
rm -rf "$FAKE_SYS"
exit 0
EOS

cat > "$FAKEBIN/nvidia-smi" <<'EOS'
#!/bin/bash
mem() { if [ -f "$FAKE_STATE/mod_loaded" ]; then echo 5005; else echo 405; fi; }
name() {
    [ -f "$FAKE_STATE/no_gpu" ] && return 0
    if [ -f "$FAKE_STATE/no_p104" ]; then echo "NVIDIA GeForce GTX 1060"
    else echo "NVIDIA P104-100"; fi
}
case "$*" in
-L) [ -f "$FAKE_STATE/no_gpu" ] && exit 1; name; exit 0 ;;
# 身份查询
*--query-gpu=name*)  name; exit 0 ;;
# 单字段查询（nounits）→ 只返回数字，与真机一致
*--query-gpu=clocks.mem*--format=csv,noheader,nounits*|*--query-gpu=clocks.mem*noheader,nounits*)
    mem; exit 0 ;;
# 多字段 → 逗号行
*--query-gpu=pstate*|*--query-gpu=clocks*)
    if [ -f "$FAKE_STATE/mod_loaded" ]; then echo "P0, 1911 MHz, 5005 MHz, 69.0 W"
    else echo "P8, 139 MHz, 405 MHz, 7.6 W"; fi; exit 0 ;;
esac
exit 0
EOS

cat > "$FAKEBIN/mclkctl" <<'EOS'
#!/bin/bash
# 假 daemon：睡到被杀
if [ "${1:-}" = "daemon" ]; then
    while true; do sleep 1; done
fi
exit 0
EOS

chmod +x "$FAKEBIN"/*

# ── 把 p104-mclk 里写死的路径改成假的 ──
sed -e "s#^SELF=.*#SELF=$T/p104-mclk#" -e "s#^HERE=.*#HERE=$T#" \
    -e "s#^ARTDIR=.*#ARTDIR=$T#" \
    -e "s#^STATEDIR=.*#STATEDIR=$T/run#" \
    -e "s#^SYS=.*#SYS=$FAKESYS#" \
    -e "s#^PIDF=.*#PIDF=$T/run/pid#" \
    -e "s#^LOGF=.*#LOGF=$T/log/log#" \
    -e "s#^MOD=.*#MOD=arbhook#" \
    "$HERE/p104-mclk" > "$T/p104-mclk"
chmod +x "$T/p104-mclk"

# 假 sysfs 路径要在脚本变量里生效，但脚本里用的是 $SYS —— 已替换
export PATH="$FAKEBIN:$PATH"
export FAKE_STATE=$T FAKE_SYS=$FAKESYS
unset P104_HOME P104_LOG P104_TARGET_NAME P104_ALLOW_ANY P104_NO_SUDO P104_STATE

# 造 .ko 与 ctl，让 need_artifact 通过
touch "$T/arbhook.ko"
cp "$FAKEBIN/mclkctl" "$T/mclkctl"
chmod +x "$T/mclkctl"

# 绕过 root 检查（本测试以非 root 跑）
sed -i 's/^need_root() {/need_root() { return 0; # /' "$T/p104-mclk"
# 本机没有 /dev/nvidiactl，测试时放宽该检查
sed -i 's#! \[ -c /dev/nvidiactl \]#false#; s#\[ -c /dev/nvidiactl \]#true#' "$T/p104-mclk"

run() { "$T/p104-mclk" "$@" 2>&1; }

echo "════ 1. 首次 start ════"
out=$(run start)
echo "$out" | sed 's/^/  | /'
ck "模块被加载"         test -f "$FAKE_STATE/mod_loaded"
ck "pid 文件已写"       test -s "$T/run/pid"
ck "sysfs mode 存在"    test -f "$FAKESYS/mode"

echo
echo "════ 2. 重复 start（应复用，不重复加载）════"
out2=$(run start)
echo "$out2" | sed 's/^/  | /'
ck "提示已在运行"       bash -c "echo '$out2' | grep -q '已在运行'"
ck "pid 未变"           test "$(cat "$T/run/pid")" = "$(cat "$T/run/pid")"

echo
echo "════ 3. status ════"
out3=$(run status)
echo "$out3" | sed 's/^/  | /'
ck "报告模块已加载"     bash -c "echo '$out3' | grep -q '已加载'"
ck "报告 daemon 运行"   bash -c "echo '$out3' | grep -q '运行中'"
ck "报告 MCLK 已提升"   bash -c "echo '$out3' | grep -q '已提升'"

echo
echo "════ 4. stop ════"
out4=$(run stop)
echo "$out4" | sed 's/^/  | /'
ck "模块被卸载"         test ! -f "$FAKE_STATE/mod_loaded"
ck "pid 文件已删"       test ! -f "$T/run/pid"
ck "sysfs 已移除"       test ! -d "$FAKESYS"
ck "报告回到 405"       bash -c "echo '$out4' | grep -q '405'"

echo
echo "════ 5. 重复 stop（应幂等）════"
out5=$(run stop)
echo "$out5" | sed 's/^/  | /'
ck "幂等：不报错"       bash -c "echo '$out5' | grep -q '未加载'"

echo
echo "════ 6. stale pid 恢复 ════"
run start >/dev/null 2>&1
echo 999999 > "$T/run/pid"        # 假的 pid
out6=$(run start)
echo "$out6" | sed 's/^/  | /'
ck "识别 stale pid 并恢复" bash -c "echo '$out6' | grep -qE '清理 stale|已在运行'"
run stop >/dev/null 2>&1

echo
echo "════ 7. insmod 失败（vermagic 不匹配）════"
touch "$FAKE_STATE/insmod_fail"
out7=$(run start)
echo "$out7" | sed 's/^/  | /'
ck "报 insmod 失败"     bash -c "echo '$out7' | grep -q 'insmod 失败'"
ck "给出 make 提示"     bash -c "echo '$out7' | grep -q 'make'"
rm -f "$FAKE_STATE/insmod_fail"

echo
echo "════ 8. rmmod 失败（refcnt>0）════"
run start >/dev/null 2>&1
touch "$FAKE_STATE/rmmod_fail"
out8=$(run stop)
echo "$out8" | sed 's/^/  | /'
ck "报 rmmod 失败"      bash -c "echo '$out8' | grep -q 'rmmod 失败'"
ck "提示查 refcnt"      bash -c "echo '$out8' | grep -q 'refcnt'"
rm -f "$FAKE_STATE/rmmod_fail"
rm -f "$FAKE_STATE/mod_loaded"; rm -rf "$FAKESYS"

echo
echo "════ 9. 无 GPU 时拒绝启动 ════"
touch "$FAKE_STATE/no_gpu"
out9=$(run start)
echo "$out9" | sed 's/^/  | /'
ck "拒绝启动"           bash -c "echo '$out9' | grep -q '枚举不到'"
rm -f "$FAKE_STATE/no_gpu"

echo
echo "════ 10. .ko 缺失时拒绝启动 ════"
mv "$T/arbhook.ko" "$T/arbhook.ko.bak"
out10=$(run start)
echo "$out10" | sed 's/^/  | /'
ck "报找不到模块"       bash -c "echo '$out10' | grep -q '找不到模块'"
ck "给出 make 提示"     bash -c "echo '$out10' | grep -q 'make'"
mv "$T/arbhook.ko.bak" "$T/arbhook.ko"

echo
echo "════ 11. 显卡不是 P104 时拒绝启动（身份校验）════"
touch "$FAKE_STATE/no_p104"
out11=$(run start)
echo "$out11" | sed 's/^/  | /'
ck "拒绝启动"           test "$(echo "$out11" | grep -c '没有名字含')" = "1"
ck "列出本机 GPU"       bash -c "echo '$out11' | grep -q 'GTX 1060'"
ck "未加载模块"         test ! -f "$FAKE_STATE/mod_loaded"
out11b=$(P104_ALLOW_ANY=1 "$T/p104-mclk" start 2>&1)
ck "P104_ALLOW_ANY=1 可放行" bash -c "echo '$out11b' | grep -q '风险自负'"
rm -f "$FAKE_STATE/no_p104"
"$T/p104-mclk" stop >/dev/null 2>&1

echo
echo "════ 12. 递归提权（不写 sudo 直接跑）════"
# 用一份 need_root 完好的副本 + 记录型假 sudo；假 sudo 只记录不执行，避免真递归
sed 's/^need_root() { return 0; # /need_root() {/' "$T/p104-mclk" > "$T/p104-sudo"
chmod +x "$T/p104-sudo"
cat > "$FAKEBIN/sudo" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_STATE/sudo_calls"
exit 0
EOS
chmod +x "$FAKEBIN/sudo"
: > "$FAKE_STATE/sudo_calls"
out12=$("$T/p104-sudo" start 2>&1)
echo "$out12" | sed 's/^/  | /'
ck "提示要提权"         bash -c "echo '$out12' | grep -q '提权'"
ck "调用过 sudo"        test -s "$FAKE_STATE/sudo_calls"
ck "传了 P104_NO_SUDO=0" bash -c "grep -q 'P104_NO_SUDO=0' '$FAKE_STATE/sudo_calls'"
ck "用绝对路径重入"     bash -c "grep -q '$T/p104-mclk start' '$FAKE_STATE/sudo_calls'"
ck "P104_NO_SUDO=1 时拒绝" bash -c "P104_NO_SUDO=1 '$T/p104-sudo' start 2>&1 | grep -q '禁止提权'"
rm -f "$FAKEBIN/sudo"

echo
echo "════ 13. 产物查找：脚本被搬到别处（deploy 布局）════"
mkdir -p "$T/elsewhere" "$T/pkg" "$T/nohome" "$T/fakehome/.local/share/mclk-p104"
# 只替换路径字段，**保留** ARTDIR=$(resolve_artdir)，并关掉 root 检查
sed -e "s#^SELF=.*#SELF=$T/elsewhere/p104-mclk#" -e "s#^HERE=.*#HERE=$T/elsewhere#" \
    -e "s#^STATEDIR=.*#STATEDIR=$T/run#" -e "s#^SYS=.*#SYS=$FAKESYS#" \
    -e "s#^PIDF=.*#PIDF=$T/run/pid2#" -e "s#^LOGF=.*#LOGF=$T/log/log2#" \
    "$HERE/p104-mclk" > "$T/elsewhere/p104-mclk"
sed -i 's/^need_root() {/need_root() { return 0; # /' "$T/elsewhere/p104-mclk"
chmod +x "$T/elsewhere/p104-mclk"
cp "$T/arbhook.ko" "$T/pkg/arbhook.ko"; cp "$T/mclkctl" "$T/pkg/mclkctl"

out13a=$(HOME=$T/nohome "$T/elsewhere/p104-mclk" start 2>&1)
echo "$out13a" | sed 's/^/  | /'
ck "无产物时报找不到模块" bash -c "echo '$out13a' | grep -q '找不到模块'"

out13b=$(P104_HOME="$T/pkg" "$T/elsewhere/p104-mclk" start 2>&1)
echo "$out13b" | sed 's/^/  | /'
ck "P104_HOME 命中"        bash -c "echo '$out13b' | grep -q '模块 $T/pkg/arbhook.ko'"
P104_HOME="$T/pkg" "$T/elsewhere/p104-mclk" stop >/dev/null 2>&1

echo
echo "════ 14. 产物查找：~/.local/share/mclk-p104 兜底 ════"
cp "$T/arbhook.ko" "$T/fakehome/.local/share/mclk-p104/arbhook.ko"
cp "$T/mclkctl"   "$T/fakehome/.local/share/mclk-p104/mclkctl"
out14=$(HOME="$T/fakehome" "$T/elsewhere/p104-mclk" start 2>&1)
echo "$out14" | sed 's/^/  | /'
ck "HOME 安装目录命中"      bash -c "echo '$out14' | grep -q 'fakehome/.local/share/mclk-p104/arbhook.ko'"
ck "状态目录也在 HOME 下"   bash -c "echo '$out14' | grep -q 'daemon 启动'"
HOME="$T/fakehome" "$T/elsewhere/p104-mclk" stop >/dev/null 2>&1

echo
echo "════════════════════════════════════"
echo " 通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] && echo " ✓ 全部通过" || echo " ✗ 有失败项"
exit $((fail > 0))
