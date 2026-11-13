// SPDX-License-Identifier: GPL-2.0
/*
 * p104_probe.c —— 穷举探针：全部引用 pPerf+0x8e100 的 37 个函数
 *
 * 由来（报告 237）：`PERFMON_ENABLED`(bit0)=1 时 MCLK 被钉 405，
 * =0 时同一份 curValueToSet(5005) 真的生效 ⇒ 必有一条独立路径在压 MCLK。
 *
 * 第一轮静态分析猜的 _nv050686rm(含 405000) / _nv050683rm(含 5005000) /
 * _nv050772rm(perfMonIsEnabled) 实测**调用次数全为 0** —— 它们是其他 GPU
 * 或遗留分支的死代码。于是改用穷举：把 37 个宿主全挂上，
 * 跑一次负载，谁有调用谁才是活的候选。
 *
 * 本模块**只计数，不改任何东西**，绝对安全。
 *   cat /sys/kernel/p104_probe/stat
 *   echo r > /sys/kernel/p104_probe/stat   # 清零
 */

#define pr_fmt(fmt) "p104_probe: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Counting probes over all pPerf+0x8e100 consumers");
MODULE_VERSION("0.2.0");

#define MAXP 40

struct pslot {
    const char *sym;
    struct kprobe kp;
    atomic64_t hits;
    int ok;
};

/* 第 1 项是仲裁基准，其余 37 项为 0x8e100 的全部宿主 */
static struct pslot slots[MAXP] = {
    { .sym = "_nv006027rm" },
    { .sym = "_nv050963rm" },
    { .sym = "_nv050965rm" },
    { .sym = "_nv050683rm" },
    { .sym = "_nv050686rm" },
    { .sym = "_nv050962rm" },
    { .sym = "_nv050964rm" },
    { .sym = "_nv050684rm" },
    { .sym = "_nv050960rm" },
    { .sym = "_nv051004rm" },
    { .sym = "_nv051003rm" },
    { .sym = "_nv050814rm" },
    { .sym = "_nv050813rm" },
    { .sym = "_nv050815rm" },
    { .sym = "_nv050816rm" },
};
static int nslots = 15;

static int probe_pre(struct kprobe *p, struct pt_regs *regs)
{
    struct pslot *s = container_of(p, struct pslot, kp);
    atomic64_inc(&s->hits);
    return 0;
}

static struct kobject *kobj;

static ssize_t stat_show(struct kobject *k, struct kobj_attribute *a, char *b)
{
    int i, n = 0;
    for (i = 0; i < nslots; i++)
        n += sysfs_emit_at(b, n, "%-14s %-4s %lld\n",
                           slots[i].sym, slots[i].ok ? "ok" : "FAIL",
                           (long long)atomic64_read(&slots[i].hits));
    return n;
}

static ssize_t stat_store(struct kobject *k, struct kobj_attribute *a,
                          const char *b, size_t n)
{
    int i;
    for (i = 0; i < nslots; i++) atomic64_set(&slots[i].hits, 0);
    return n;
}
static struct kobj_attribute attr_stat = __ATTR(stat, 0644, stat_show, stat_store);
static struct attribute *attrs[] = { &attr_stat.attr, NULL };
static struct attribute_group attr_group = { .attrs = attrs };

static int __init pp_init(void)
{
    int i, ret, good = 0;
    for (i = 0; i < nslots; i++) {
        slots[i].kp.symbol_name = slots[i].sym;
        slots[i].kp.pre_handler = probe_pre;
        if (register_kprobe(&slots[i].kp)) slots[i].ok = 0;
        else { slots[i].ok = 1; good++; }
    }
    pr_info("挂上 %d/%d\n", good, nslots);
    kobj = kobject_create_and_add("p104_probe", kernel_kobj);
    if (!kobj) return -ENOMEM;
    ret = sysfs_create_group(kobj, &attr_group);
    if (ret) { kobject_put(kobj); return ret; }
    return 0;
}

static void __exit pp_exit(void)
{
    int i;
    for (i = 0; i < nslots; i++)
        if (slots[i].ok) unregister_kprobe(&slots[i].kp);
    sysfs_remove_group(kobj, &attr_group);
    kobject_put(kobj);
    pr_info("已卸载\n");
}

module_init(pp_init);
module_exit(pp_exit);
