/*
 * p104-set-mem-clock — 通过 reserve perfmon 翻转 P104 的时钟极性
 *
 * 原理（详见 docs/mechanism.md）：
 *   PolarityGet_2X 的三条件之一是
 *       PERFMON_IS_FLAG_SET(PERFMON_NEEDED_BY_CLIENT) || !PERFMON_IS_FLAG_SET(PERFMON_ENABLED)
 *   任一成立 ⇒ bSetValuesMin = FALSE ⇒ curValueToSet = range.maxValue。
 *   而 PERFMON_NEEDED_BY_CLIENT 全树唯一的置位点是
 *       perfPerfMonReserveWithClient(take = TRUE)          [perfmon.c:876]
 *   对应控制命令
 *       NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW   (0x20802093)
 *   参数
 *       NV2080_CTRL_PERF_RESERVE_PERFMON_HW_PARAMS { NvBool bAcquire; }
 *
 *   ⇒ 本程序 acquire 后，极性维持 FALSE，MCLK 取 5005；
 *     release（或进程退出触发 client 销毁）后，极性回 TRUE，MCLK 回 405。
 *
 * 权限：内核侧 subdeviceCtrlCmdPerfReservePerfmonHw_KERNEL 里有
 *       if (gpuIsRmProfilingPrivileged(pGpu) && !osIsAdministrator())
 *           return NV_ERR_INSUFFICIENT_PERMISSIONS;
 *       ⇒ 需要 root 运行。
 *
 * 用法：
 *   sudo ./p104-set-mem-clock               # acquire 后常驻，Ctrl-C 时 release
 *   sudo ./p104-set-mem-clock --seconds 30  # 保持 30 秒后自动 release
 *   sudo ./p104-set-mem-clock --probe       # 只测通道：acquire → release → 退出
 *   sudo ./p104-set-mem-clock --release     # 仅尝试释放（用于清理残留）
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/types.h>

/* ------------------------------------------------------------------ *
 * 基础类型（与 NVIDIA RM UAPI 双字宽度一致）
 * ------------------------------------------------------------------ */
typedef unsigned int       NvU32;
typedef unsigned int       NvHandle;
typedef int                NvV32;
typedef unsigned long long NvU64;
typedef void *             NvP64;
typedef unsigned char      NvBool;

/* ------------------------------------------------------------------ *
 * 版本相关 ABI —— 全部集中在 abi.h
 *   换驱动版本时只改 abi.h；每个 versions/<版本>/ 都有一份冻结副本。
 * ------------------------------------------------------------------ */
#include "abi.h"

#define NV_OK                  0x00000000

/* ------------------------------------------------------------------ *
 * 参数结构（nvos.h / cl0080.h / cl2080.h / ctrl2080perf.h）
 * ------------------------------------------------------------------ */
/* NVOS64_PARAMETERS —— 形态由 abi.h 的 NVOS64_HAS_PARAMSSIZE 决定
 *
 * 48 字节版（580 实测，strace: alloc size=0x30）
 *   比 510 头文件的 40 字节版多了 paramsSize / flags。
 *   选错的症状很隐蔽：alloc 返回 NV_OK 但 hObjectNew 不回填
 *   （subdevice handle = 0），后续 control 才报 0x57。 */
#if NVOS64_HAS_PARAMSSIZE
typedef struct {
    NvHandle hRoot;
    NvHandle hObjectParent;
    NvHandle hObjectNew;
    NvV32    hClass;
    NvP64    pAllocParms;
    NvP64    pRightsRequested;
    NvU32    paramsSize;
    NvU32    flags;
    NvV32    status;
} NVOS64_PARAMETERS;
#else
typedef struct {
    NvHandle hRoot;
    NvHandle hObjectParent;
    NvHandle hObjectNew;
    NvV32    hClass;
    NvP64    pAllocParms;
    NvP64    pRightsRequested;
    NvV32    status;
} NVOS64_PARAMETERS;
#endif

typedef struct {
    NvHandle hClient;
    NvHandle hObject;
    NvV32    cmd;
    NvU32    flags;
    NvP64    params;
    NvU32    paramsSize;
    NvV32    status;
} NVOS54_PARAMETERS;

typedef struct {
    NvU32    deviceId;
    NvHandle hClientShare;
    NvHandle hTargetClient;
    NvHandle hTargetDevice;
    NvV32    flags;
    NvU64    vaSpaceSize;
    NvU64    vaStartInternal;
    NvU64    vaLimitInternal;
    NvV32    vaMode;
} NV0080_ALLOC_PARAMETERS;

typedef struct {
    NvU32 subDeviceId;
} NV2080_ALLOC_PARAMETERS;

typedef struct {
    NvBool bAcquire;
} NV2080_CTRL_PERF_RESERVE_PERFMON_HW_PARAMS;

/* ------------------------------------------------------------------ *
 * ioctl 请求号
 * ------------------------------------------------------------------ */
#define IOCTL_RM_ALLOC \
    _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, NVOS64_PARAMETERS)
#define IOCTL_RM_CONTROL \
    _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54_PARAMETERS)
#define IOCTL_RM_FREE \
    _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, void *)

/* ------------------------------------------------------------------ *
 * client 上下文
 * ------------------------------------------------------------------ */
typedef struct {
    int      fd;        /* /dev/nvidiactl */
    int      fd_gpu;    /* /dev/nvidia0 —— 必须在 alloc device 之前打开，
                         * 否则驱动侧 GPU 未完成 RM 初始化，alloc 报 0x1b */
    NvHandle hClient;
    NvHandle hDevice;
    NvHandle hSubdevice;
} rm_ctx;

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static const char *nv_status_str(int s)
{
    switch (s) {
    case 0x00000000: return "NV_OK";
    case 0x00000001: return "NV_ERR_INVALID_CLASS / GENERIC";
    case 0x00000002: return "NV_ERR_NOT_SUPPORTED";
    case 0x00000003: return "NV_ERR_NOT_CONFIGURED";
    case 0x00000004: return "NV_ERR_IN_USE";
    case 0x00000005: return "NV_ERR_INVALID_STATE";
    case 0x00000006: return "NV_ERR_INSUFFICIENT_RESOURCES";
    case 0x0000000B: return "NV_ERR_INVALID_ARGUMENT";
    case 0x00000011: return "NV_ERR_INSUFFICIENT_PERMISSIONS";
    case 0x00000019: return "NV_ERR_INVALID_OBJECT_HANDLE";
    case 0x0000001B: return "NV_ERR_INVALID_OBJECT_PARENT（多发于未先 open /dev/nvidia0）";
    case 0x00000057: return "NV_ERR_INVALID_OBJECT_HANDLE（多发于 subdevice alloc 未回填 handle）";
    case 0x00000063: return "NV_ERR_STATE_IN_USE（perfmon 已被其他客户端占用）";
    default:         return "?";
    }
}

/* pAllocParms 的字节数：驱动侧会按这个长度校验/拷贝 */
static NvU32 alloc_parms_size(NvV32 klass)
{
#if ABI_ALLOC_PARMS_SIZE_BY_CLASS
    switch (klass) {
    case NV01_ROOT_CLIENT: return 0;                                   /* 无参数 */
    case NV01_DEVICE_0:    return (NvU32)sizeof(NV0080_ALLOC_PARAMETERS);
    case NV20_SUBDEVICE_0: return (NvU32)sizeof(NV2080_ALLOC_PARAMETERS);
    default:               return 0;
    }
#else
    (void)klass;
    return 0;
#endif
}

/* ------------------------------------------------------------------ *
 * 逐级 alloc：root client → device → subdevice
 * ------------------------------------------------------------------ */
static int rm_alloc(rm_ctx *c, NvHandle parent, NvHandle *out,
                    NvV32 klass, NvP64 parms, const char *what)
{
    NVOS64_PARAMETERS a;

    memset(&a, 0, sizeof(a));
    a.hRoot            = c->hClient;
    a.hObjectParent    = parent;
    a.hObjectNew       = 0;
    a.hClass           = klass;
    a.pAllocParms      = parms;
    a.pRightsRequested = NULL;
    a.paramsSize       = parms ? alloc_parms_size(klass) : 0;
    a.flags            = 0;
    a.status           = 0;

    if (ioctl(c->fd, IOCTL_RM_ALLOC, &a) < 0) {
        fprintf(stderr, "  [alloc %s] ioctl 失败: %s (errno=%d)\n",
                what, strerror(errno), errno);
        return -1;
    }
    if (a.status != NV_OK) {
        fprintf(stderr, "  [alloc %s] status=0x%08x (%s)\n",
                what, a.status, nv_status_str(a.status));
        return -1;
    }
    *out = a.hObjectNew;
    fprintf(stderr, "  [alloc %s] ok  handle=0x%08x\n", what, *out);
    return 0;
}

static int rm_open(rm_ctx *c)
{
    NV0080_ALLOC_PARAMETERS dev;
    NV2080_ALLOC_PARAMETERS sub;

    memset(c, 0, sizeof(*c));
    c->fd = -1;
    c->fd_gpu = -1;

    c->fd = open("/dev/nvidiactl", O_RDWR);
    if (c->fd < 0) {
        fprintf(stderr, "打开 /dev/nvidiactl 失败: %s\n", strerror(errno));
        return -1;
    }

    /* 1. root client —— pAllocParms 传 NULL；此时 c->hClient 尚为 0，
     *    故 rm_alloc 内部的 a.hRoot = 0，正是 root client 要求的取值。
     *    返回后 c->hClient 被赋值，后续 alloc 都拿它当 hRoot。 */
    if (rm_alloc(c, 0, &c->hClient, NV01_ROOT_CLIENT, NULL, "root client") < 0)
        goto fail;

#if ABI_NEED_OPEN_GPU_NODE
    /* 2. 先打开 /dev/nvidia0 —— 让驱动完成该 GPU 的 RM 初始化。
     *    实测：不打开直接 alloc device 会返回 0x1b。 */
    c->fd_gpu = open("/dev/nvidia0", O_RDWR);
    if (c->fd_gpu < 0)
        fprintf(stderr, "  警告：打开 /dev/nvidia0 失败 (%s)，继续尝试\n",
                strerror(errno));
    else
        fprintf(stderr, "  [open /dev/nvidia0] ok\n");
#endif

    /* 3. device */
    memset(&dev, 0, sizeof(dev));
    dev.deviceId = 0;
    if (rm_alloc(c, c->hClient, &c->hDevice, NV01_DEVICE_0,
                 (NvP64)&dev, "device") < 0)
        goto fail;

    /* 4. subdevice */
    memset(&sub, 0, sizeof(sub));
    sub.subDeviceId = 0;
    if (rm_alloc(c, c->hDevice, &c->hSubdevice, NV20_SUBDEVICE_0,
                 (NvP64)&sub, "subdevice") < 0)
        goto fail;

    return 0;

fail:
    if (c->fd_gpu >= 0) close(c->fd_gpu);
    if (c->fd >= 0) close(c->fd);
    c->fd = c->fd_gpu = -1;
    return -1;
}

static void rm_close(rm_ctx *c)
{
    if (c->fd_gpu >= 0) {
        close(c->fd_gpu);
        c->fd_gpu = -1;
    }
    if (c->fd >= 0) {
        /* 关 fd 会销毁 client，RM 侧随之清理 perfmon_reserve 状态 */
        close(c->fd);
        c->fd = -1;
    }
}

/* ------------------------------------------------------------------ *
 * 核心：acquire / release perfmon
 * ------------------------------------------------------------------ */
static int perfmon_reserve(rm_ctx *c, int acquire)
{
    NVOS54_PARAMETERS p;
    NV2080_CTRL_PERF_RESERVE_PERFMON_HW_PARAMS arg;

    arg.bAcquire = acquire ? 1 : 0;

    memset(&p, 0, sizeof(p));
    p.hClient    = c->hClient;
    p.hObject    = c->hSubdevice;
    p.cmd        = NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW;
    p.flags      = 0;
    p.params     = (NvP64)&arg;
    p.paramsSize = sizeof(arg);
    p.status     = 0;

    if (ioctl(c->fd, IOCTL_RM_CONTROL, &p) < 0) {
        fprintf(stderr, "  [perfmon %s] ioctl 失败: %s (errno=%d)\n",
                acquire ? "acquire" : "release", strerror(errno), errno);
        return -1;
    }
    if (p.status != NV_OK) {
        fprintf(stderr, "  [perfmon %s] status=0x%08x (%s)\n",
                acquire ? "acquire" : "release",
                p.status, nv_status_str(p.status));
        return -1;
    }
    fprintf(stderr, "  [perfmon %s] ok\n", acquire ? "acquire" : "release");
    return 0;
}

/* ------------------------------------------------------------------ *
 * 便捷：读 MEM 频率（用 NVML 太重，改读 nvidia-smi 文本）
 * ------------------------------------------------------------------ */
static int read_mem_mhz(int *sm, int *mem, char *pstate, size_t pn)
{
    FILE *f = popen(
        "nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem "
        "--format=csv,noheader,nounits 2>/dev/null", "r");
    int s = -1, m = -1;
    char ps[16] = "?";

    if (!f) return -1;
    if (fscanf(f, " %15[^,], %d, %d", ps, &s, &m) != 3) {
        pclose(f);
        return -1;
    }
    pclose(f);
    if (sm) *sm = s;
    if (mem) *mem = m;
    if (pstate && pn) snprintf(pstate, pn, "%s", ps);
    return 0;
}

static void print_state(const char *tag)
{
    int sm = -1, mem = -1;
    char ps[16] = "?";

    if (read_mem_mhz(&sm, &mem, ps, sizeof(ps)) == 0)
        printf("  %-22s %s  SM=%-5d MEM=%-5d %s\n",
               tag, ps, sm, mem,
               (mem >= 5000 ? "<-- 5005 生效" : (mem > 0 && mem <= 405 ? "<-- 405" : "")));
    else
        printf("  %-22s (nvidia-smi 读取失败)\n", tag);
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    rm_ctx c;
    int i;
    int seconds = -1;
    int probe = 0;
    int release_only = 0;
    int rc = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--probe")) {
            probe = 1;
        } else if (!strcmp(argv[i], "--release")) {
            release_only = 1;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf(
"用法: sudo %s [选项]\n"
"  (无选项)         acquire 后常驻，Ctrl-C / SIGTERM 时 release\n"
"  --seconds N      保持 N 秒后自动 release\n"
"  --probe          只验证通道：acquire → release → 退出\n"
"  --release        仅尝试 release（清理残留）\n"
"\n"
"原理: 置位 PERFMON_NEEDED_BY_CLIENT ⇒ PolarityGet 条件② 命中\n"
"      ⇒ bSetValuesMin=FALSE ⇒ MCLK 取 range.maxValue=5005\n", argv[0]);
            return 0;
        } else {
            fprintf(stderr, "未知参数: %s（用 --help）\n", argv[i]);
            return 2;
        }
    }

    if (geteuid() != 0)
        fprintf(stderr, "⚠ 非 root：内核侧有 osIsAdministrator() 检查，"
                        "大概率返回 NV_ERR_INSUFFICIENT_PERMISSIONS\n\n");

    printf("== ABI: driver %s, NVOS64=%zuB, paramsSize@%s ==\n",
           P104_ABI_DRIVER, sizeof(NVOS64_PARAMETERS),
           NVOS64_HAS_PARAMSSIZE ? "on" : "off");
    printf("   %s\n\n", P104_ABI_NOTE);

    printf("== 打开 RM client ==\n");
    if (rm_open(&c) < 0) {
        fprintf(stderr, "\n建 client 失败。排查：\n"
                        "  - /dev/nvidiactl 是否存在、当前用户在 video 组\n"
                        "  - dmesg | tail 看 NVRM 是否报错\n"
                        "  - 确认 nvidia 模块已加载\n");
        return 1;
    }
    printf("  hClient=0x%08x hDevice=0x%08x hSubdevice=0x%08x\n\n",
           c.hClient, c.hDevice, c.hSubdevice);

    print_state("acquire 前:");

    if (release_only) {
        printf("\n== 仅 release ==\n");
        rc = perfmon_reserve(&c, 0) < 0 ? 1 : 0;
        print_state("release 后:");
        rm_close(&c);
        return rc;
    }

    printf("\n== acquire perfmon ==\n");
    if (perfmon_reserve(&c, 1) < 0) {
        fprintf(stderr, "  acquire 失败 —— 通道没通，先解决这个\n");
        rm_close(&c);
        return 1;
    }

    if (probe) {
        /* 给驱动一点时间跑仲裁，然后立刻释放 */
        sleep(3);
        print_state("acquire 3s 后:");
        printf("\n== release（probe 模式）==\n");
        perfmon_reserve(&c, 0);
        sleep(2);
        print_state("release 2s 后:");
        rm_close(&c);
        printf("\nprobe 结束。若两行 MEM 相同，说明极性未被翻转"
               "（多半是 MaxPerfWithPerfMon=0 已生效，极性本来就恒 max）\n");
        return 0;
    }

    /* 常驻模式 */
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    printf("\n== 常驻中%s ==\n", seconds > 0 ? "（定时）" : "（Ctrl-C 退出）");
    {
        int elapsed = 0;
        while (!g_stop) {
            sleep(1);
            elapsed++;
            if (elapsed % 5 == 0)
                print_state("运行中:");
            if (seconds > 0 && elapsed >= seconds)
                break;
        }
    }

    printf("\n== release perfmon ==\n");
    perfmon_reserve(&c, 0);
    sleep(2);
    print_state("release 后:");
    rm_close(&c);

    printf("\n已退出。若 MEM 仍是 5005，是 MaxPerfWithPerfMon=0 造成的"
           "（该键使极性恒 max，与本程序无关）\n");
    return rc;
}
