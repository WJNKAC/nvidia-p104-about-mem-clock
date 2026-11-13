// SPDX-License-Identifier: GPL-2.0
/*
 * mclkctl.c —— arbhook 的用户态控制器与负载自适应守护
 *
 * 用法（都要 root，因为要写 sysfs 的 mode）：
 *   sudo ./mclkctl stat          看状态
 *   sudo ./mclkctl dump          打印 clocks[] 结构（确认 stride/index）
 *   sudo ./mclkctl mode N        0=pass 1=always-max 2=auto
 *   sudo ./mclkctl busy          手动发一次 busy
 *   sudo ./mclkctl daemon        自动守护（推荐）
 *   sudo ./mclkctl daemon -v     带详细输出
 *
 * daemon 的判据：
 *   NVML utilization.gpu > 阈值（默认 5%）→ 发 busy
 *   负载停止 → 停止续期 → 2 秒窗口过期 → MCLK 回 405
 *
 * ⚠ 为什么不用功耗判据：busy=1 会把 MCLK 拉到 5005，空载功耗本身
 *    就升到 ~51W。用功耗做判据会形成正反馈，永远降不下来。
 *    utilization 是干净的（我们没关 perfmon，所以它准确）。
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <dlfcn.h>

#define SYSFS "/sys/kernel/p104_arb"

/* ---------- NVML 最小声明 ---------- */
typedef void *nvmlDevice_t;
typedef struct { unsigned int gpu, memory; } nvmlUtilization_t;
typedef int (*fnInit)(void);
typedef int (*fnCnt)(unsigned int *);
typedef int (*fnHnd)(unsigned int, nvmlDevice_t *);
typedef int (*fnName)(nvmlDevice_t, char *, unsigned int);
typedef int (*fnUtil)(nvmlDevice_t, nvmlUtilization_t *);

static nvmlDevice_t g_dev;
static fnUtil g_getUtil;
static int g_ready;

/* 目标卡识别：默认只认名字里含 "P104" 的（P104-100 是本项目唯一验证过的型号）。
 * 多卡机器上绝不能盲取 index 0 —— 那可能把别的卡当目标。
 * 可用环境变量 P104_ALLOW_ANY=1 放宽（用于有意在别的卡上试），但会明确警告。
 * P104_TARGET_NAME 只用于自测「拒绝路径」，正常不要设。
 */
#define TARGET_NAME_MATCH "P104"

static int g_idx = -1;

static const char *target_name(void)
{
    const char *e = getenv("P104_TARGET_NAME");
    return (e && *e) ? e : TARGET_NAME_MATCH;
}

static int nvml_open(void)
{
    void *h = dlopen("libnvidia-ml.so.1", RTLD_NOW);
    fnInit init; fnCnt cnt; fnHnd hnd; fnName getname;
    unsigned int n = 0, i;
    int allow_any = (getenv("P104_ALLOW_ANY") != NULL);
    const char *want = target_name();
    int fallback = -1;   /* 拿不到名字时记下第一张，仅用于报错 */

    if (!h) h = dlopen("libnvidia-ml.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen NVML 失败（装驱动了吗）\n"); return -1; }

    init      = (fnInit)dlsym(h, "nvmlInit_v2");
    cnt       = (fnCnt)dlsym(h, "nvmlDeviceGetCount_v2");
    hnd       = (fnHnd)dlsym(h, "nvmlDeviceGetHandleByIndex_v2");
    getname   = (fnName)dlsym(h, "nvmlDeviceGetName");
    g_getUtil = (fnUtil)dlsym(h, "nvmlDeviceGetUtilizationRates");
    if (!init || !cnt || !hnd || !g_getUtil) {
        fprintf(stderr, "dlsym 失败（NVML 版本不兼容？）\n"); return -1;
    }
    if (!getname)
        fprintf(stderr, "  ! 取不到 nvmlDeviceGetName，无法校验显卡身份\n");
    if (init() != 0) { fprintf(stderr, "nvmlInit 失败\n"); return -1; }
    if (cnt(&n) != 0 || n == 0) { fprintf(stderr, "NVML 报告 0 张 GPU\n"); return -1; }

    /* 逐张查名字，挑出目标卡 */
    for (i = 0; i < n; i++) {
        nvmlDevice_t d;
        char nm[96] = {0};
        if (hnd(i, &d) != 0) continue;
        if (fallback < 0) fallback = (int)i;
        if (getname && getname(d, nm, sizeof(nm)) != 0) nm[0] = 0;
        if (nm[0] && strstr(nm, want)) {
            g_dev = d; g_idx = (int)i;
            fprintf(stderr, "  目标卡: index=%u  name=%s\n", i, nm);
            g_ready = 1;
            return 0;
        }
    }

    /* 没找到 */
    fprintf(stderr, "✗ 没找到名字含 \"%s\" 的 GPU。\n", want);
    fprintf(stderr, "  本机 GPU 清单：\n");
    for (i = 0; i < n; i++) {
        nvmlDevice_t d;
        char nm[96] = {0};
        if (hnd(i, &d) != 0) continue;
        if (getname && getname(d, nm, sizeof(nm)) != 0) nm[0] = 0;
        fprintf(stderr, "    [%u] %s\n", i, nm[0] ? nm : "(取名失败)");
    }
    if (allow_any && fallback >= 0) {
        fprintf(stderr, "  ⚠ P104_ALLOW_ANY=1，退化为使用 index %d（可能不是目标卡！）\n",
                fallback);
        if (hnd((unsigned)fallback, &g_dev) == 0) {
            g_idx = fallback; g_ready = 1; return 0;
        }
    }
    fprintf(stderr, "  本项目只在 P104-100 上验证过。若确实要在别的卡上试：\n");
    fprintf(stderr, "    P104_ALLOW_ANY=1 %s ...\n", "mclkctl");
    return -1;
}

static int read_util(unsigned *u)
{
    nvmlUtilization_t x;
    if (!g_ready && nvml_open() < 0) return -1;
    if (g_getUtil(g_dev, &x) != 0) return -1;
    *u = x.gpu;
    return 0;
}

/* ---------- sysfs ---------- */
static int wr(const char *name, const char *val)
{
    char p[256]; int fd; ssize_t n;
    snprintf(p, sizeof(p), SYSFS "/%s", name);
    fd = open(p, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "打开 %s 失败: %s\n", p, strerror(errno));
        fprintf(stderr, "  模块加载了吗？sudo insmod arbhook.ko\n");
        return -1;
    }
    n = write(fd, val, strlen(val));
    close(fd);
    return (n == (ssize_t)strlen(val)) ? 0 : -1;
}

static void show(const char *name)
{
    char p[256], b[8192]; int fd; ssize_t n;
    snprintf(p, sizeof(p), SYSFS "/%s", name);
    fd = open(p, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "打开 %s 失败: %s\n", p, strerror(errno)); return; }
    n = read(fd, b, sizeof(b) - 1);
    close(fd);
    if (n > 0) { b[n] = 0; fputs(b, stdout); }
}

/* ---------- daemon ---------- */
static volatile sig_atomic_t g_stop;
static void onsig(int s) { (void)s; g_stop = 1; }

static int cmd_daemon(int thr, int interval_ms, int verbose)
{
    unsigned last = 999;
    int was_busy = -1;

    printf("== mclkctl daemon ==\n");

    /* 先校验显卡身份（NVML），再做任何写操作。
     * 顺序很重要：身份不对时必须在碰 sysfs 之前就拒绝。 */
    {
        unsigned tmp;
        if (read_util(&tmp) < 0) {
            fprintf(stderr, "✗ 显卡身份校验失败，拒绝启动\n");
            return 1;
        }
    }

    printf("   判据: utilization.gpu > %d%%  → 发 busy\n", thr);
    printf("   轮询: %d ms，busy 窗口在模块侧（默认 2000ms）\n", interval_ms);
    printf("   Ctrl-C 退出（会先把 mode 置 0）\n\n");

    if (wr("mode", "2") < 0) return 1;

    signal(SIGINT, onsig);
    signal(SIGTERM, onsig);

    while (!g_stop) {
        unsigned u = 0;
        int busy;

        if (read_util(&u) < 0) {
            fprintf(stderr, "读 utilization 失败，退出\n");
            break;
        }
        busy = (u > (unsigned)thr);

        if (busy) {
            wr("busy", "1");
            if (was_busy != 1) {
                printf("[busy] util=%u%%  → MCLK 5005\n", u);
                was_busy = 1;
            }
        } else if (was_busy != 0) {
            printf("[idle] util=%u%%  → 停止续期，窗口过期后回 405\n", u);
            was_busy = 0;
        }

        if (verbose && u != last) {
            printf("  util=%-3u%% %s\n", u, busy ? "BUSY" : "idle");
            last = u;
        }
        usleep(interval_ms * 1000);
    }

    printf("\n退出：mode -> 0\n");
    wr("mode", "0");
    return 0;
}

static void usage(const char *p)
{
    printf(
"用法: sudo %s <命令>\n"
"  stat            状态\n"
"  dump            打印 clocks[] 结构\n"
"  mode 0|1|2      0=pass 1=always-max 2=auto\n"
"  busy            手动发一次 busy（续期 2s）\n"
"  daemon [-t N] [-i MS] [-v]\n"
"                  自动守护，默认 util>5%% 判忙、200ms 轮询\n"
"\n典型：\n"
"  sudo insmod arbhook.ko\n"
"  sudo %s daemon          # 挂后台跑，空闲 7W / 满载 5005\n", p, p);
}

int main(int argc, char **argv)
{
    const char *c = argc > 1 ? argv[1] : "";

    if (!strcmp(c, "stat")) {
        unsigned tmp;
        if (read_util(&tmp) < 0) { fprintf(stderr, "✗ 显卡身份校验失败\n"); return 1; }
        show("stat"); return 0;
    }
    if (!strcmp(c, "dump")) {
        wr("dump", "1");
        usleep(800000);
        show("dump");
        return 0;
    }
    if (!strcmp(c, "mode") && argc > 2) return wr("mode", argv[2]) < 0;
    if (!strcmp(c, "busy"))             return wr("busy", "1") < 0;
    if (!strcmp(c, "daemon")) {
        int thr = 5, iv = 200, v = 0, i;
        for (i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "-t") && i + 1 < argc) thr = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-i") && i + 1 < argc) iv = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-v")) v = 1;
        }
        return cmd_daemon(thr, iv, v);
    }
    usage(argv[0]);
    return 1;
}
