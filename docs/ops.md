# 运维手册：Portable (192.168.1.43) 的常驻依赖与易失项

本机是 P104-100 测试机（hostname `Portable`，Debian 13，内核 6.12.x）。
下面这些是**重启后不会自动恢复**的东西，或者会在内核升级时失效的东西。

---

## 1. 重启后必须手动做的两件事

### 1.1 挂 NFS `/data/用户`

`/data/用户` 来自 `192.168.1.15`（82MS），`/data/labs/nvidia` 是指向它的软链。
**不挂就会断链**，所有 analysis/reports 目录看不到。

**2026-11-13 起已进 fstab（automount）**，正常情况无需手动：

```
192.168.1.15:/data/用户  /data/用户  nfs4  defaults,_netdev,noauto,x-systemd.automount,x-systemd.mount-timeout=10,x-systemd.idle-timeout=600  0  0
```

- `noauto` + `x-systemd.automount`：开机不直挂，首次访问才挂 ⇒ NFS 服务器不可达时**不卡启动**
- 生成的单元在 `/run/systemd/generator/data-\xe7\x94\xa8\xe6\x88\xb7.automount`
- `TimeoutIdleSec=10min`（= idle-timeout 600）

若 automount 没生效，手动兜底：

```bash
sudo mount -t nfs 192.168.1.15:/data/用户 /data/用户
```

> ⚠ 别误判：`/dev/sda2` 是**另一套系统的根分区**（有 bin/usr/etc），不是 `/data/用户`。

### 1.2 恢复 PCIe Gen2

**Gen2 不会自动生效。** 见 §2。

---

## 2. gen2kr：手动加载，不归系统管（澄清一个常见误解）

| 项 | 由谁管 | 重启后 | 内核升级后 |
|---|---|---|---|
| `nvidia.ko` 的 2 字节补丁 | 在 .ko 文件里 | **保留** | **DKMS 重编译会丢** → 需重新 `patch-gen2.py apply` |
| `gen2kr.ko` 模块 | **没有任何持久化机制**（modprobe.d / systemd / udev 全无） | **不在内核里** → 需重新 `insmod` | **vermagic 不匹配** → 需重新编译 |

实测确认（2026-11-13）：`grep -rn gen2kr /etc/modprobe.d/ /etc/modules /etc/modules-load.d/ /etc/systemd/ /etc/udev/` **全部无命中**。

所以：

```bash
# 每次重启后（模块在磁盘上，vermagic 没变就不用重编）
sudo insmod /data/labs/nvidia/nvidia-p104-unlock-gen2-for-linux/build/gen2kr.ko
sudo sh -c 'echo 0000:01:00.0 > /sys/bus/pci/drivers/nvidia/unbind; sleep 1;
            echo 0000:01:00.0 > /sys/bus/pci/drivers/nvidia/bind'
```

或者用封装脚本（自动做上面两步并等链路升速）：

```bash
cd /data/labs/nvidia/nvidia-p104-unlock-gen2-for-linux
sudo bash patches/580.178.04/03-gen2-push-light.sh
```

**内核升级后**（vermagic 变了），先重编：

```bash
cd /data/labs/nvidia/nvidia-p104-unlock-gen2-for-linux
bash src/build.sh          # 产出 build/gen2kr.ko
```

### 2.1 2026-11-13 实际发生

内核从 `6.12.113` 自动升到 `6.12.116+deb13-amd64`。
- `nvidia.ko` 的补丁**仍在位**（`check/10-check.sh` 通过）—— 这次运气好
- `gen2kr.ko` 的 vermagic 是 `6.12.116`，**必须重编**（旧的 6.12.113 版本 insmod 会失败）

> ⚠ 下次内核更新若触发 nvidia DKMS 重编译，**2 字节补丁会丢**，
> 届时 `03-gen2-push-light.sh` 会报「补丁不在位」，需要先 `patch-gen2.py apply`。

---

## 3. 桌面会话（KDE / Wayland）

### 3.1 dbus 激活环境

`ksmserver-logout-greeter` 等由 dbus 激活的服务继承 **dbus-daemon 的环境**。
若缺 `WAYLAND_DISPLAY`，点「重启」会**完全没反应**（greeter 起来就静默退出）。

已装 `~/.config/autostart/fix-kde-dbus-env.desktop` 在每次登录后 5 秒刷新，
且**从当前会话取值、不硬编码 `wayland-0`**（换会话序号也不会失效）。

手动修复：

```bash
dbus-update-activation-environment --systemd \
    WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP
```

### 3.2 重启请用 `restart.sh`，不要 `sudo reboot`

```bash
cd /data/labs/nvidia/nvidia-p104-set-mem-clock
./scripts/restart.sh            # 无需 sudo
./scripts/check-session.sh      # 验证上次关机是否保存了会话
```

直接 `reboot` 不会走 KDE 注销流程 ⇒ 窗口记忆停留在上一次正常注销的状态
⇒ 下次登录复活「早已关掉的」窗口。

---

## 4. GPU 频率相关（P104 特有问题）

详见 `/data/labs/nvidia/reports/226`、`233`、`235` 与本项目目录。

### 4.1 现状（2026-11-13 晚）

- `MaxPerfWithPerfMon=0` **已回退**（当前 `RegistryDwords` 只剩 Gen2 三键）。
- 原生：空闲 `P8/139/405/7.5W`，负载 `P0/1911/405/47W`，带宽 **19.3 GB/s**。
- 这是**未修复**的基线。目标态是「空闲 ~8W、负载 5005 / ~275 GB/s」。

⚠ 同一行带着 Gen2 三键，改 `RegistryDwords` 时**不要删掉**：

```
options nvidia NVreg_RegistryDwords="RMPcieLinkSpeed=1;RmForceEnableGen2=1;RmEnableGen2=1"
```

### 4.2 安装与命令（不碰系统目录）

```bash
cd /data/labs/nvidia/nvidia-p104-set-mem-clock/versions/580.178.04
./01.install.sh        # 编译 + 安装
p104-switch on|off|status|unload|uninstall
```

安装落点（全部在 `$HOME`）：

| 源 | 目标 |
|---|---|
| `main/scripts/p104-switch.sh` | `~/.local/bin/p104-switch`（软链） |
| `main/output/*` | `~/.local/share/mclk-p104/` |

**没有** systemd unit、**没有** `modules-load.d`、**没有** `rc.local`、**没有** cron。
⇒ 开机不加载任何东西，必须手动 `p104-switch on`。

### 4.3 命令

```bash
p104-switch on          # → 5005（清 PERFMON_ENABLED）
p104-switch off         # → 405（安全恢复）
p104-switch status
p104-switch unload      # off + 卸内核模块
p104-switch uninstall   # 删已安装文件
```

- **不需要写 sudo**：`on/off/unload` 内部用 `exec sudo -E env ... "$SELF" "$@"` 递归提权，
  并显式传 `P104_BIN_DIR` / `P104_SHARE_DIR` / `P104_STATE_DIR`
  （sudo 默认把 `HOME` 改成 `/root`，不传就找不到产物）。
- **显卡身份校验两层**：脚本层比对 `nvidia-smi --query-gpu=name`；
  `install`/`status` 也不盲取 index 0。不是 P104 就拒绝并列出清单。

### 4.4 手动开关：`p104-switch`（推荐用法）

```bash
p104-switch on       # → 5005
p104-switch off      # → 405（安全恢复）
p104-switch status
p104-switch unload   # off + 卸载模块
```

装到 `~/.local/bin/p104-switch`，模块在 `~/.local/share/mclk-p104/polarity_hook.ko`。
**不需要写 sudo**（脚本内部递归提权）。

#### ⚠ 两个必须遵守的操作约束（都是实测踩出来的）

**① `on` 必须在 P8 时清 flag，且要重试**

清掉 `PERFMON_ENABLED` 之后 `GPU_IS_IDLE` 会失效 ⇒ pstate 常驻 **P0**；
而 P0 状态下不再有 P-State 跃迁 ⇒ 没有 changeseq ⇒ MCLK 永远不会被重新下发。

所以「先清 flag、卡在 P0、然后再拼命跑负载」是徒劳的 —— 必须在**空闲态**清 flag，
紧接着制造**一次** P8→P0 跃迁。脚本因此把重试单位定为
「回 P8 + 清 flag + 长负载」一整轮，默认 4 轮、每轮负载 10 秒：

```
✓ P8 就绪：P8, 139 MHz, 405 MHz, 7.80 W
! 本轮未命中（P0, 1911 MHz, 405 MHz, 32.91 W）
── 第 2 轮 ──
✓ P8 就绪：P8, 139 MHz, 405 MHz, 7.80 W
✓ MCLK=5005（已解锁）        P0, 1911 MHz, 5005 MHz, 70.01 W
```

可调：`P104_RETRY=6 P104_LOAD_SECS=15 p104-switch on`

**② `off` 只跑一次负载，然后纯静置**

置回 bit0 后 GPU **不会自己重算**，仍需一次 changeseq。但：
- 完全静置 → 卡在 `P0/5005/69W` 20 秒不动
- 在循环里反复跑负载 → 负载把 GPU 撑住，永远等不到降档

正确做法：**跑一次短负载（5s）→ 停手 → 静置等它降**，实测 5 秒内回到 `P8/405/8.05W`。

**幂等**：已是 405 时 `off` 直接返回，不会再跑负载
（踩过：`unload` 里再调一次 `off`，把刚空闲的 GPU 重新撑到 P0/33W，看起来像卸载失败）。

### 4.5 ⚠ polarity_hook 的卸载纪律（有真实事故）

直接 `rmmod polarity_hook` 会让 **GPU 常驻 `P0/5005/70W` 且不回落**（实测 90 秒仍 70W，
`nvidia-smi --gpu-reset` 也因 X server 占用而失败）。

必须走这条路径：

```bash
# 1. 复活 perfmon（置回 PERFMON_ENABLED）
echo 2 > /sys/kernel/p104_polarity/override
# 2. 触发一次 changeseq 让它真正生效
/data/labs/nvidia/analysis/clburn 5 triad
# 3. 确认已回到 P8/405 才能卸
nvidia-smi --query-gpu=pstate,clocks.mem,power.draw --format=csv,noheader
# 4. 卸载
rmmod polarity_hook
```

实测：`恢复后 P0/405/32W → rmmod → 10s 后 P8/405/7.45W → 30s 后 7.25W` ✓

### 4.6 判频率的铁律

```bash
# clocks.mem 会漏瞬态；nvidia-smi 1 秒一次不够
nvidia-smi/mclkwatch 只是一半
# 唯一真判据是带宽：
/data/labs/nvidia/analysis/clburn 10 triad
#   405 → ~19 GB/s    5005 → ~250-280 GB/s（差 13-14×）
```
高精度看瞬态用 `src/polarity-hook/mclkwatch`（300 Hz），
`nvidia-smi`/`nvitop` 的 1 秒刷新会漏掉「短暂 2999 MHz」这类事件。

---

## 5. 快速自检清单（重启后）

```bash
# 1. NFS
ls /data/labs/nvidia/reports/ | tail -3

# 2. PCIe
nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv
#   期望 2, 4

# 3. GPU 频率
nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw --format=csv
#   原生（当前）：P8/139/405/7.5W
#   若装了 regkey 方案 A：P0/1911/5005/69W

# 3b. 频率真伪只信带宽（clocks.mem 会谎报）
/data/labs/nvidia/analysis/clburn 10 triad    # 405→~19 GB/s，5005→~250-280 GB/s

# 4. KDE 会话
cd /data/labs/nvidia/nvidia-p104-set-mem-clock && ./scripts/check-session.sh

# 5. dbus 激活环境（点重启前）
./scripts/restart.sh --dry-run
```
