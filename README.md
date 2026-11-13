# nvidia-p104-set-mem-clock

P104-100 显存频率（405 → 5005 MHz）攻关工程。

> **当前成果**：手动切换可用 —— `p104-switch.sh on` → 5005 / ~250 GB/s，`off` → 405 / ~8 W。
> **未实现**：空闲自动省电 / 负载自动 5005（判据自毁，见「已知限制」）。

所有可执行、源码、脚本都在版本目录里：
**[`versions/580.178.04/`](versions/580.178.04/README.md)**

---

## 四条路线，三个已证伪

| 路线 | 结论 |
|---|---|
| **方案 A**：regkey `MaxPerfWithPerfMon=0` | ✅ 有效，但空闲也是 69 W（不可接受） |
| **方案 D**：reserve perfmon（`p104-set-mem-clock`） | ❌ 独占成功、MCLK 不动，acquire 期间常驻 44 W |
| **方案 A′**：PM1 | ❌ no-op（写 1 读回 0） |
| **kretprobe 改 `curValueToSet`**（`arbhook`） | ❌ 技术通、效果不通：仲裁输出改了，硬件不跟 |
| **⭐ 开关 `PERFMON_ENABLED`**（当前） | ✅ **405 ⇄ 5005 手动切换可用** |

---

## 原理（报告 237，一句话）

**405 不是硬件限制，是 RM 在 `PERFMON_ENABLED=1` 期间施加的「时钟锁定」**
—— PMU 要计数准确，前提是时钟稳定；MCLK 一变，计数器读数就无法换算回时间。

所以它是**纯软件行为**，关掉 perfmon 就解除。这就是为什么一行
`MaxPerfWithPerfMon=0` 配置就能满速：它只做了"清 bit0"这一件事。

**A/B 判决（唯一变量 = `pPerf+0x8e100` 的 bit0）**：

| | bit0=1 | bit0=0 |
|---|---|---|
| MCLK range | `[5005,5005]` | `[5005,5005]`（相同） |
| `curValueToSet` | `5005000` | `5005000`（相同） |
| 硬件实测 | 405 MHz / 19.3 GB/s | 5005 MHz / 254.5 GB/s |

⇒ 仲裁输出一样、硬件行为不同。**改 `curValueToSet` 是无效方向。**

硬件本身**零审查**：写 `3000000`（3 GHz）它就真跑 2999 MHz，不做电压/时序校验。

> 这个结论推翻了前面三个：极性取 min（早期）→ range 塌缩（233）→ 锁存竞态（236）。
> 每个错误结论都记录在 `reports/` 里，包括推翻它的证据。

---

## 快速开始

```bash
cd versions/580.178.04
./01.install.sh        # 编译 + 安装（普通用户）
p104-switch.sh on         # → 5005（自己提权）
p104-switch.sh off        # → 405
p104-switch.sh status
p104-switch.sh unload     # off + 卸内核模块
p104-switch.sh uninstall  # 删已安装的文件
```

目录规范、安装落点、操作约束见
[`versions/README.md`](versions/README.md) 与
[`versions/580.178.04/README.md`](versions/580.178.04/README.md)。

---

## 目录

```
nvidia-p104-set-mem-clock/
├── README.md                本文件：项目总览
├── docs/
│   ├── mechanism.md         机制链（源码级）
│   └── ops.md               运维：部署、卸载纪律、自检清单
├── versions/
│   ├── README.md            目录规范、安装方式、新增版本步骤
│   ├── 580.178.04/          ← 唯一实测过的版本，自包含
│   └── _template/           新版本适配模板
└── out/                     临时输出
```

历史脚本与旧源码在 `versions/580.178.04/history/ark/`（含 reserve perfmon 时期的
`p104-set-mem-clock`、`arbhook`、各类 A/B 实验脚本）。

---

## 判频率的铁律

**`clocks.mem` 会谎报** —— 它报的是 `curValueToSet`（目标值），不是硬件实测。
这个坑一天内被骗过三次。

| 手段 | 可靠性 |
|---|---|
| `nvidia-smi --query-gpu=clocks.mem` | ⚠ 会谎报，1 秒刷新也会漏瞬态 |
| `nvitop` 等 TUI | ⚠ 同上 |
| **`clburn N triad` 的 BANDWIDTH** | ✅ **唯一可信** |

```
405  → ~19 GB/s
5005 → ~250-280 GB/s   （差 13-14×）
```

看瞬态用 `mclkwatch 20 3`（300 Hz，在 `~/.local/share/mclk-p104/`）。实测过「写 3000000 后硬件真到 2999 MHz，
只存活几十毫秒」——用 `nvidia-smi` 1 秒采样完全看不见，会误判成"值被拒绝"。

---

## 已知限制

| 限制 | 原因 |
|---|---|
| **不能自动切换** | 清 bit0 后 `utilization` 恒 0（数据源没了）、`pstate` 恒 P0 ⇒ 任何运行时判据自毁 |
| `on` 命中率不稳定 | D-state 竞态，约 1/2 ~ 1/4；`seqtick_v2` 用"轮间冷却 + 6 轮重试"缓解 |
| 只验证了 580.178.04 | bit0 偏移 `0x8e100` 是 580 的，换驱动必须重新定位 |
| 空闲 69 W（on 状态） | 这是"时钟锁定"的代价，regkey 方案同样避不开 |

**自动切换做不成的真正原因不是"找不到闸门"，是"找不到一个不会自毁的判据"。**
`_nv051004rm` 已被定位为 utilization 的计算器（报告 239）——perfmon 停了它就没有输入。

---

## 重启纪律（KDE）

直接 `sudo reboot` 不走 KDE 注销流程 ⇒ 窗口记忆停留上次正常注销的状态
⇒ 下次登录复活一堆早已关掉的窗口。

用 KDE 自己的注销/重启路径（`restart.sh` 已归档在
`versions/580.178.04/history/ark/dev-scripts/`，需要时拷回来用）。

KDE 的开始菜单「重启」曾一度失效，根因是 **dbus 激活环境缺 `WAYLAND_DISPLAY`**
⇒ greeter 连不上合成器、静默退出（rc=0、无 stderr）。修复：

```bash
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
```

---

## 安全

- 模块会改 `nvidia.ko` 内部结构。2026-11-13 因**定时器缓存 `pArbOutput2x` 地址后反复写**
  导致整机 panic（`pArbOutput2x` 是每次仲裁新分配的临时结构，缓存它 = 写野指针）。
  当时还配了开机自启，差点变成"每次开机都 panic、连 rmmod 的机会都没有"。
  **现在：只在 `ret_handler`/`pre_handler` 内写；无定时器；无任何自动启动路径。**
- 不写 systemd / modules-load.d / rc.local / modprobe.d；
  产物只在 `$HOME`，`/usr` `/etc` `/var` 一个不碰。
- `unload` 前强制确认已回 405，否则拒绝（防止 GPU 常驻 70 W）。
