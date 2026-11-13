# versions/ — 按驱动版本组织

每个目录**自包含**：进去 `make` 就能出可执行文件，不依赖上级目录。

```
versions/
├── 580.178.04/          ← 唯一实测过的版本
│   ├── VERSION          机器可读的元数据与验证进度
│   ├── README.md        本版本的 ABI 表、特征、验证记录、错误码对照
│   ├── Makefile         make / make abi / make clean
│   ├── src/
│   │   ├── abi.h        ★ 唯一允许版本间不同的文件
│   │   ├── p104-set-mem-clock.c    ← 由 sync-versions.sh 维护，别手改
│   │   └── sizes.c
│   ├── scripts/         memclock / restart / check-session / verify-flip / revert-regkey / rsh
│   └── bin/             构建产物
└── _template/
    └── src/abi.h        新版本适配模板（含 TODO 清单）
```

## 为什么按版本分

工具的**全部版本敏感性**集中在 5 个常量上，其余 400 行逻辑跨版本通用：

| 常量 | 为什么可能变 | 怎么看 |
|---|---|---|
| `NVOS64_HAS_PARAMSSIZE` | alloc 结构体在 510 是 40B、580 是 48B | `strace` 看 alloc ioctl 的 size |
| `ABI_NEED_OPEN_GPU_NODE` | 是否必须先开 GPU 节点 | 不开试一次，看是否报 `0x1B` |
| `ABI_ALLOC_PARMS_SIZE_BY_CLASS` | `pAllocParms` 长度是否随 class 变 | 报参数长度错误就关掉试 |
| `NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW` | 控制命令号 | 该版本 `ctrl2080perf.h` |
| class ID | `NV01_ROOT_CLIENT` / `NV01_DEVICE_0` / `NV20_SUBDEVICE_0` | `nvos.h`、`cl0080.h`、`cl2080.h` |

**选错 `NVOS64_HAS_PARAMSSIZE` 的代价最大**：`alloc` 返回 `NV_OK` 但 handle 不回填，
后面才报 `0x57`，非常容易误判成权限问题。

## 版本状态一览

| 版本 | 状态 | client | reserve | 极性翻转 | 内核 |
|---|---|---|---|---|---|
| 580.178.04 | 通道已验证 | ✅ | ✅ | ⬜ pending | 6.12.116 |

## 新增一个版本

```bash
cd scripts
./make-version.sh 590.48.01              # 全新骨架（abi.h 是模板，含 TODO）
./make-version.sh 590.48.01 --from 580.178.04   # 以 580 为起点，abi.h 一并复制
```

然后：

1. **改 `src/abi.h`** —— 按文件里的 TODO 逐项核对（这是唯一必须手改的地方）
2. `cd versions/590.48.01 && make abi` —— 打印实际结构体尺寸，与 `strace` 观测比对
3. `make && sudo ./bin/p104-set-mem-clock --probe`
4. 补 `VERSION` 与 `README.md` 的实测记录

## 维护共享源码

master 源码在顶层 `src/`。改完用同步脚本推到各版本：

```bash
./scripts/sync-versions.sh --check     # 只看差异
./scripts/sync-versions.sh --build     # 同步 + 逐个构建
```

**铁律：`sync-versions.sh` 永不覆盖 `versions/*/src/abi.h`。**
那是每个版本唯一的差异点，覆盖它等于抹掉适配依据。

## 部署时先核对 ABI 指纹

二进制和版本目录容易配错。启动时会打印：

```
== ABI: driver 580.178.04, NVOS64=48B, paramsSize@on ==
```

若这行与 `VERSION` 不符，说明跑的不是对应版本的二进制。
