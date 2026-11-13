// SPDX-License-Identifier: GPL-2.0
/*
 * phctl.c —— polarity_hook 的用户态控制器
 *
 * 用法：
 *   sudo ./phctl stat              看统计与当前模式
 *   sudo ./phctl mode 0|1|2|3      0=pass 1=force_min 2=force_max 3=auto
 *   sudo ./phctl busy              手动发一次"忙"信号
 *   sudo ./phctl on / off          快捷：auto 开 / pass 关
 *   sudo ./phctl verify            验证 hook：force_max → 看 MCLK → 复原
 *   sudo ./phctl daemon            自动模式守护（轮询负载 → 发 busy 信号）
 *
 * daemon 模式：
 *   每 200ms 用 NVML 读一次 GPU 利用率与功耗，
 *   超过阈值就向 /sys/kernel/p104_polarity/busy 写 1（续期 2 秒窗口）。
 *   负载停止后窗口自然过期 ⇒ 极性回 min ⇒ MCLK 405、P8、7W。
 *
 *   为什么用 NVML 而不是 nvidia-smi：后者每次要 fork+exec，约 100ms，
 *   0.2s 轮询会吃掉 50% 的单核。NVML 是进程内调用，几十微秒。
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

#define SYSFS_DIR "/sys/kernel/p104_polarity"

/* ---------------- NVML 最小声明（不依赖 SDK 头文件） ---------------- */

typedef void *nvmlDevice_t;

typedef struct {
    unsigned int gpu;
    unsigned int memory;
} nvmlUtilization_t;

typedef struct {
    unsigned int version;
    nvmlDevice_t device;
    unsigned long long timestamp;
    unsigned int delay;
} nvmlProcessUtilizationSample_t;

/* 只取我们需要的那几个 */
typedef int (*fnInit)(void);
typedef int (*fnGetCount)(unsigned int *);
typedef int (*fnGetHandle)(unsigned int, nvmlDevice_t *);
typedef int (*fnGetUtil)(nvmlDevice_t, nvmlUtilization_t *);
typedef int (*fnGetPower)(nvmlDevice_t, unsigned int *);

static struct {
    fnInit     Init;
    fnGetCount GetCount;
    fnGetHandle GetHandle;
    fnGetUtil  GetUtil;
    fnGetPower GetPower;
} nv;

static int nvml_load(void)
{
    void *h = dlopen("libnvidia-ml.so.1", RTLD_NOW);
    if (!h) h = dlopen("libnvidia-ml.so", RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen libnvidia-ml 失败: %s\n", dlerror());
        return -1;
    }
    nv.Init      = (fnInit)dlsym(h, "nvmlInit_v2");
    nv.GetCount  = (fnGetCount)dlsym(h, "nvmlDeviceGetCount_v2");
    nv.GetHandle = (fnGetHandle)dlsym(h, "nvmlDeviceGetHandleByIndex_v2");
    nv.GetUtil   = (fnGetUtil)dlsym(h, "nvmlDeviceGetUtilizationRates");
    nv.GetPower  = (fnGetPower)dlsym(h, "nvmlDeviceGetPowerUsage");
    if (!nv.Init || !nv.GetCount || !nv.GetHandle || !nv.GetUtil) {
        fprintf(stderr, "dlsym 关键函数失败\n");
        return -1;
    }
    if (nv.Init() != 0) {
        fprintf(stderr, "nvmlInit 失败\n");
        return -1;
    }
    return 0;
}

/* ---------------- sysfs 读写 ---------------- */

static int wr(const char *name, const char *val)
{
    char path[256];
    int fd;
    ssize_t n;

    snprintf(path, sizeof(path), SYSFS_DIR "/%s", name);
    fd = open(path, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "打开 %s 失败: %s\n", path, strerror(errno));
        fprintf(stderr, "  → 模块加载了吗？sudo insmod polarity_hook.ko\n");
        return -1;
    }
    n = write(fd, val, strlen(val));
    close(fd);
    if (n != (ssize_t)strlen(val)) {
        fprintf(stderr, "写 %s 失败: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

static void show(const char *name)
{
    char path[256], buf[4096];
    int fd;
    ssize_t n;

    snprintf(path, sizeof(path), SYSFS_DIR "/%s", name);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "打开 %s 失败: %s\n", path, strerror(errno));
        return;
    }
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n > 0) {
        buf[n] = 0;
        fputs(buf, stdout);
    }
}

/* ---------------- GPU 状态（用 NVML，避免 fork） ---------------- */

static int gpu_state(unsigned *util, unsigned *power_mw, unsigned *sm, unsigned *mem)
{
    static nvmlDevice_t dev;
    static int inited;
    nvmlUtilization_t u;

    if (!inited) {
        if (nvml_load() < 0) return -1;
        if (nv.GetCount(&(unsigned){0}) != 0) { /* warm-up */ }
        {
            unsigned cnt = 0;
            if (nv.GetCount(&cnt) != 0 || cnt == 0) return -1;
            if (nv.GetHandle(0, &dev) != 0) return -1;
        }
        inited = 1;
    }
    if (util && nv.GetUtil(dev, &u) == 0) *util = u.gpu;
    if (power_mw && nv.GetPower) {
        unsigned w = 0;
        if (nv.GetPower(dev, &w) == 0) *power_mw = w;
    }
    (void)sm; (void)mem;
    return 0;
}

/* ---------------- verify ---------------- */

static int cmd_verify(void)
{
    unsigned util = 0, pw = 0;
    int i;

    printf("== verify: 验证 kretprobe 是否真能改写 PolarityGet 返回值 ==\n");
    gpu_state(&util, &pw, NULL, NULL);
    printf("  before : util=%u%%  power=%u W\n", util, pw / 1000);
    printf("  若 MCLK 已是 5005，本测试看不出差异（先 echo 0 > mode 等 30s 让它回 405）\n\n");

    if (wr("mode", "2") < 0) return 1;
    printf("  已设 mode=2 (force_max)，等 3 秒…\n");
    sleep(3);
    printf("  -- 统计 --\n");
    show("stat");

    printf("\n  现在设 mode=1 (force_min)，等 3 秒…\n");
    wr("mode", "1");
    sleep(3);
    show("stat");

    printf("\n  恢复 mode=0 (pass)\n");
    wr("mode", "0");
    return 0;
}

/* ---------------- daemon ---------------- */

static volatile sig_atomic_t stop;

static void on_sig(int s) { (void)s; stop = 1; }

static int cmd_daemon(int util_thr, int power_thr_w, int interval_ms, int verbose)
{
    unsigned util, pw, last_util = 999, last_pw = 999;
    int busy = -1;

    printf("== daemon: util>%d%% 或 power>%dW 视为忙，轮询 %dms ==\n",
           util_thr, power_thr_w, interval_ms);
    printf("   busy 窗口由模块的 busy_window_ms 决定（默认 2000ms）\n");
    printf("   Ctrl-C 退出\n\n");

    if (wr("mode", "3") < 0) {
        fprintf(stderr, "设 mode=3 失败 —— 模块没加载？\n");
        return 1;
    }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    while (!stop) {
        unsigned u = 0, p = 0;
        int now_busy;

        if (gpu_state(&u, &p, NULL, NULL) < 0) {
            fprintf(stderr, "读 GPU 状态失败\n");
            break;
        }
        now_busy = (u >= (unsigned)util_thr) || ((int)(p / 1000) >= power_thr_w);

        if (now_busy) {
            wr("busy", "1");
            if (busy != 1) {
                printf("[%s] 忙: util=%u%% power=%uW → busy=1\n",
                       now_busy ? "BUSY" : "", u, p / 1000);
                busy = 1;
            }
        } else {
            if (busy != 0) {
                printf("[idle] util=%u%% power=%uW → 停止续期，窗口过期后回 405\n",
                       u, p / 1000);
                busy = 0;
            }
        }

        if (verbose && (u != last_util || p / 1000 != last_pw)) {
            printf("  util=%-3u%% power=%-4uW %s\n", u, p / 1000,
                   now_busy ? "BUSY" : "idle");
            last_util = u; last_pw = p / 1000;
        }

        usleep(interval_ms * 1000);
    }

    printf("\n  退出：恢复 mode=0\n");
    wr("mode", "0");
    return 0;
}

/* ---------------- main ---------------- */

static void usage(const char *p)
{
    printf(
"用法: sudo %s <命令> [参数]\n"
"\n"
"  stat                    看模块统计与当前模式\n"
"  mode 0|1|2|3            0=pass 1=force_min(405) 2=force_max(5005) 3=auto\n"
"  busy                    手动发一次忙信号（续期 busy 窗口）\n"
"  on / off                等价于 mode 3 / mode 0\n"
"  verify                  验证 hook 生效（force_max ↔ force_min 对照）\n"
"  daemon [util%%] [W] [ms] [v]\n"
"                          自动守护：util 或功耗超阈值就发忙信号\n"
"                          默认 5%% 30W 200ms（v=详细输出）\n"
"\n"
"典型用法:\n"
"  sudo %s daemon           # 挂上后一直跑，空闲 405 / 满载 5005\n"
"  sudo %s on               # 只开 auto，自己手动喂 busy\n"
"\n"
"⚠ 卸载模块前先 `%s mode 0`\n", p, p, p, p);
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "";

    if (!strcmp(cmd, "stat")) {
        show("stat");
    } else if (!strcmp(cmd, "mode") && argc > 2) {
        return wr("mode", argv[2]) < 0 ? 1 : 0;
    } else if (!strcmp(cmd, "busy")) {
        return wr("busy", "1") < 0 ? 1 : 0;
    } else if (!strcmp(cmd, "on")) {
        return wr("mode", "3") < 0 ? 1 : 0;
    } else if (!strcmp(cmd, "off")) {
        return wr("mode", "0") < 0 ? 1 : 0;
    } else if (!strcmp(cmd, "verify")) {
        return cmd_verify();
    } else if (!strcmp(cmd, "daemon")) {
        int util_thr = argc > 2 ? atoi(argv[2]) : 5;
        int pow_thr  = argc > 3 ? atoi(argv[3]) : 30;
        int interval = argc > 4 ? atoi(argv[4]) : 200;
        int verbose  = argc > 5 && argv[5][0] == 'v';
        return cmd_daemon(util_thr, pow_thr, interval, verbose);
    } else {
        usage(argv[0]);
        return 1;
    }
    return 0;
}
