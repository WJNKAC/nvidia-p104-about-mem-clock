// SPDX-License-Identifier: GPL-2.0
/*
 * arbhook.c —— kretprobe 拦截 perfLimits2xArbitrate_30 (_nv050524rm)，
 *              逐域覆盖 MCLK 的 curValueToSet
 *
 * ══ 这是「安全版」（v0.2.0-safe）══
 *
 * 历史教训（2026-11-13 17:20，实测导致整机 panic，必须记住）：
 *   曾经加过一个定时器，缓存 pArbOutput2x 地址后每 200ms 直接写
 *       *(u32*)(cached_addr + idx*0x24 + 0x50) = want;
 *
 *   pArbOutput2x 是**每次仲裁时新分配的临时结构**，实测地址每次都不同：
 *       ffff88bbbbb94c08 → ffff88bb99ed408 → ffff88bb3d26dc08
 *   缓存它再让定时器持续写 = 写野指针 → 内核内存损坏 → 整机 down。
 *
 *   ⇒ **只在 ret_handler 里写**。那时地址就是本次调用的有效参数，
 *     结构还活着。任何"事后再写"的方案都是野指针。
 *
 *   定时器也根本不需要：实测 ret_handler 单路径 + 用户态 daemon
 *   （150ms 轮询 utilization）已能正常切换：
 *       空闲 P8/139/405/7.9W  ←→  负载 P0/1911/5005/120W / 236 GB/s
 *   原因：仲裁虽常被 arbSeqId 缓存，但**每次 P-State 切换必然触发一次
 *   非缓存仲裁**，而"起负载/停负载"本身就是 P-State 切换。
 *
 * ── 为什么 hook 这层 ────────────────────────────────────────────
 *
 * PolarityGet 只返回一个布尔，真正写 curValueToSet 的是仲裁函数：
 *
 *     perfLimits2xArbitrate_30(pGpu, pPerf, pLimits2x,
 *                              pLimitMaskExclude, pArbOutput2x, bSetValuesMin)
 *                              rdi   rsi   rdx         rcx          r8      r9
 *
 * ⇒ pArbOutput2x = 第 5 个参数（r8），entry_handler 存下来即可。
 *
 * ── clocks[] 布局（本模块 dump 实测）──────────────────────────────
 *
 *     clk[0] @+0x50  min=278000  max=3518000  cur=278000
 *     clk[1] @+0x74  min=1088000 max=3391000  cur=1088000
 *     clk[2] @+0x98  min=405000  max=5005000  cur=405000   <-- MCLK
 *
 *   stride=0x24，curValueToSet@+0x50，range.min@+0x34，max@+0x38。
 *   MCLK 索引 = 2（靠 range.max ∈ [4990000,5100000] 自动探测）。
 *
 *   注意 clk[2] 的 min=405000 / max=5005000 —— **range 是完整的**。
 *   早期报告说"MCLK range 被压成 [405,405]"是错的（dump 抓在降档过程中）。
 *
 * ── 为什么改这里能生效 ─────────────────────────────────────────
 *
 * _nv014904rm 拿到 pArbOutput2x 后逐域跟前一份比较：
 *     if (*piVar10 != *piVar18) { bChanged = true; ... }
 * 改了值 ⇒ 比较不等 ⇒ 自动走完整下发路径，不需要额外递增 arbSeqId。
 *
 * ── 模式 ───────────────────────────────────────────────────────
 *   mode=0  只观察
 *   mode=1  恒把 MCLK 的 cur 改成 target_khz
 *   mode=2  auto：busy 窗口内 → target_khz；否则 → range.minValue（**双向**）
 *
 * ⚠ 必须双向。只往 5005 写不写回的话，缓存命中时不会重算，cur 会一直停在
 *   5005000，空闲也降不下来（实测踩过）。
 */

#define pr_fmt(fmt) "p104_arb: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/jiffies.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("kretprobe on perfLimits2xArbitrate_30: per-domain override of MCLK");
MODULE_VERSION("0.2.0-safe");

/* perfLimits2xArbitrate_30 @ 580.178.04, 离线 rva 0x8a2dd0 */
#define TARGET_SYMBOL   "_nv050524rm"

#define CLK_STRIDE      0x24u
#define CLK_CURVALUE    0x50u
#define CLK_RANGE_MIN   0x34u
#define CLK_RANGE_MAX   0x38u
#define CLK_MAX_ENTRIES 8u
/* 580.178.04 实测：MCLK 在 clk[2]。若 range.max 探测成功则以探测为准，
 * 探测失败时才退到该值（dump 用）。 */
#define MCLK_IDX_FALLBACK 2u

static unsigned int target_khz = 5005000;
static int mode = 0;
static int mclk_idx = -1;
static unsigned long busy_window_ms = 2000;
static unsigned long busy_until;

static atomic64_t stat_calls   = ATOMIC64_INIT(0);
static atomic64_t stat_patched = ATOMIC64_INIT(0);
static atomic64_t stat_flip    = ATOMIC64_INIT(0);   /* mode=3 制造的"伪变化"次数 */

#define DUMP_SEG   24        /* 最多连续记录多少次调用 */
#define DUMP_LINE  168
static char dumpbuf[DUMP_SEG * DUMP_LINE];
static DEFINE_MUTEX(dump_lock);
static bool dump_requested;
static int  dump_used;       /* 已写字节 */
static int  dump_count;      /* 已记录调用次数 */
static int  dump_target = 1; /* 目标次数，sysfs dump_n 可设 */

static struct kretprobe krp;
static struct kobject *kobj;

static void apply_override(void __iomem *arb);

static inline bool is_busy(void)
{
    if (!READ_ONCE(busy_until))
        return false;
    return time_before(jiffies, READ_ONCE(busy_until));
}

static void apply_override(void __iomem *arb)
{
    u32 *e, *cur, rmin, want, now;
    bool want_max;

    if (!arb || mclk_idx < 0)
        return;

    e    = (u32 *)((u8 *)arb + (unsigned int)mclk_idx * CLK_STRIDE);
    cur  = (u32 *)((u8 *)e + CLK_CURVALUE);
    rmin = READ_ONCE(*(u32 *)((u8 *)e + CLK_RANGE_MIN));

    if (mode == 1)
        want_max = true;
    else if (mode == 2 || mode == 3)
        want_max = is_busy();
    else if (mode == 5)
        want_max = is_busy();
    else
        return;                 /* mode=0：不干预 */

    want = want_max ? target_khz : rmin;
    if (!want)
        return;

    now = READ_ONCE(*cur);

    /* ── mode=5：先撑开 range.max，再制造伪变化 ────────────────────
     * 负载期 range 被收成 [5005000, 5005000]（dump 实测 SPAN=0）。
     * 此时写 5005001 会被 RM 按 range 钳回 5005000 ⇒ 与缓存相等 ⇒ 不下发。
     * 对照实验证明是"钳位"而非"通道失效"：
     *   写 3000000（在 range 内、≠cur）→ 硬件确实短暂到 2999 MHz（目击+高频采样）；
     *   写 5005001（超出 range.max）    → 34 秒纹丝不动（300Hz 采样零跃迁）。
     */
    if (mode == 5 && want_max) {
        u32 *rmax = (u32 *)((u8 *)e + CLK_RANGE_MAX);

        if (now == want) {
            if (READ_ONCE(*rmax) <= want)
                WRITE_ONCE(*rmax, want + 1000);
            WRITE_ONCE(*cur, want + 1);
            atomic64_inc(&stat_flip);
            return;
        }
        WRITE_ONCE(*cur, want);
        atomic64_inc(&stat_patched);
        return;
    }

    if (now != want) {
        /* 正常路径：值不同 ⇒ RM 判 changed ⇒ 走完整下发 */
        WRITE_ONCE(*cur, want);
        atomic64_inc(&stat_patched);
        return;
    }

    /* ── kick（mode=1/3）：cur 已经等于目标，但硬件没跟上 ───────────
     * 这是整个项目的死结：升档时 RM 自己算出的 cur 就是 5005，
     * 与它缓存的上一份相等 ⇒ 判定"没变化" ⇒ 根本不下发 ⇒ 硬件停在 405。
     * 想靠改值破局，但升档期 range 已塌成 [5005000, 5005000]，
     * 任何不同值都会被钳回来。
     *
     * 唯一能写进去且"看起来不同"的，只有 range.min（405000）：
     *   帧 A 写 405000 → 缓存被污染成低档
     *   帧 B RM 算 5005000 ≠ 缓存 405000 ⇒ 判 changed ⇒ 下发 5005
     * 升档那一段实测有十几次连续调用（calls 139→822→1607→1771→1911），
     * 足够走完 A→B。代价是帧 A 那一瞬硬件可能真的降档，但紧接着就被顶回。
     *
     * 实测支撑：把 MCLK 顶到 5005 之后它**粘得住** —— 后续整个 16 秒负载
     * 都保持 5005 / 267.8 GB/s，直到降档 changeseq 才回落。
     */
    if ((mode == 1 || mode == 3) && want_max && rmin && rmin != want) {
        WRITE_ONCE(*cur, rmin);
        atomic64_inc(&stat_flip);
    }
}

static int entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned long *d = (unsigned long *)ri->data;
    d[0] = regs->r8;            /* pArbOutput2x */
    atomic64_inc(&stat_calls);
    return 0;
}

static int ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned long *d = (unsigned long *)ri->data;
    void __iomem *arb = (void __iomem *)d[0];
    u32 *base;
    unsigned int i;
    int n;

    if (!arb)
        return 0;
    base = (u32 *)arb;

    /* 自动探测 MCLK：range.max 落在 4990~5100 MHz 那一档 */
    if (mclk_idx < 0) {
        for (i = 0; i < CLK_MAX_ENTRIES; i++) {
            u32 *e = (u32 *)((u8 *)base + i * CLK_STRIDE);
            u32 rmax = *(u32 *)((u8 *)e + CLK_RANGE_MAX);
            if (rmax >= 4990000u && rmax <= 5100000u) {
                mclk_idx = (int)i;
                pr_info("MCLK 探测: idx=%d range=[%u, %u]\n", i,
                        *(u32 *)((u8 *)e + CLK_RANGE_MIN), rmax);
                break;
            }
        }
    }

    if (unlikely(dump_requested)) {
        mutex_lock(&dump_lock);
        if (dump_used + DUMP_LINE < (int)sizeof(dumpbuf)) {
            u32 *e0 = (u32 *)((u8 *)base + 0 * CLK_STRIDE);
            int mx = (mclk_idx >= 0) ? mclk_idx : (int)MCLK_IDX_FALLBACK;
            u32 *em = (u32 *)((u8 *)base + mx * CLK_STRIDE);

            /* 一行一次调用：GPC(clk0) 与 MCLK 的 range/cur —— 看演进 */
            n = scnprintf(dumpbuf + dump_used, DUMP_LINE,
                "#%02d calls=%-6lld gpc[%u..%u c%u] mclk[%u..%u c%u]%s\n",
                dump_count,
                (long long)atomic64_read(&stat_calls),
                *(u32 *)((u8 *)e0 + CLK_RANGE_MIN),
                *(u32 *)((u8 *)e0 + CLK_RANGE_MAX),
                *(u32 *)((u8 *)e0 + CLK_CURVALUE),
                *(u32 *)((u8 *)em + CLK_RANGE_MIN),
                *(u32 *)((u8 *)em + CLK_RANGE_MAX),
                *(u32 *)((u8 *)em + CLK_CURVALUE),
                (*(u32 *)((u8 *)em + CLK_RANGE_MIN) ==
                 *(u32 *)((u8 *)em + CLK_RANGE_MAX)) ? "  SPAN=0" : "");
            dump_used += n;
            dump_count++;
        }
        if (dump_count >= dump_target ||
            dump_used + DUMP_LINE >= (int)sizeof(dumpbuf)) {
            *((char *)dumpbuf + (dump_used < (int)sizeof(dumpbuf) ?
                                 dump_used : (int)sizeof(dumpbuf) - 1)) = 0;
            dump_requested = false;
        }
        mutex_unlock(&dump_lock);
    }

    apply_override(arb);
    return 0;
}

/* ---------------- sysfs ---------------- */

static ssize_t mode_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", mode); }

static ssize_t mode_store(struct kobject *k, struct kobj_attribute *a,
                          const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v) || v < 0 || v > 5) return -EINVAL;
    WRITE_ONCE(mode, v);
    pr_info("mode -> %d\n", v);
    return n;
}
static struct kobj_attribute attr_mode = __ATTR(mode, 0644, mode_show, mode_store);

static ssize_t dump_show(struct kobject *k, struct kobj_attribute *a, char *b)
{
    int r;
    mutex_lock(&dump_lock);
    r = sysfs_emit(b, "%s", dumpbuf[0] ? dumpbuf : "(先 echo 1 > dump)\n");
    mutex_unlock(&dump_lock);
    return r;
}

static ssize_t dump_store(struct kobject *k, struct kobj_attribute *a,
                          const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v)) return -EINVAL;
    if (v) {
        mutex_lock(&dump_lock);
        dump_used = 0;
        dump_count = 0;
        dumpbuf[0] = 0;
        dump_requested = true;   /* 连续记录 dump_target 次调用 */
        mutex_unlock(&dump_lock);
    }
    return n;
}
static struct kobj_attribute attr_dump = __ATTR(dump, 0644, dump_show, dump_store);

/* dump_n：连续记录多少次调用（1..DUMP_SEG）。默认 1 = 只抓一帧。 */
static ssize_t dumpn_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", dump_target); }

static ssize_t dumpn_store(struct kobject *k, struct kobj_attribute *a,
                           const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v) || v < 1 || v > DUMP_SEG) return -EINVAL;
    WRITE_ONCE(dump_target, v);
    return n;
}
static struct kobj_attribute attr_dumpn =
    __ATTR(dump_n, 0644, dumpn_show, dumpn_store);

static ssize_t tgt_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%u\n", target_khz); }

static ssize_t tgt_store(struct kobject *k, struct kobj_attribute *a,
                         const char *b, size_t n)
{
    unsigned int v;
    if (kstrtouint(b, 10, &v) || v < 100000 || v > 8000000) return -EINVAL;
    WRITE_ONCE(target_khz, v);
    return n;
}
static struct kobj_attribute attr_tgt =
    __ATTR(target_khz, 0644, tgt_show, tgt_store);

static ssize_t idx_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", mclk_idx); }

static ssize_t idx_store(struct kobject *k, struct kobj_attribute *a,
                         const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v) || v < -1 || v > 15) return -EINVAL;
    WRITE_ONCE(mclk_idx, v);
    return n;
}
static struct kobj_attribute attr_idx =
    __ATTR(mclk_idx, 0644, idx_show, idx_store);

static ssize_t busy_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%d\n", is_busy() ? 1 : 0); }

static ssize_t busy_store(struct kobject *k, struct kobj_attribute *a,
                          const char *b, size_t n)
{
    int v;
    if (kstrtoint(b, 10, &v)) return -EINVAL;
    if (v)
        WRITE_ONCE(busy_until,
                   jiffies + msecs_to_jiffies(READ_ONCE(busy_window_ms)));
    else
        WRITE_ONCE(busy_until, 0);
    return n;
}
static struct kobj_attribute attr_busy = __ATTR(busy, 0644, busy_show, busy_store);

static ssize_t bw_show(struct kobject *k, struct kobj_attribute *a, char *b)
{ return sysfs_emit(b, "%lu\n", READ_ONCE(busy_window_ms)); }

static ssize_t bw_store(struct kobject *k, struct kobj_attribute *a,
                        const char *b, size_t n)
{
    unsigned long v;
    if (kstrtoul(b, 10, &v) || v > 600000) return -EINVAL;
    WRITE_ONCE(busy_window_ms, v);
    return n;
}
static struct kobj_attribute attr_bw =
    __ATTR(busy_window_ms, 0644, bw_show, bw_store);

static ssize_t stat_show(struct kobject *k, struct kobj_attribute *a, char *b)
{
    return sysfs_emit(b,
        "symbol     : %s\n"
        "mode       : %d  (0=pass 1=always+kick 2=auto 3=auto+kick 5=expand-range)\n"
        "target_khz : %u\n"
        "mclk_idx   : %d\n"
        "stride     : 0x%x  cur@0x%x\n"
        "calls      : %lld\n"
        "patched    : %lld\n"
        "flip       : %lld  (mode=3 制造的伪变化)\n"
        "busy       : %d   (window %lu ms)\n"
        "SAFE       : 只在 ret_handler 内写，无定时器\n",
        TARGET_SYMBOL, mode, target_khz, mclk_idx,
        CLK_STRIDE, CLK_CURVALUE,
        (long long)atomic64_read(&stat_calls),
        (long long)atomic64_read(&stat_patched),
        (long long)atomic64_read(&stat_flip),
        is_busy() ? 1 : 0, READ_ONCE(busy_window_ms));
}
static struct kobj_attribute attr_stat = __ATTR(stat, 0444, stat_show, NULL);

static struct attribute *attrs[] = {
    &attr_mode.attr, &attr_dump.attr, &attr_dumpn.attr, &attr_tgt.attr,
    &attr_idx.attr, &attr_busy.attr, &attr_bw.attr, &attr_stat.attr, NULL,
};
static struct attribute_group attr_group = { .attrs = attrs };

static int __init ah_init(void)
{
    int ret;

    memset(&krp, 0, sizeof(krp));
    krp.kp.symbol_name = TARGET_SYMBOL;
    krp.entry_handler  = entry_handler;
    krp.handler        = ret_handler;
    krp.data_size      = sizeof(unsigned long);
    krp.maxactive      = 32;

    ret = register_kretprobe(&krp);
    if (ret) {
        pr_err("register_kretprobe(%s) 失败: %d\n", TARGET_SYMBOL, ret);
        return ret;
    }
    pr_info("已挂上 %s @ %px（安全版：无定时器）\n",
            TARGET_SYMBOL, krp.kp.addr);

    kobj = kobject_create_and_add("p104_arb", kernel_kobj);
    if (!kobj) { unregister_kretprobe(&krp); return -ENOMEM; }
    ret = sysfs_create_group(kobj, &attr_group);
    if (ret) { kobject_put(kobj); unregister_kretprobe(&krp); return ret; }

    return 0;
}

static void __exit ah_exit(void)
{
    WRITE_ONCE(mode, 0);
    sysfs_remove_group(kobj, &attr_group);
    kobject_put(kobj);
    unregister_kretprobe(&krp);
    pr_info("已卸载。calls=%lld patched=%lld\n",
            (long long)atomic64_read(&stat_calls),
            (long long)atomic64_read(&stat_patched));
}

module_init(ah_init);
module_exit(ah_exit);
