// SPDX-License-Identifier: GPL-2.0
/*
 * p104_inject.c —— 单点注入：只在指定函数入口清 PERFMON_ENABLED
 *
 * 目的（承接报告 237/238）：
 *   全局清 bit0 已知能让 MCLK 405→5005。但"到底哪一层被 perfmon 拦住"没定位。
 *   本模块把"清 bit0"这个动作**收窄到单个函数的入口**，逐一试：
 *     若在某函数注入就能让 MCLK 变 5005 ⇒ 该函数就是 perfmon 的闸门
 *     若所有单点都无效 ⇒ 说明影响在更底层（pstate table / clock domain 计算）
 *
 * 注入点（静态分析得到的 perfmon 守卫，都有 (flags&5)==1 && bit7 的条件）：
 *   site=1  _nv050963rm  dispatch，负载期 87~98 次
 *   site=2  _nv050965rm  per-domain setter，A 组 34 / B 组 6
 *   site=3  _nv050962rm  用 0x8e170/0x8e178
 *   site=4  _nv050771rm  perfPerfMonInit（对照：已知能改初始状态）
 *   site=5  _nv058409rm  频率换算
 *
 * 用法：
 *   insmod p104_inject.ko site=2
 *   cat /sys/kernel/p104_inject/stat
 *   echo 1 > /sys/kernel/p104_inject/enable   # 开始注入
 *   echo 0 > /sys/kernel/p104_inject/enable   # 停止（并尝试把 bit0 置回）
 *
 * ⚠ 安全：pre_handler 里只对 pPerf+0x8e100 做一次位清零，
 *    与已验证安全的 polarity_hook 是同一个操作，且不缓存任何指针。
 */

#define pr_fmt(fmt) "p104_inject: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Single-site PERFMON_ENABLED injection to locate the gate");
MODULE_VERSION("0.1.0");

#define PERF_FLAGS_OFFSET 0x8e100u
#define PERF_FLAG_ENABLED 1u

static int site = 2;
module_param(site, int, 0644);
MODULE_PARM_DESC(site, "1=_nv050963rm 2=_nv050965rm 3=_nv050962rm 4=_nv050771rm 5=_nv058409rm");

static struct kprobe kp;
static struct kobject *kobj;
static int  enable;
static int  force;            /* 1 = 无条件清（不管当前值） */
static u32 *last_flags;                 /* 仅用于停止时置回 */
static atomic64_t n_hit = ATOMIC64_INIT(0);
static atomic64_t n_off = ATOMIC64_INIT(0);
static atomic64_t n_seen = ATOMIC64_INIT(0);

static const char *site_name(int s)
{
    switch (s) {
    case 1: return "_nv050963rm";
    case 2: return "_nv050965rm";
    case 3: return "_nv050962rm";
    case 4: return "_nv050771rm";
    case 5: return "_nv058409rm";
    }
    return "?";
}

static int inj_pre(struct kprobe *p, struct pt_regs *regs)
{
    u32 *f;

    atomic64_inc(&n_hit);

    /* _nv050xxx(pGpu=rdi, pPerf=rsi, ...) ⇒ pPerf 在 rsi */
    if (!regs->si)
        return 0;
    f = (u32 *)(regs->si + PERF_FLAGS_OFFSET);
    last_flags = f;

    if (READ_ONCE(enable)) {
        u32 v = READ_ONCE(*f);
        /* force=1 时不再"看当前值决定要不要清" —— 无条件清，
         * 这样才能对抗"别处周期性把 bit0 置回"的行为。
         * 这是验证"闸门是周期性重置"假设的关键（报告 238 §4.2）。
         */
        if (READ_ONCE(force) || (v & PERF_FLAG_ENABLED)) {
            if (v & PERF_FLAG_ENABLED) {
                WRITE_ONCE(*f, v & ~PERF_FLAG_ENABLED);
                atomic64_inc(&n_off);
            }
            atomic64_inc(&n_seen);
        }
    }
    return 0;
}

static ssize_t stat_show(struct kobject *k, struct kobj_attribute *a, char *b)
{
    return sysfs_emit(b,
        "site       : %d (%s)\n"
        "enable     : %d\n"
        "force      : %d\n"
        "hits       : %lld\n"
        "seen_off   : %lld\n"
        "cleared    : %lld\n",
        site, site_name(site), READ_ONCE(enable), READ_ONCE(force),
        (long long)atomic64_read(&n_hit),
        (long long)atomic64_read(&n_seen),
        (long long)atomic64_read(&n_off));
}

static ssize_t stat_store(struct kobject *k, struct kobj_attribute *a,
                          const char *b, size_t n)
{
    atomic64_set(&n_hit, 0);
    atomic64_set(&n_off, 0);
    atomic64_set(&n_seen, 0);
    return n;
}
static struct kobj_attribute attr_stat = __ATTR(stat, 0644, stat_show, stat_store);

static ssize_t en_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", READ_ONCE(enable)); }

static ssize_t en_store(struct kobject *k, struct kobj_attribute *a,
                        const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v)) return -EINVAL;
    WRITE_ONCE(enable, v ? 1 : 0);
    /* 停止注入时把 bit0 置回去，避免 perfmon 永久停摆 */
    if (!v && last_flags) {
        u32 cur = READ_ONCE(*last_flags);
        if (!(cur & PERF_FLAG_ENABLED))
            WRITE_ONCE(*last_flags, cur | PERF_FLAG_ENABLED);
    }
    return n;
}
static struct kobj_attribute attr_en = __ATTR(enable, 0644, en_show, en_store);

static ssize_t fo_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", READ_ONCE(force)); }
static ssize_t fo_store(struct kobject *k, struct kobj_attribute *a,
                        const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v)) return -EINVAL;
    WRITE_ONCE(force, v ? 1 : 0);
    return n;
}
static struct kobj_attribute attr_fo = __ATTR(force, 0644, fo_show, fo_store);

static struct attribute *attrs[] = { &attr_stat.attr, &attr_en.attr, &attr_fo.attr, NULL };
static struct attribute_group attr_group = { .attrs = attrs };

static int __init inj_init(void)
{
    int ret;

    kp.symbol_name = site_name(site);
    kp.pre_handler = inj_pre;
    ret = register_kprobe(&kp);
    if (ret) {
        pr_err("挂不上 %s (%d)\n", kp.symbol_name, ret);
        return ret;
    }
    pr_info("已挂 %s\n", kp.symbol_name);

    kobj = kobject_create_and_add("p104_inject", kernel_kobj);
    if (!kobj) { unregister_kprobe(&kp); return -ENOMEM; }
    ret = sysfs_create_group(kobj, &attr_group);
    if (ret) { kobject_put(kobj); unregister_kprobe(&kp); return ret; }
    return 0;
}

static void __exit inj_exit(void)
{
    if (last_flags) {
        u32 cur = READ_ONCE(*last_flags);
        if (!(cur & PERF_FLAG_ENABLED))
            WRITE_ONCE(*last_flags, cur | PERF_FLAG_ENABLED);
    }
    sysfs_remove_group(kobj, &attr_group);
    kobject_put(kobj);
    unregister_kprobe(&kp);
    pr_info("已卸载（hits=%lld cleared=%lld）\n",
            (long long)atomic64_read(&n_hit),
            (long long)atomic64_read(&n_off));
}

module_init(inj_init);
module_exit(inj_exit);
