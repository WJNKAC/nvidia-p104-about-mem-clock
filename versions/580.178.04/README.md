# 580.178.04 —— P104-100 显存频率手动开关

> 驱动 580.178.04 / NVIDIA P104-100 / 内核 6.12.x
> 状态：**可用**（手动 405 ⇄ 5005，已验证幂等与可恢复）

---

## 一句话

`p104-switch.sh on` → MCLK 5005（带宽 ~250 GB/s）；`p104-switch.sh off` → 回 405（~8 W）。

---

## 快速开始

```bash
cd versions/580.178.04
./01.install.sh        # 编译 + 安装（普通用户，不要 sudo）
p104-switch.sh on      # → 5005（自己提权）
p104-switch.sh off     # → 405
p104-switch.sh status
p104-switch.sh unload     # off + 卸内核模块
p104-switch.sh uninstall  # 删已安装的文件
```

`01..06` 是同一批命令的顺序别名，源码树里可以逐个跑；
安装后只需要 `p104-switch.sh`。

---



## 目录结构

```
580.178.04/
├── VERSION                     机器可读元数据
├── README.md                   本文件
├── 01.install.sh … 06.uninstall.sh   顺序别名（薄封装，不写实现）
├── main/
│   ├── scripts/p104-switch.sh  ★ 自包含入口
│   ├── utils/                  函数库
│   │   ├── init.sh             唯一定义路径（识别源码树/已安装两种布局）
│   │   ├── commands.sh         ★ 六个命令的实现
│   │   ├── output.sh           提示函数
│   │   ├── gpu_ident.sh        显卡身份校验
│   │   ├── gpu_state.sh        读 pstate/mem/带宽
│   │   ├── perfmon.sh          ★ 开关 PERFMON_ENABLED
│   │   ├── seqtick.sh          ★ 制造/等待 changeseq（最难的部分）
│   │   ├── module.sh           模块加载/卸载
│   │   └── install.sh          构建与安装
│   ├── src/                    C 源码 + Makefile
│   └── output/                 构建产物
└── history/{ark,docs}/         退役脚本与历史文档
```

### 安装动什么（只有两处）

| 源 | 目标 |
|---|---|
| `main/scripts/p104-switch.sh` | `~/.local/bin/p104-switch.sh`（**复制**） |
| `main/utils/*.sh` + `main/output/*` | `~/.local/share/mclk-p104/` |

- **bin 里只有一个文件**，不带工具、不带库。
- **share 里带 utils**，所以入口不依赖源码树 —— 复制后即可独立运行。
- 入口用**复制**而非软链：软链等于"没装"，源码树一删就废。

`/usr` `/etc` `/var` 一个不碰；不写 systemd / modules-load.d / rc.local。
⇒ 开机不会加载任何东西，必须手动 `on`。

### 改了要不要重装

| 改哪里 | 是否要重跑 install |
|---|---|
| `main/utils/*.sh`、`0N.*.sh` | ✅ 要（安装时是复制） |
| `main/src/*.c` | ✅ 要（并重新编译） |

源码树里直接跑 `./main/scripts/p104-switch.sh on` 不受影响。

---

## 原理（当前结论，报告 237）

405 **不是硬件限制**，是 RM 在 `PERFMON_ENABLED=1` 期间施加的**时钟锁定**：
PMU 要计数准确，前提是时钟稳定；MCLK 一变，计数器读数就无法换算回时间。

所以这是**纯软件行为**，关掉 perfmon 锁就解除。这就是为什么一行
`MaxPerfWithPerfMon=0` 配置就能满速 —— 它只做了清 bit0 这一件事。

**A/B 判决（唯一变量 = bit0）**：

| | bit0=1 | bit0=0 |
|---|---|---|
| MCLK range | `[5005,5005]` | `[5005,5005]`（**相同**） |
| `curValueToSet` | `5005000` | `5005000`（**相同**） |
| 硬件实测 | 405 MHz / 19.3 GB/s | 5005 MHz / 254.5 GB/s |

⇒ 仲裁输出一样、硬件行为不同。**改 `curValueToSet` 是无效方向**（前两轮都错在这里）。

硬件本身零审查：写 `3000000`（3 GHz）它就真跑 2999 MHz，不做电压/时序校验。

---

## 两个必须知道的副作用

清掉 bit0 之后：

1. **`utilization` 恒 0** —— 不是"被限制"，是数据源没了。
   `_nv051004rm` 从 perfmon 的采样缓冲读数算百分比（报告 239），
   perfmon 停了缓冲不更新，算出来自然是 0。
2. **pstate 恒 P0** —— `GPU_IS_IDLE` 依赖 util，util=0 就判不出空闲。

⇒ **任何基于 util / pstate / 功耗的运行时判据都会自毁。**
这是「空闲 7W + 负载 5005 自动切换」至今做不成的真正原因 ——
**不是找不到闸门，是找不到一个不会自毁的判据。**

---

## 操作上的两条硬约束（都踩过）

### `on` 必须在 P8 时清 flag，且要重试

清 flag 后 `GPU_IS_IDLE` 失效 ⇒ pstate 常驻 P0 ⇒ **P0 下不再有 P-State 跃迁**
⇒ 没有 changeseq ⇒ MCLK 永远不会被重新下发。

所以「先清 flag、卡在 P0、再拼命跑负载」是徒劳的（实测连续 6 次失败）。
重试的最小单位必须是「回 P8 + 清 flag + 长负载」**一整轮**。

**命中率不稳定**：跨会话实测约 **1/2 ~ 1/4**，属于 D-state 下的竞态。
`main/utils/seqtick.sh` 因此做了三件事：轮间冷却 2 秒、默认 6 轮、失败时打印每轮落点。

可调：`P104_RETRY=8 P104_LOAD_SECS=15 p104-switch.sh on`

### `off` 只跑一次短负载，然后纯静置

- 完全静置 → 卡在 `P0/5005/69W` 20 秒不动
- 循环里反复跑负载 → 负载把 GPU 撑住，永远等不到降档

正确：跑一次 5s → 停手 → 等它自己降（实测 5 秒内回 `P8/405/8W`）。

### 还有一条：`off` 必须幂等

已是 405 时直接返回，不再跑负载。否则 `unload` 里再调一次 `off`
会把刚空闲的 GPU 重新撑到 `P0/33W`，看起来像卸载失败。

---

## 判频率的铁律

**`clocks.mem` 会谎报**（报的是目标值 `curValueToSet`，不是硬件实测）。这个坑一天内被骗过三次。

| 手段 | 可靠性 |
|---|---|
| `nvidia-smi --query-gpu=clocks.mem` | ⚠ 会谎报，也可能因瞬态漏采 |
| `nvitop` 等 TUI | ⚠ 默认 1 秒刷新，短瞬态全漏 |
| **`clburn N triad` 的 BANDWIDTH** | ✅ **唯一可信** |

```
405  → ~19 GB/s
5005 → ~250-280 GB/s   （差 13-14×）
```

要看瞬态（例如"短暂 2999 MHz"）用 `mclkwatch 20 3`（300 Hz 轮询）。

---

## 远程执行

`utils/rsh.sh` 用于在测试机上执行命令。**它不含任何主机、账号或密码**：

```bash
export P104_SSH_HOST=...    # 测试机地址
export P104_SSH_USER=...    # 登录账号
export P104_SSH_PW=...      # 密码（仅本会话，勿写入任何文件）
./utils/rsh.sh 'nvidia-smi'
./utils/rsh.sh -f local_script.sh
```

三者缺失即报错退出，不回落到内置默认值。密码只写进 `mktemp` 建的 700 文件、
退出时 `trap` 删除，不 echo、不写日志。

---

## 已验证 / 未验证

| 项 | 状态 |
|---|---|
| `01.install.sh`（构建 + 装 HOME） | ✅ 通过 |
| `on` → 5005 / 249.6 GB/s | ✅ 通过（含重试） |
| `off` → 405 / 7.6 W | ✅ 通过（5 秒内） |
| `off` 幂等 | ✅ 通过 |
| `unload` → 模块卸载、GPU 回 8 W | ✅ 通过 |
| `status` 打印 utils 版本 | ✅ 通过 |
| 空闲自动省电 / 负载自动 5005 | ❌ **未实现**（判据自毁，见上文） |
| 跨驱动版本 | ❌ 未验证（bit0 偏移 `0x8e100` 是 580 的） |

---

## 安全

- 模块会改 `nvidia.ko` 内部结构。2026-11-13 因定时器写野指针导致过**整机 panic**
  （当时还配了开机自启，差点变成"每次开机都 panic"）。现在：
  **只在 `ret_handler`/`pre_handler` 内写，无定时器，无任何自动启动路径。**
- `unload` 前强制确认已回 405，否则拒绝卸载（防止 GPU 常驻 70 W）。
- `install` 不允许 root 运行（会装错 `$HOME`，且 NFS 上 root 无写权限）。

---

## 历史

- `history/ark/` —— 退役脚本与产物（含 reserve perfmon 时期的 `p104-set-mem-clock`、旧 Makefile、旧 README）
- 完整调查过程见上层 `docs/mechanism.md`、`docs/ops.md` 与 `reports/233`–`239`
