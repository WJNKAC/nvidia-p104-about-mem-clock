# versions/ — 按驱动版本组织

每个版本目录**自包含**：进去 `./01.install.sh` 就能装好，不依赖上级目录。

## 版本状态

| 版本 | 状态 | 手动切换 | 自动切换 | 内核 |
|---|---|---|---|---|
| 580.178.04 | **可用** | ✅ 405 ⇄ 5005 | ❌ 判据自毁 | 6.12.116 |

## 目录规范（所有版本统一）

```
<驱动版本>/
├── VERSION                 机器可读元数据 + 实测结论
├── README.md               本版本的原理、约束、验证记录
├── 01.install.sh           ① 构建 + 安装
├── 02.on.sh                ② 切到 5005
├── 03.off.sh               ③ 切回 405
├── 04.status.sh            ④ 状态
├── 05.unload.sh            ⑤ 卸内核模块
├── 06.uninstall.sh         ⑥ 删已安装文件
├── main/                   ★ 全部实现在这里
│   ├── scripts/            主入口（装到 ~/.local/bin）
│   ├── utils/              函数库（装到 share，供入口 source）
│   ├── src/                C 源码 + Makefile
│   └── output/             构建产物（装到 share）
└── history/
    ├── ark/                退役脚本与产物
    └── docs/               历史文档
```

### 各层职责

| 位置 | 只放什么 | 不放什么 |
|---|---|---|
| `0N.*.sh` | 用例编排（调 utils） | 具体实现 |
| `main/scripts/` | 主入口：提权 + 分发命令 | 业务逻辑 |
| `main/utils/` | 可复用函数 | 命令行入口 |
| `main/src/` | C 源码与 Makefile | 编译产物 |
| `main/output/` | 构建产物 | 源码 |
| `history/ark/` | 退役的东西 | 还在用的东西 |

**路径只在 `main/utils/init.sh` 定义**，其它脚本一律不许自己算。

## 安装

`01.install.sh` 做两件事：

| 源 | 目标 |
|---|---|
| `main/scripts/p104-switch.sh` | `~/.local/bin/p104-switch.sh`（**复制**） |
| `main/utils/*.sh` + `main/output/*` | `~/.local/share/mclk-p104/` |

- **bin 里只放一个文件**，不带库、不带工具。
- **utils 跟着进 share**，入口复制过去也能独立跑，不依赖源码树。
- 入口用**复制**而非软链：软链等于没装，源码树一删就废。
- `main/utils/init.sh` 自动识别「源码树 / 已安装」两种布局。

`/usr`、`/etc`、`/var` **一个不碰**；不写 systemd / modules-load.d / rc.local。
⇒ 开机不会加载任何东西，必须手动 `02.on.sh` / `p104-switch.sh on`。

## 改代码

| 改哪里 | 是否要重装 |
|---|---|
| `main/utils/*.sh`、`0N.*.sh` | ✅ 要重跑 `./01.install.sh`（安装是复制） |
| `main/src/*.c` | ✅ 要（并重新编译） |

源码树里直接跑 `./main/scripts/p104-switch.sh on` 不受影响，不用重装。

## 新增一个版本

```bash
cp -r versions/580.178.04 versions/<新版本>
# 改 main/src/polarity_hook.c 的 PERF_FLAGS_OFFSET
# 改 main/src/abi.h 的 ABI 常量
# 然后：./01.install.sh && p104-switch.sh status
```

**换版本必须重新定位的常量**（都写在 `VERSION` 里）：

| 常量 | 为什么可能变 |
|---|---|
| `PERF_FLAGS_OFFSET`（580 是 `0x8e100`） | `pPerf` 结构体布局随版本变 |
| `mclk_idx`（580 是 2） | clocks[] 的顺序 |
| ABI 结构体尺寸 | `NVOS64` 在 510 是 40B、580 是 48B |

**别信 `clocks.mem`**，新版本上一定要用 `clburn` 带宽验证：
`405 → ~19 GB/s`，`5005 → ~250-280 GB/s`。
