/*
 * abi.h — 版本相关的 ABI 常量
 *
 * 这个文件是"版本"的唯一意义所在：换驱动版本时**只有这里需要改**。
 * 每个 versions/<版本号>/src/abi.h 是一份冻结的副本，改动它等于声明
 * "该版本用这套 ABI"，请同时在同目录 README.md 里记录验证证据。
 *
 * 当前内容 = 580.178.04（唯一实测过的版本）。
 *
 * 改之前先确认（三件事，缺一不可）：
 *   1. alloc 结构体字节数    → strace -e ioctl nvidia-smi 看 0x2b 的 size
 *   2. control 结构体字节数  → 同上，看 0x2a 的 size
 *   3. RESERVE_PERFMON 的命令号 → 该版本 resman 源码的 ctrl2080perf.h
 */
#ifndef P104_ABI_H
#define P104_ABI_H

/* ── 版本标识（仅用于自检输出与文档对照） ── */
#define P104_ABI_DRIVER      "580.178.04"
#define P104_ABI_NOTE        "NVOS64=48B(含 paramsSize/flags)；alloc 前需先 open /dev/nvidia0"

/* ── ioctl escape 号（nv_escape.h） ──
 * 这几个是 RM UAPI 的稳定常量，跨版本几乎不变，但仍放在这里，
 * 万一遇到改过的分支可以就地覆盖。 */
#define NV_IOCTL_MAGIC         'F'
#define NV_ESC_RM_FREE         0x29
#define NV_ESC_RM_CONTROL      0x2A
#define NV_ESC_RM_ALLOC        0x2B

/* ── class ID（nvos.h / class/cl0080.h / class/cl2080.h） ── */
#define NV01_ROOT_CLIENT       0x00000041
#define NV01_DEVICE_0          0x00000080
#define NV20_SUBDEVICE_0       0x00002080

/* ── 本工具用的控制命令（ctrl2080perf.h） ──
 * NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW = 0x20802093
 *   = (FINN_NV20_SUBDEVICE_0_PERF_INTERFACE_ID << 8) | 0x93 */
#define NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW   0x20802093

/* ── NVOS64（alloc）结构体的形态选择 ──
 *   0 = 510 头文件的 40 字节版（无 paramsSize / flags）
 *   1 = 580 实测的 48 字节版（含 paramsSize / flags）
 *
 * ⚠ 选错的症状非常隐蔽：alloc 返回 status=NV_OK，但 hObjectNew 不被回填
 *   （subdevice handle = 0），后续 control 才报 0x57。
 *   判定方法：strace -e ioctl nvidia-smi 看 alloc(0x2b) 的 size。
 */
#define NVOS64_HAS_PARAMSSIZE   1

/* ── alloc 前是否必须先打开 GPU 节点 ──
 * 580 实测：不开 /dev/nvidia0 直接 alloc device 会返回 0x1B
 *          （NV_ERR_INVALID_OBJECT_PARENT 一类）。 */
#define ABI_NEED_OPEN_GPU_NODE  1

/* ── alloc 时 pAllocParms 的长度是否随 class 变化 ──
 * 580 实测：device=56 / subdevice=4 / root=0 能通。
 *   0 = 一律传 0（老驱动不校验）
 *   1 = 按 class 给长度
 */
#define ABI_ALLOC_PARMS_SIZE_BY_CLASS  1

#endif /* P104_ABI_H */
