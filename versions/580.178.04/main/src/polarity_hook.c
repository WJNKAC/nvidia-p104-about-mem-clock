// SPDX-License-Identifier: GPL-2.0
/*
 * polarity_hook.c —— kretprobe 拦截 nvidia.ko 的 PolarityGet_2X，
 *                    按条件改写它的返回值，实现「空闲 405 / 满载 5005」
 *
 * ── 原理 ─────────────────────────────────────────────────────────
 *
 * nvidia.ko 的 30 类仲裁里，目标值只有两个端点：
 *
 *     perfLimits2xArbitrate_30(..., NvBool bSetValuesMin)
 *         if (bSetValuesMin) curValueToSet = range.minValue;   // MCLK 405
 *         else               curValueToSet = range.maxValue;   // MCLK 5005
 *
 * 而 bSetValuesMin 完全由 PolarityGet 的返回值决定：
 *
 *     NvBool PolarityGet_2X(pGpu, pPerf, pLimitMaskExclude)   // 返回 AL
 *
 * 它是独立函数（vtable 槽 0xb78 指向它），在 kallsyms 里可见（local text）。
 * 580.178.04 上：
 *     symbol_name = "_nv014972rm"
 *     离线 rva    = 0x898eb0
 *     返回值语义  = 1 → 取 min(405) ; 0 → 取 max(5005)
 *
 * 调用点（反汇编）：
 *     899b44  CALL __x86_indirect_thunk_rax    ; → _nv014972rm
 *     899b49  MOV  R8,R12
 *     899b4c  LEA  RCX,[RBP+0x60]
 *     899b50  MOV  RDX,RBX
 *     899b53  MOVZX R9D,AL                     ; ← 读返回值
 *     899b60  CALL _nv014901rm                 ; 仲裁，R9 = bSetValuesMin
 *
 * 中间有 3 条指令的空隙，kretprobe 的 trampoline 在这之后执行，
 * 改 regs->ax 能让 899b53 读到新值。
 *
 * ── 为什么不能简单恒返回 0 ───────────────────────────────────────
 *
 * bSetValuesMin 是**全局一个布尔**，管所有域。恒返回 0 ⇒ 所有域取 max
 * ⇒ 空闲也是 GPC 1911 / MCLK 5005 / 69W（就是方案 A 的副作用）。
 *
 * 所以必须**按负载切换**：
 *     空闲  → 返回原值(1) → 取 min → 139/405/7W   （P8，低功耗）
 *     满载  → 返回 0     → 取 max → 1911/5005     （P0，全性能）
 *
 * ── 模式 ─────────────────────────────────────────────────────────
 *
 *   mode=0  pass-through   完全不干预（默认，用于安全卸载前）
 *   mode=1  force_min      恒返回 1（取 405）—— 调试用
 *   mode=2  force_max      恒返回 0（取 5005）—— 验证 hook 是否生效
 *   mode=3  auto           按负载自动切换（目标模式）
 *
 * sysfs: /sys/kernel/p104_polarity/{mode,force,stat,override}
 *
 * ── auto 模式的判据 ──────────────────────────────────────────────
 *
 * 在 ret_handler 里拿不到 util（不知道 pPerf 内的偏移），
 * 但能拿到**函数参数**（pGpu/pPerf/mask）——entry_handler 里存下来。
 *
 * 本模块用两级判据，都不依赖 NVIDIA 内部结构：
 *
 *   (a) 显式 override：用户态写 0/1 到 sysfs，直接指定极性。
 *       最可靠，用于「跑计算前打开、跑完关闭」。
 *
 *   (b) 时间窗口自适应：由用户态喂「最近一次观察到负载的时刻」，
 *       模块在 N 秒内认为"忙"。用户态一个极小的轮询程序
 *       （读 nvidia-smi 的 utilization 或功耗）就能驱动它。
 *
 * 刻意**不做**内核内自动检测：nvidia.ko 的 pPerf 内部偏移属于未公开 ABI，
 * 换驱动版本就变，比 hook 本身更脆弱。
 *
 * ── 风险 ─────────────────────────────────────────────────────────
 *
 * 1. kprobe 会改写目标函数入口的前几字节（int3 + 单步）。
 *    nvidia.ko 若有代码完整性校验会检测到 —— 实测 580.178.04 没有。
 * 2. PolarityGet 在仲裁路径上，调用频率约几十 Hz，kprobe 开销可接受，
 *    但**不是零**。若发现帧时间/吞吐受影响，优先怀疑这里。
 * 3. 卸载模块前务必先 `echo 0 > mode`，让在途调用走原路径。
 * 4. 本模块只对 **580.178.04 的 30 类路径** 验证过。
 *    其他版本要重新确认符号名与返回值语义。
 */

#define pr_fmt(fmt) "p104_polarity: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/mutex.h>
#include <linux/jiffies.h>
#include <linux/version.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("nvidia-p104-set-mem-clock");
MODULE_DESCRIPTION("kretprobe hook on nvidia PolarityGet_2X: idle 405 / load 5005");
MODULE_VERSION("0.1.0");

/* 目标函数：580.178.04 的 _perfPerfLimitsArbitrateAndApplyPolarityGet_2X */
#define TARGET_SYMBOL   "_nv014972rm"

/* 模式 */
enum {
    MODE_PASSTHROUGH = 0,
    MODE_FORCE_MIN   = 1,
    MODE_FORCE_MAX   = 2,
    MODE_AUTO        = 3,
};

static int mode = MODE_PASSTHROUGH;
static int override = -1;          /* -1=不覆盖, 0=强制 max, 1=强制 min */
static unsigned long busy_window_ms = 2000;   /* 收到 busy 信号后视为忙的时长 */
static unsigned long busy_until;              /* jiffies */

/* 统计 */
static atomic64_t stat_calls    = ATOMIC64_INIT(0);
static atomic64_t stat_forced   = ATOMIC64_INIT(0);
static atomic64_t stat_passed   = ATOMIC64_INIT(0);
static atomic64_t stat_orig_min = ATOMIC64_INIT(0);
static atomic64_t stat_orig_max = ATOMIC64_INIT(0);
static atomic64_t stat_flags_off = ATOMIC64_INIT(0);
static atomic64_t stat_flags_on  = ATOMIC64_INIT(0);

static struct kretprobe krp;
static struct kobject *kobj;
static struct timer_list keepalive_timer;
static unsigned long keepalive_ms = 1000;     /* 0 = 关闭 */
static atomic64_t stat_keepalive = ATOMIC64_INIT(0);

/* ── 关键：直接改写 pPerf 的 perfmon flags ──────────────────────
 *
 * PolarityGet_2X(pGpu, pPerf, pLimitMaskExclude)
 *                        ↑ arg2 = RSI
 * 而 580 的 PolarityGet 内部就是读 pPerf+0x8e100：
 *     MOV  EAX,[pPerf+0x8e100]
 *     AND  EAX,0x5           ; bit0=PERFMON_ENABLED, bit2=NEEDED_BY_CLIENT
 *     CMP  EAX,0x1
 *     JNZ  → 极性 FALSE（取 max）
 *
 * 所以只要把 bit0 清掉，就等于"方案 A"（MaxPerfWithPerfMon=0）的
 * 运行时版本：
 *     PERFMON_ENABLED=0
 *       → 条件② 命中 → 极性 FALSE → curValueToSet = range.maxValue
 *       → 且 perfmon 停止采样 → 没有 util 数据
 *       → 那些依赖 util 把 MCLK range 压成单点的 limit 全部失效
 *       → MCLK 的 range 恢复成 [405, 5005] → 真正取到 5005
 *
 * ⚠ 这是本方案与"只改极性返回值"的根本区别：
 *   只改返回值 → 极性 max，但 range 仍被压 → MCLK 实际还是 405
 *               （clocks.mem 会**谎报** 5005，因为它报的是目标值，
 *                真实带宽仍是 19.3 GB/s）
 *   改 flags    → 极性 max + range 恢复 → MCLK 真的 5005
 */
#define PERF_FLAGS_OFFSET   0x8e100u
#define PERF_FLAG_ENABLED   (1u << 0)

static int  saved_bit0 = -1;      /* -1 = 尚未保存 */
static u32 *last_flags;           /* 最近一次看到的 flags，供卸载时恢复 */

static inline u32 *perf_flags(struct pt_regs *regs)
{
    /* arg2 = pPerf，在 x86_64 上是 RSI */
    unsigned long pperf = regs->si;
    if (!pperf)
        return NULL;
    return (u32 *)(pperf + PERF_FLAGS_OFFSET);
}

/* ---------------- 核心：是否要强制取 max ---------------- */

static bool want_max(void)
{
    /* 显式 override 最高优先 */
    if (override == 0)
        return true;
    if (override == 1)
        return false;

    switch (mode) {
    case MODE_FORCE_MIN: return false;
    case MODE_FORCE_MAX: return true;
    case MODE_AUTO:
        /* 在 busy 窗口内 ⇒ 认为有负载 ⇒ 取 max */
        return time_before(jiffies, READ_ONCE(busy_until));
    case MODE_PASSTHROUGH:
    default:
        return false;   /* 不干预（下面靠 sentinel 区分） */
    }
}

/* ---------------- keepalive 定时器 ----------------
 *
 * 实测发现：清掉 PERFMON_ENABLED 之后，那些依赖 util 把所有域 range
 * 压成单点的 limit 会**立刻失效**，MCLK 的 range 在几秒内从 [405,405]
 * 恢复成 [405,5005]，此时带宽能到 248~270 GB/s。
 *
 * 但这个恢复**不持久**：约 5 分钟后 range 又被压回去（带宽回 18.8）。
 *
 * 所以做法是**周期性续命**：定时器每 keepalive_ms 清一次 bit0，
 * 让"range 被放开"这个状态一直保持。
 *
 * ⚠ 代价：perfmon 持续停摆 ⇒ NVML 的 utilization 恒为 0。
 *    这正是方案 A 的副作用，这里一样有。但 MCLK 能上 5005。
 */
static void keepalive_fn(struct timer_list *t)
{
    bool active = (mode == MODE_FORCE_MAX) || (override == 0) ||
                  (mode == MODE_AUTO &&
                   time_before(jiffies, READ_ONCE(busy_until)));

    if (last_flags && keepalive_ms && active) {
        u32 v = READ_ONCE(*last_flags);
        if (v & PERF_FLAG_ENABLED) {
            WRITE_ONCE(*last_flags, v & ~PERF_FLAG_ENABLED);
            atomic64_inc(&stat_keepalive);
        }
        mod_timer(&keepalive_timer,
                  jiffies + msecs_to_jiffies(keepalive_ms));
    }
}

/* ---------------- kretprobe ---------------- */

static int entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    u32 *f;
    bool want_on;

    atomic64_inc(&stat_calls);

    f = perf_flags(regs);
    if (!f)
        return 0;
    last_flags = f;

    /* ── override=2：强制把 ENABLED 置回去（运行时"复活 perfmon"）────────
     * 用途：清过 bit0 之后，perfmon 停摆会让 GPU 常驻 P0/5005/70W，
     *       而且**模块卸载也恢复不了**（__exit 只是置位，RM 不重新 init）。
     *       实测踩过：rmmod 后 90 秒仍 70W。
     * 这里提供一条软件恢复路径，避免为了复位而重启整机。
     * 也用来回答一个关键问题：perfmon 到底能不能在运行时重启？
     */
    if (override == 2) {
        u32 v = READ_ONCE(*f);
        if (!(v & PERF_FLAG_ENABLED)) {
            WRITE_ONCE(*f, v | PERF_FLAG_ENABLED);
            atomic64_inc(&stat_flags_on);
        }
        return 0;
    }

    /* 不干预模式：若之前清过 ENABLED，在这里恢复 */
    if (mode == MODE_PASSTHROUGH && override < 0) {
        if (saved_bit0 > 0) {
            WRITE_ONCE(*f, READ_ONCE(*f) | PERF_FLAG_ENABLED);
            atomic64_inc(&stat_flags_on);
            saved_bit0 = -1;
        }
        return 0;
    }
    if (!(mode == MODE_AUTO || mode == MODE_FORCE_MAX || override == 0))
        return 0;

    /* 决定：这次要不要"模拟方案 A"（清 ENABLED） */
    want_on = (mode == MODE_FORCE_MAX) || (override == 0) ||
              (mode == MODE_AUTO && time_before(jiffies, READ_ONCE(busy_until)));

    if (want_on) {
        if (saved_bit0 < 0)
            saved_bit0 = (int)(READ_ONCE(*f) & PERF_FLAG_ENABLED);
        WRITE_ONCE(*f, READ_ONCE(*f) & ~PERF_FLAG_ENABLED);
        atomic64_inc(&stat_flags_off);
    } else {
        if (saved_bit0 > 0) {
            WRITE_ONCE(*f, READ_ONCE(*f) | PERF_FLAG_ENABLED);
            atomic64_inc(&stat_flags_on);
        }
    }
    return 0;
}

static int ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    /* x86_64 返回值在 ax；PolarityGet 返回 NvBool(1 字节)，用完整的 ax 判断 */
    unsigned long orig = regs_return_value(regs);

    if (orig)
        atomic64_inc(&stat_orig_min);
    else
        atomic64_inc(&stat_orig_max);

    if (mode == MODE_PASSTHROUGH && override < 0) {
        atomic64_inc(&stat_passed);
        return 0;
    }

    if (want_max()) {
        regs_set_return_value(regs, 0);   /* 0 ⇒ bSetValuesMin=FALSE ⇒ range.max */
        atomic64_inc(&stat_forced);
    } else {
        /* 要 min：原值若是 0 就改回 1；原本是 1 就不动 */
        if (!orig) {
            regs_set_return_value(regs, 1);
            atomic64_inc(&stat_forced);
        } else {
            atomic64_inc(&stat_passed);
        }
    }
    return 0;
}

/* ---------------- sysfs ---------------- */

static ssize_t mode_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
    return sysfs_emit(buf, "%d\n", mode);
}

static ssize_t mode_store(struct kobject *k, struct kobj_attribute *a,
                          const char *buf, size_t n)
{
    int v;
    if (kstrtoint(buf, 10, &v) || v < 0 || v > 3)
        return -EINVAL;
    WRITE_ONCE(mode, v);
    if (v == MODE_PASSTHROUGH)
        WRITE_ONCE(override, -1);
    pr_info("mode -> %d\n", v);
    return n;
}
static struct kobj_attribute attr_mode =
    __ATTR(mode, 0644, mode_show, mode_store);

static ssize_t override_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
    return sysfs_emit(buf, "%d\n", override);
}

static ssize_t override_store(struct kobject *k, struct kobj_attribute *a,
                              const char *buf, size_t n)
{
    int v;
    /* -1=不覆盖  0=强制max  1=强制min  2=强制恢复 ENABLED（复活 perfmon） */
    if (kstrtoint(buf, 10, &v) || v < -1 || v > 2)
        return -EINVAL;
    WRITE_ONCE(override, v);
    pr_info("override -> %d\n", v);
    return n;
}
static struct kobj_attribute attr_override =
    __ATTR(override, 0644, override_show, override_store);

static ssize_t busy_store(struct kobject *k, struct kobj_attribute *a,
                          const char *buf, size_t n)
{
    int v;
    if (kstrtoint(buf, 10, &v))
        return -EINVAL;
    if (v) {
        WRITE_ONCE(busy_until,
                   jiffies + msecs_to_jiffies(READ_ONCE(busy_window_ms)));
        /* 从 0 开始直接写无符号数会溢出，用 jiffies + clamp(1) */
        if (!READ_ONCE(busy_until))
            WRITE_ONCE(busy_until, jiffies + 1);
    } else {
        WRITE_ONCE(busy_until, 0);
    }
    return n;
}
static struct kobj_attribute attr_busy =
    __ATTR(busy, 0200, NULL, busy_store);

static ssize_t window_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
    return sysfs_emit(buf, "%lu\n", READ_ONCE(busy_window_ms));
}

static ssize_t window_store(struct kobject *k, struct kobj_attribute *a,
                            const char *buf, size_t n)
{
    unsigned long v;
    if (kstrtoul(buf, 10, &v) || v > 600000)
        return -EINVAL;
    WRITE_ONCE(busy_window_ms, v);
    return n;
}
static struct kobj_attribute attr_window =
    __ATTR(busy_window_ms, 0644, window_show, window_store);

static ssize_t stat_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
    return sysfs_emit(buf,
        "symbol      : %s\n"
        "mode        : %d  (0=pass 1=force_min 2=force_max 3=auto)\n"
        "override    : %d  (-1=off 0=max 1=min)\n"
        "busy_window : %lu ms\n"
        "calls       : %lld\n"
        "forced      : %lld\n"
        "passed      : %lld\n"
        "orig_min(1) : %lld\n"
        "orig_max(0) : %lld\n"
        "flags_off   : %lld   (清 PERFMON_ENABLED 的次数)\n"
        "flags_on    : %lld\n"
        "keepalive   : %lld   (定时器清 bit0 的次数)\n"
        "keepalive_ms: %lu   (0=关)\n",
        TARGET_SYMBOL, mode, override, READ_ONCE(busy_window_ms),
        (long long)atomic64_read(&stat_calls),
        (long long)atomic64_read(&stat_forced),
        (long long)atomic64_read(&stat_passed),
        (long long)atomic64_read(&stat_orig_min),
        (long long)atomic64_read(&stat_orig_max),
        (long long)atomic64_read(&stat_flags_off),
        (long long)atomic64_read(&stat_flags_on),
        (long long)atomic64_read(&stat_keepalive),
        READ_ONCE(keepalive_ms));
}
static struct kobj_attribute attr_stat =
    __ATTR(stat, 0444, stat_show, NULL);

static ssize_t ka_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
    return sysfs_emit(buf, "%lu\n", READ_ONCE(keepalive_ms));
}

static ssize_t ka_store(struct kobject *k, struct kobj_attribute *a,
                        const char *buf, size_t n)
{
    unsigned long v;
    if (kstrtoul(buf, 10, &v) || v > 60000)
        return -EINVAL;
    WRITE_ONCE(keepalive_ms, v);
    return n;
}
static struct kobj_attribute attr_ka =
    __ATTR(keepalive_ms, 0644, ka_show, ka_store);

static struct attribute *attrs[] = {
    &attr_mode.attr,
    &attr_override.attr,
    &attr_busy.attr,
    &attr_window.attr,
    &attr_stat.attr,
    &attr_ka.attr,
    NULL,
};
static struct attribute_group attr_group = { .attrs = attrs };

/* ---------------- init / exit ---------------- */

static int __init ph_init(void)
{
    int ret;

    memset(&krp, 0, sizeof(krp));
    krp.kp.symbol_name = TARGET_SYMBOL;
    krp.entry_handler  = entry_handler;
    krp.handler        = ret_handler;
    krp.maxactive      = 64;      /* PolarityGet 不会深递归，64 足够 */

    ret = register_kretprobe(&krp);
    if (ret) {
        pr_err("register_kretprobe(%s) 失败: %d\n", TARGET_SYMBOL, ret);
        pr_err("  检查：grep %s /proc/kallsyms （需要 root 才能看到地址）\n",
               TARGET_SYMBOL);
        pr_err("  该符号是 nvidia.ko 的 local text symbol，"
               "要求 CONFIG_KALLSYMS_ALL=y\n");
        return ret;
    }
    pr_info("kretprobe 已挂上 %s @ %px\n", TARGET_SYMBOL, krp.kp.addr);

    kobj = kobject_create_and_add("p104_polarity", kernel_kobj);
    if (!kobj) {
        unregister_kretprobe(&krp);
        return -ENOMEM;
    }
    ret = sysfs_create_group(kobj, &attr_group);
    if (ret) {
        kobject_put(kobj);
        unregister_kretprobe(&krp);
        return ret;
    }

    timer_setup(&keepalive_timer, keepalive_fn, 0);
    keepalive_timer.expires = jiffies + msecs_to_jiffies(1000);
    add_timer(&keepalive_timer);

    pr_info("就绪。默认 mode=0（不干预）。\n");
    pr_info("  验证 hook 生效: echo 2 > /sys/kernel/p104_polarity/mode\n");
    pr_info("  空闲/满载自动:  echo 3 > .../mode  （配合 busy 信号）\n");
    return 0;
}

static void __exit ph_exit(void)
{
    del_timer_sync(&keepalive_timer);

    /* 先把 ENABLED 恢复回去，否则卸载后 perfmon 永久停摆 */
    if (saved_bit0 > 0 && last_flags) {
        WRITE_ONCE(*last_flags, READ_ONCE(*last_flags) | PERF_FLAG_ENABLED);
        pr_info("已恢复 PERFMON_ENABLED\n");
        saved_bit0 = -1;
    }
    /* ⚠ 实测教训（2026-11-13）：上面这段"置回 bit0"在 unloading 时**不一定生效** ——
     *   曾出现 rmmod 后 90 秒仍 P0/5005/70W 的情况，最后靠重新 insmod +
     *   `override=2` + 一次 changeseq 才恢复 405/7.9W。
     *   所以卸载脚本必须：
     *     1) 先 echo 2 > override 并跑一次负载（确保 perfmon 真的活了）
     *     2) 确认 nvidia-smi 回到 P8/405 之后，再 rmmod
     *   直接 rmmod 有让 GPU 常驻高功耗的风险。
     */
    WRITE_ONCE(mode, MODE_PASSTHROUGH);
    WRITE_ONCE(override, -1);

    sysfs_remove_group(kobj, &attr_group);
    kobject_put(kobj);
    unregister_kretprobe(&krp);

    pr_info("已卸载。统计: calls=%lld forced=%lld passed=%lld\n",
            (long long)atomic64_read(&stat_calls),
            (long long)atomic64_read(&stat_forced),
            (long long)atomic64_read(&stat_passed));
}

module_init(ph_init);
module_exit(ph_exit);

module_param(mode, int, 0444);
MODULE_PARM_DESC(mode, "0=pass 1=force_min 2=force_max 3=auto");
