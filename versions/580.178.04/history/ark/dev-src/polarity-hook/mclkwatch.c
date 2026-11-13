/* mclkwatch.c —— 高频轮询 GPU 时钟，记录每一次变化
 *
 * 为什么需要它：
 *   nvidia-smi 一次要 100~300ms，用它 1~5 秒采一次会**漏掉短瞬态**。
 *   实测踩过：写 3000000 kHz 后硬件确实到了 2999 MHz，但只在 5 秒采样的
 *   间隙里存在过，于是被我误判成"值非法被硬件拒绝"。这是完全相反的结论。
 *
 * 做法：dlopen NVML，紧循环读 nvmlDeviceGetClockInfo(NVML_CLOCK_MEM/SM)，
 *       只在值变化时打印（带毫秒时间戳 + 保持时长），
 *       于是每次"跃迁"和它的"寿命"都能拿到。
 *
 * 用法：
 *   ./mclkwatch [秒数] [轮询间隔ms]
 *   ./mclkwatch 20 5        # 20 秒，5ms 轮询
 *
 * 输出：stderr（不干扰管道），每行一次跃迁：
 *   +1.234s  MEM 405 -> 2999  (held 0.087s)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>

typedef void *nvmlDevice_t;
typedef int (*fnInit)(void);
typedef int (*fnCnt)(unsigned int *);
typedef int (*fnHnd)(unsigned int, nvmlDevice_t *);
typedef int (*fnName)(nvmlDevice_t, char *, unsigned int);
typedef int (*fnClk)(nvmlDevice_t, int, unsigned int *);

#define NVML_CLOCK_GRAPHICS 0
#define NVML_CLOCK_SM       1
#define NVML_CLOCK_MEM      2

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    double dur = (argc > 1) ? atof(argv[1]) : 20.0;
    int    iv  = (argc > 2) ? atoi(argv[2]) : 5;   /* ms */
    void *h = dlopen("libnvidia-ml.so.1", RTLD_NOW);
    fnInit init; fnCnt cnt; fnHnd hnd; fnName getname; fnClk clk;
    nvmlDevice_t dev = NULL;
    unsigned int n = 0, i, mem = 0, sm = 0, pm = 0, ps = 0;
    double t0, t, tmem, tsm;
    long samples = 0;

    if (!h) h = dlopen("libnvidia-ml.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen NVML 失败\n"); return 1; }

    init    = (fnInit)dlsym(h, "nvmlInit_v2");
    cnt     = (fnCnt)dlsym(h, "nvmlDeviceGetCount_v2");
    hnd     = (fnHnd)dlsym(h, "nvmlDeviceGetHandleByIndex_v2");
    getname = (fnName)dlsym(h, "nvmlDeviceGetName");
    clk     = (fnClk)dlsym(h, "nvmlDeviceGetClockInfo");
    if (!init || !cnt || !hnd || !clk) { fprintf(stderr, "dlsym 失败\n"); return 1; }
    if (init() != 0 || cnt(&n) != 0 || n == 0) { fprintf(stderr, "NVML init/count 失败\n"); return 1; }

    /* 和 mclkctl 一样：按名字挑 P104，不盲取 index 0 */
    for (i = 0; i < n; i++) {
        nvmlDevice_t d; char nm[96] = {0};
        if (hnd(i, &d) != 0) continue;
        if (getname) getname(d, nm, sizeof(nm));
        if (strstr(nm, "P104")) { dev = d; 
            fprintf(stderr, "device: index=%u %s\n", i, nm); break; }
    }
    if (!dev) { fprintf(stderr, "没找到 P104\n"); return 1; }

    clk(dev, NVML_CLOCK_MEM, &mem);
    clk(dev, NVML_CLOCK_SM,  &sm);
    pm = mem; ps = sm;
    t0 = tmem = tsm = now_s();

    fprintf(stderr, "watch %.0fs, poll %dms, start MEM=%u SM=%u\n---\n", dur, iv, mem, sm);

    while (1) {
        t = now_s() - t0;
        if (t >= dur) break;
        clk(dev, NVML_CLOCK_MEM, &mem);
        clk(dev, NVML_CLOCK_SM,  &sm);
        samples++;

        if (mem != pm) {
            fprintf(stderr, "+%7.3fs  MEM %4u -> %-4u  (held %.3fs)\n",
                    t, pm, mem, t - tmem);
            pm = mem; tmem = t;
        }
        if (sm != ps) {
            fprintf(stderr, "+%7.3fs  SM  %4u -> %-4u  (held %.3fs)\n",
                    t, ps, sm, t - tsm);
            ps = sm; tsm = t;
        }
        usleep(iv * 1000);
    }

    fprintf(stderr, "---\nend: MEM=%u (held %.3fs)  SM=%u  (%ld samples, %.0f Hz)\n",
            mem, now_s() - tmem, sm, samples, samples / dur);
    return 0;
}
