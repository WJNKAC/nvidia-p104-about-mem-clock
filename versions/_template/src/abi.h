/*
 * abi.h [模板] — 新版本适配起点
 *
 * 这个文件是"版本"的唯一意义：换驱动版本时**只有这里需要改**。
 *
 * 用法：
 *   cp versions/_template/src/abi.h versions/<新版本>/src/abi.h
 *   然后逐项按下面 TODO 核对并填写。
 *
 * 核对三件事（缺一不可）：
 *   1. alloc 结构体字节数    → strace -e ioctl nvidia-smi，看 0x2b 的 size
 *   2. control 结构体字节数  → 同上，看 0x2a 的 size
 *   3. RESERVE_PERFMON 命令号 → 该版本 resman 源码的 ctrl2080perf.h
 *
 * 已知参考点（实测）：
 *   510 源码头文件：NVOS64 = 40 字节，无 paramsSize/flags
 *   580.178.04 实测：NVOS64 = 48 字节，有 paramsSize/flags（ioctl 0xc030462b）
 */
#ifndef P104_ABI_H
#define P104_ABI_H

/* ── 版本标识 ── */
#define P104_ABI_DRIVER      "TODO 例如 580.178.04"
#define P104_ABI_NOTE        "TODO 一句话说明本版本的 ABI 特点"

/* ── ioctl escape 号（nv_escape.h） ──
 * 跨版本通常稳定，遇到改过的分支再改这里。 */
#define NV_IOCTL_MAGIC         'F'
#define NV_ESC_RM_FREE         0x29
#define NV_ESC_RM_CONTROL      0x2A
#define NV_ESC_RM_ALLOC        0x2B

/* ── class ID（nvos.h / class/cl0080.h / class/cl2080.h） ── */
#define NV01_ROOT_CLIENT       0x00000041
#define NV01_DEVICE_0          0x00000080
#define NV20_SUBDEVICE_0       0x00002080

/* ── 控制命令号（ctrl2080perf.h） ──
 * TODO 从该版本源码核对：
 *   grep -n "NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW" ctrl2080perf.h
 * 已知：510/580 = 0x20802093 */
#define NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW   0x20802093

/* ── NVOS64（alloc）结构体形态 ──
 *   0 = 40 字节版（无 paramsSize / flags），510 头文件形态
 *   1 = 48 字节版（含 paramsSize / flags），580 实测形态
 *
 * TODO 用 strace 定：
 *   strace -f -e trace=ioctl -o /tmp/t nvidia-smi -q -d PERFORMANCE
 *   grep "0x46, 0x2b" /tmp/t
 *   size=0x30(48) → 置 1；size=0x28(40) → 置 0
 *
 * ⚠ 选错的症状很隐蔽：alloc 返回 NV_OK 但 hObjectNew 不回填（handle=0），
 *   后续 control 才报 0x57。 */
#define NVOS64_HAS_PARAMSSIZE   0   /* TODO */

/* ── alloc 前是否必须先打开 GPU 节点 ──
 * TODO 先置 0 试；若 alloc device 报 0x1B，改成 1。
 * 580 实测需要。 */
#define ABI_NEED_OPEN_GPU_NODE  0   /* TODO */

/* ── pAllocParms 长度是否随 class 变化 ──
 * TODO 先置 1（580 实测 device=56 / subdevice=4 能通）；
 *      若 alloc 报参数长度类错误，改 0 试。 */
#define ABI_ALLOC_PARMS_SIZE_BY_CLASS  1

#endif /* P104_ABI_H */
