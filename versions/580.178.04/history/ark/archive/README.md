# archive —— 前序方案的脚本与工具

这些是方案 A（`MaxPerfWithPerfMon=0` regkey）阶段的产物。

**状态更正（2026-11-13 16:12）**：
- ❌ 方案 D（reserve perfmon）**已实测证伪** —— acquire 成功但 MCLK 不翻，且常驻 44W
- ✅ **方案 A 重新成为候选终态** —— 它是唯一被实测证明能把 MCLK 拉到 5005 的手段
- ❌ 方案 A′（PM1 常驻）**已实测证伪** —— `nvidia-settings -a` 报 "assigned value 1"
  但读回仍是 0、行为无变化 ⇒ **PM1 在 Wayland + 580 下是 no-op**

所以本目录不是"被取代"，而是**当前最优解的实现**。保留它。

| 文件 | 说明 |
|---|---|
| `maxperf_verify.sh` | 方案 A 的验证脚本：空闲 10s 基线 + 5 轮×25s 负载 + 判据汇总 |
| `clburn.c` | OpenCL 负载生成器（FMA / triad 两种 kernel），带最小 CL 声明，无 SDK 依赖 |

## 为什么被取代

`MaxPerfWithPerfMon=0` 实测有效（显存带宽 19.3 → 278.6 GB/s），但代价是
**空闲功耗 7.2 W → 69 W**：该键清掉 `PERFMON_ENABLED`，连带让利用率数据消失，
所有"空闲压上界"的 limit 失效 ⇒ 空闲也被钉在最高档，且无法调掉。

本工具只在需要时翻转极性，空闲自动回 405/7 W。

详见 `/data/labs/nvidia/reports/226-N236-方案A修复成功-显存带宽19.3到278.6GBps-14.4倍.md`
