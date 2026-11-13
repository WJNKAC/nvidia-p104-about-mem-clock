# 机制链：为什么 reserve perfmon 能让 MCLK 从 405 变成 5005

本文只写**与本工具直接相关**的那条链，逐环给出证据出处。
完整调查过程见 `/data/labs/nvidia/reports/207–226`。

---

## 0. 一条因果链

```
reserve perfmon  (NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW, bAcquire=TRUE)
   └─ perfPerfMonReserveWithClient(take=TRUE)              [perfmon.c:876]
        └─ PERFMON_SET_FLAG(PERFMON_NEEDED_BY_CLIENT)       (flags |= NVBIT(2))
             └─ PolarityGet_2X 条件② 命中                    [perf_limit_2x.c:2552]
                  └─ bSetValuesLimits = NV_FALSE
                       └─ perfLimits2xArbitrate_30(..., bSetValuesMin = FALSE)
                            └─ curValueToSet = range.maxValue      [perf_limit_30.c:561-569]
                                 └─ MCLK: 405000 → 5005000
                                      └─ 物理时钟 405 → 5005 MHz
```

反向（release / 进程退出）：`NEEDED_BY_CLIENT` 清除 ⇒ 条件① `maskIsZero` 为真且
`PERFMON_ENABLED=1` ⇒ 条件② 不命中 ⇒ `bSetValuesMin=TRUE` ⇒ 取 `range.minValue` = 405。

---

## 1. 为什么 MCLK 只可能取 405 或 5005

MCLK 的 `range` 恒为 `[405000, 5005000]`（来自 PSTATE 表查询），而写值只有两个端点：

```c
/* perf_limit_30.c:561-569  即 580 的 _nv050524rm */
for (i = 0; i < pArbOutput2x->super.nNumClockEntries; i++) {
    pArbEnt = &pArbOutput2x->super.clocks[i];
    if (bSetValuesMin) pArbEnt->curValueToSet = pArbEnt->range.minValue;
    else               pArbEnt->curValueToSet = pArbEnt->range.maxValue;
}
```

580 反编译逐字复现（`0x8a2dd0`），详见报告 224。

## 2. 为什么 GPC 能"爬"而 MCLK 不能

利用率闭环只回写到两个 domain group：`GPC2CLK` 与 `PSTATE`
（`aggPs.currentVal[]` 全文件仅两处写入，`perf_limit_2x.c:2065/2105`）。
**MCLK 不在闭环内** ⇒ 它的 `range.minValue` 永远不会被抬高
⇒ 只要极性是 TRUE（取 min），MCLK 就永远 405。

## 3. 极性是怎么算的

```c
/* perf_limit_2x.c:2539-2572，580 对应 _nv014972rm @0x898eb0 */
bSetUtilizationLimits = !perfLimitMaskIsSetAny(pLimitMaskExclude);   // mask 空 → TRUE

if (PERFMON_IS_FLAG_SET(PERFMON_NEEDED_BY_CLIENT) ||                  // ← 本工具的抓手
    !PERFMON_IS_FLAG_SET(PERFMON_ENABLED))
    bSetUtilizationLimits = NV_FALSE;

pPstate = PERF_PSTATE_GET(pPerf, perfPstatesMaxLevelGet(pPerf));
if (pPstate && getProperty(PDB_PROP_PERF_DYNAMIC_PSTATE_DISABLED) && !pPstate->bOverClocked) {
    perfLimitMaskSetLowerThan(pLimitMaskExclude, OS_LEVEL);
    bSetUtilizationLimits = NV_FALSE;
}
return bSetUtilizationLimits;
```

三个条件里：
- ① `maskIsZero` —— `excludeMask` 每次仲裁前被 `perfLimitMaskInit()` 清零，
  只有 ③ 支路会往里填，所以平时恒真
- ② `NEEDED_BY_CLIENT || !ENABLED` —— **本工具打这条**
- ③ `DYNAMIC_PSTATE_DISABLED` —— 该 property 全树无人写（`PolaritySet_2X` 是死代码，
  580 里 vtable 槽 `0xb70` 只写不读），恒不命中

## 4. `NEEDED_BY_CLIENT` 的唯一来源

全树 3 处（`grep PERFMON_NEEDED_BY_CLIENT`）：

| 位置 | 动作 |
|---|---|
| `perfmon.c:828` | 读 |
| `perfmon.c:876` | **SET** ← `perfPerfMonReserveWithClient(..., take=TRUE)` |
| `perfmon.c:934` | CLEAR ← 同函数 `take=FALSE` |
| `perf_limit_2x.c:2552` | 读（就是上面条件②） |

`perfPerfMonReserveWithClient` 由 `subdeviceCtrlCmdPerfReservePerfmonHw_KERNEL`
（`kern_perf_pm.c:238`）分派，命令号 `0x20802093`。

⚠ 该函数开头有权限检查：

```c
if (gpuIsRmProfilingPrivileged(pGpu) && !osIsAdministrator())
    return NV_ERR_INSUFFICIENT_PERMISSIONS;
```

⇒ 必须 root。

---

## 5. 与 regkey 方案的差别（为什么会省 62 W）

`MaxPerfWithPerfMon=0` 做的是 `PERFMON_ENABLED = 0`（清 bit0，`_nv050771rm` @0x865e10）：

- 条件② 恒真 ⇒ 极性恒 FALSE ⇒ **包括空闲也取 max**
- 而且 perfmon 一关，**利用率数据就没了** ⇒ `GPU_IS_IDLE` 这类"空闲压上界"的 limit 全部失效
  ⇒ `range.maxValue` 变成**绝对最高档**
- 结果：空闲 1911/5005/**69 W**（原本 139/405/7.2 W）

本工具只改 `NEEDED_BY_CLIENT`（bit2），**不动 `ENABLED`**：

- perfmon 仍在采样，利用率数据仍在
- 只是"客户端占用了 perfmon"这一条让极性临时翻 FALSE
- release 后自动恢复 ⇒ 空闲回到 139/405/7 W

---

## 6. 实测记录

**2026-11-13，Portable (192.168.1.43)，P104-100 / 580.178.04 / 6.12.116**

client 建立成功：

```
[alloc root client] ok  handle=0xc1d000a6
[open /dev/nvidia0] ok
[alloc device]      ok  handle=0xcaf00000
[alloc subdevice]   ok  handle=0xcaf00001
[perfmon acquire]   ok
```

独占互斥（证明 reserve 真的生效）：

```
A 持有中 → B acquire: status=0x63  (NV_ERR_STATE_IN_USE)
A 释放后 → B acquire: ok
```

⚠ 极性翻转效果**尚未验证**：测试时 `MaxPerfWithPerfMon=0` 仍生效，
极性本来就恒 max，MEM 一直 5005，看不出差异。需回退 regkey + 重启后再验。


---

## 7. 负结果：reserve perfmon（方案 D）无效 —— 2026-11-13 实测

**做法**：发 `NV2080_CTRL_CMD_PERF_RESERVE_PERFMON_HW (0x20802093, bAcquire=TRUE)`，
期望置位 `PERFMON_NEEDED_BY_CLIENT` ⇒ 条件② 命中 ⇒ 取 `range.maxValue`。

**结果**：

| 阶段 | P-State | GPC | MCLK | 功耗 |
|---|---|---|---|---|
| 基线 | P8 | 139 | **405** | 7.56 W |
| acquire 中 | **P0** | **1911** | **405** | 44.16 W |
| acquire + 负载 | P0 | 1911 | **405** | 92.4 W |
| release 后 | P0 | 1911 | **405** | — |

- ✅ acquire 成功、独占性成立（A 持有时 B 得 `0x63`）
- ✅ 确实有副作用（P8→P0、禁 SLCG，符合 `perfmon.c:846-882`）
- ❌ **MCLK 不动**，连起负载触发仲裁也不翻

**推断**：580 的 `RESERVE_PERFMON_HW` 处理路径与 510 源码不同 ——
它做了提功耗/禁 SLCG/占位，但**没有执行 `PERFMON_SET_FLAG(PERFMON_NEEDED_BY_CLIENT)`**
（`perfmon.c:876`）。这是推断（读不到 pPerf 内部 flags），但能同时解释三件事。

⚠ **副作用警告**：acquire 期间 GPU **常驻 P0/1911**，空闲功耗 7.6 → **44 W**。
不要在生产环境常驻调用本工具。

## 8. 负结果：PM1（方案 A′）是 no-op —— 2026-11-13 实测

```
$ nvidia-settings -a "[gpu:0]/GPUPowerMizerMode=1"
  Attribute 'GPUPowerMizerMode' ([gpu:0]) assigned value 1.   ← 报告成功

$ nvidia-settings -q "[gpu:0]/GPUPowerMizerMode" -t
  0                                                            ← 值没变

$ nvidia-smi --query-gpu=pstate,clocks.sm,clocks.mem,power.draw
  P8, 139 MHz, 405 MHz, 7.60 W                                 ← 行为没变
```

⇒ **PM1 在本环境（Wayland + 580.178.04）下被接受但不生效。**

**这推翻了 212 号报告的结论**：当时看到的 `P0/1075/5005/53.3W` 不是 PM1 的效果，
而是**负载停止后降档窗口的瞬态**（见 §9）。同一个值在不写 PM1 时也会出现。

## 9. MCLK 5005 的真实来源（2026-11-13 多轮实测）

MCLK=5005 **不是**任何"设置"的结果，而是两个短窗口：

### 窗口 A：负载停止后的降档过程（约 2.5 秒）

```
P0/1911/405/32W   × 5   (负载刚停，GPC 仍满)
P0/1075/5005/53.5W × 5  ← 这一步 MCLK 翻到 5005，GPC 被空闲钳到 1075
P8/240/405/8W     × 5
P8/139/405        × n   (稳定)
```

GPC 被 219 号说的"利用率闭环"钳下来，而 **MCLK 不在闭环内，于是取 range.max**。

> ⚠ 这个窗口**不是每次都出现**：降档有 20s+ 延迟，采样窗口不够长时整段被跳过
> （实测 12s 窗口下 5 轮里只 3 轮出现，看起来像"奇偶交替"，其实是相位巧合）。

### 窗口 B：极性状态的跨间隙继承

多轮负载实测（同一会话）：

| 实验 | load1 | load2 | load3 | load4 | load5 |
|---|---|---|---|---|---|
| 第一次（5 轮） | 405 | 405 | 405 | 405 | 405 |
| 第二次（3 轮） | **5005** | 405 | 405 | — | — |

第二次的 load1 = 5005（24/24 样本），因为**上一次实验结束时的极性是 max，被继承了**。

⇒ **"第 1 轮负载 5005、之后 405"是状态继承，不是随机。**
这也解释了 formb_b1 的"第 1 次 8→0=5005、第 2 次=405"。

### 结论

**没有任何用户态手段能让 MCLK 持续 5005**：
- PM1 no-op（§8）
- reserve perfmon 不动 MCLK（§7）
- 5005 只在降档窗口（2.5s）和跨会话继承的首轮负载里出现

⇒ 要"持续 5005"，**只能走方案 A**（`MaxPerfWithPerfMon=0`，清 `PERFMON_ENABLED`）。
