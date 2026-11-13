# utils/gpu_ident.sh —— 显卡身份校验
#
# @ver    v1
# @since  2026-11-13
# @exports p104_gpu_check
#
# 为什么要这一层：
#   多卡机器上绝不能盲取 index 0 —— 那可能把别的卡当目标。
#   P104-100 是本项目唯一验证过的型号，其余一律拒绝并列出清单。
#   内核模块侧（mclkctl / p104_inject）也有独立的一份 NVML 校验，
#   两层都做是因为：脚本层能在加载模块**之前**就拦住，
#   避免"模块已 insmod 才发现卡不对"。

P104_TARGET_NAME=${P104_TARGET_NAME:-P104}

p104_gpu_check() {
    command -v nvidia-smi >/dev/null 2>&1 || { p104_bad "找不到 nvidia-smi"; return 1; }

    local names found=""
    names=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)
    [ -z "$names" ] && { p104_bad "nvidia-smi 枚举不到 GPU"; return 1; }

    while IFS= read -r nm; do
        case "$nm" in *"$P104_TARGET_NAME"*) found="$nm" ;; esac
    done <<< "$names"

    if [ -n "$found" ]; then
        p104_ok "目标卡：$found"
        return 0
    fi

    p104_bad "没有名字含 \"$P104_TARGET_NAME\" 的 GPU"
    printf '%s\n' "$names" | sed 's/^/      /'
    if [ "${P104_ALLOW_ANY:-0}" = "1" ]; then
        p104_warn "P104_ALLOW_ANY=1，继续（风险自负）"
        return 0
    fi
    p104_inf "本项目只在 P104-100 上验证过。确实要在别的卡上试：P104_ALLOW_ANY=1"
    return 1
}
