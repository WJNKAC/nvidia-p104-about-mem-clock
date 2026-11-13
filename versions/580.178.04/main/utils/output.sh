# utils/output.sh —— 输出与提示（配色 / ok / bad / warn / inf）
#
# @ver    v1
# @since  2026-11-13
# @exports p104_ok p104_bad p104_warn p104_inf p104_hr
#
# 所有模块都依赖这几个函数，所以加载顺序上它必须最先。
# ⚠ 不要在本文件里引用其它 utils 模块 —— 会造成循环依赖。

if [ -t 1 ]; then
    P104_R=$'\033[31m'; P104_G=$'\033[32m'; P104_Y=$'\033[33m'; P104_N=$'\033[0m'
else
    P104_R=''; P104_G=''; P104_Y=''; P104_N=''
fi

p104_ok()   { printf "  ${P104_G}✓${P104_N} %s\n" "$*"; }
p104_bad()  { printf "  ${P104_R}✗${P104_N} %s\n" "$*"; }
p104_warn() { printf "  ${P104_Y}!${P104_N} %s\n" "$*"; }
p104_inf()  { printf "    %s\n" "$*"; }
p104_hr()   { printf '─%.0s' $(seq 1 46); printf '\n'; }
