# 580.178.04

> 状态：**ioctl 通道已验证；极性翻转待验**（`verify_polarity_flip=pending`）
>
> 设备：NVIDIA P104-100 · 内核 6.12.116+deb13-amd64 · 验证于 2026-11-13，Portable (192.168.1.43)

这是本项目**唯一实测过的版本**，其余版本目录都是在它基础上派生。

## 构建与运行

```bash
make abi                       # 先看 ABI 指纹，和下面表格核对
make                           # 产出 bin/p104-set-mem-clock
sudo ./bin/p104-set-mem-clock --probe
```

`bin/` 是构建产物目录，可随时 `make clean`。

## 本版本的 ABI 指纹

`make abi` 的实际输出，与本文件表格**必须一致**，否则说明 `src/abi.h` 选错了形态：

| 项 | 值 | 怎么来的 |
|---|---|---|
| `sizeof(NVOS64_PARAMETERS)` | **48** | `strace` 看 alloc(0x2b) 的 size=0x30 |
| `sizeof(NVOS54_PARAMETERS)` | **32** | `strace` 看 control(0x2a) 的 size=0x20 |
| `NV0080_ALLOC_PARAMETERS` | 56 | cl0080.h |
| `NV2080_ALLOC_PARAMETERS` | 4 | cl2080.h |
| `RESERVE_PERFMON_HW_PARAMS` | 1 | `NvBool bAcquire` |
| `IOCTL_RM_ALLOC` | `0xc030462b` | `_IOWR('F',0x2b,48B)` |
| `IOCTL_RM_CONTROL` | `0xc020462a` | `_IOWR('F',0x2a,32B)` |
| cmd | `0x20802093` | ctrl2080perf.h |

## 本版本的两个特征（与 510 头文件不同）

### 1. `NVOS64` 是 48 字节，不是 40

510 源码树里的 `NVOS64_PARAMETERS` 只有 40 字节（`hRoot … pRightsRequested, status`）。
580 多出 `paramsSize` + `flags`：

```c
NvHandle hRoot;             // 0
NvHandle hObjectParent;     // 4
NvHandle hObjectNew;        // 8   [INOUT]
NvV32    hClass;            // 12
NvP64    pAllocParms;       // 16
NvP64    pRightsRequested;  // 24
NvU32    paramsSize;        // 32  ← 510 没有
NvU32    flags;             // 36  ← 510 没有
NvV32    status;            // 40
// = 48
```

**选错的症状极隐蔽**：`alloc` 返回 `status=NV_OK`，但 `hObjectNew` 不被回填
⇒ `subdevice handle = 0` ⇒ 后续 control 报 **`0x57`**。
看上去像"权限不足"或"对象无效"，实际是结构体长度不对。

### 2. `alloc device` 之前必须先 `open("/dev/nvidia0")`

不开 GPU 节点直接 alloc device，返回 **`0x1B`**。
原因：驱动侧该 GPU 的 RM 尚未完成初始化。

`abi.h` 里用 `ABI_NEED_OPEN_GPU_NODE=1` 表示。

## 验证记录

### ✅ client 建立

```
[alloc root client] ok  handle=0xc1d000c7
[open /dev/nvidia0] ok
[alloc device]      ok  handle=0xcaf00000
[alloc subdevice]   ok  handle=0xcaf00001
```

### ✅ reserve perfmon

```
[perfmon acquire] ok
[perfmon release] ok
```

### ✅ 独占互斥（证明 reserve 真在驱动里生效）

```
A 持有中 → B acquire: status=0x63   NV_ERR_STATE_IN_USE
A 释放后 → B acquire: ok
```

`kill -9` 掉持有进程后也能立刻重新 acquire —— fd 关闭触发 client 销毁，驱动侧自动清理。

### ⬜ 极性翻转（pending）

测试时 `MaxPerfWithPerfMon=0` 仍生效（`PERFMON_ENABLED=0` 使条件② 恒真），
极性本来就恒 max，`acquire`/`release` 前后都是 5005，**看不出差异**。

要补这次验证：

```bash
../scripts/revert-regkey.sh        # 删掉 MaxPerfWithPerfMon=0
../scripts/restart.sh              # 重启（别用 sudo reboot，且别加 sudo）
sudo mount -t nfs 192.168.1.15:/data/用户 /data/用户
../scripts/verify-flip.sh          # 期望 405 → 5005 → 405
```

`verify-flip.sh` 会先检查基线；若基线就是 5005，直接退出码 2 判定 regkey 没退干净。

## 已知错误码对照

| 码 | 含义 | 常见原因 |
|---|---|---|
| `0x57` | INVALID_OBJECT_HANDLE | `NVOS64` 用了 40 字节版 ⇒ subdevice handle=0 |
| `0x1B` | INVALID_OBJECT_PARENT | alloc device 前没 `open /dev/nvidia0` |
| `0x63` | STATE_IN_USE | perfmon 已被别的客户端（profiler 或另一个本程序）占用 |
| `0x11` | INSUFFICIENT_PERMISSIONS | 没用 root（内核有 `osIsAdministrator()` 检查） |
