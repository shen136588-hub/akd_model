# KDIGO 2012 AKD Cohort — 标签判断方法

## 概述

`26_kdigo2012_akd_cohort.sql` 基于 **ADQI-16**（Chawla et al., 2017, Nat Rev Nephrol, Figure 3）定义判定 AKD（Acute Kidney Disease）：

> **AKD = AKI stage ≥1 持续 ≥7 天**

物化视图：`mimiciv_derived.kdigo2012_akd_cohort`（当前版本 **v1.1**，2026-07-24）

数据源：KDIGO 2012 严格版管线（21-25），肌酐标准诊断与分期。

### 关于亚临床 stage 0.5

`kdigo2012_stages.aki_stage_creat` 存在 `0.5` 档（Cr 达 1.2–1.5× 基线，或绝对升高 0.2–0.3 mg/dL；见 `23_kdigo2012_stage_step1.sql`），仅供敏感性分析。ADQI-16 Figure 3 中 AKD 轨迹只涉及 stage 1/2/3，未纳入 0.5，因此本视图判定时把 stage 0.5 视同 `< 1`（即不入 AKD）。

---

## 时间锚点

| 锚点 | 定义 | 说明 |
|------|------|------|
| **T0** | `t0_aki_relaxed` | 该 ICU stay 首次满足 KDIGO 2012 AKI 诊断的时间 |
| **T7** | T0 + 7 天 | AKD 判定的关键时间窗终点 |

---

## AKD 标签判定流程

```
T0 (AKI onset) ────────────────── T7 ─────────── T0+14d
                                    │
优先级 1: 死亡 ≤T7 (≥T0-24h)?  ──→ AKD = 1   竞争风险
优先级 2: RRT @T7 (T7±24h)?    ──→ AKD = 1   竞争风险
优先级 3: 随访 < 48h?           ──→ NULL      数据不足
优先级 4: stage@D7 ≥1 + 有T7附近Cr? ─→ 1    确认 AKI 持续 ≥7d
优先级 5: stage@D7 ≥1 + 无T7附近Cr? → NULL  无法确认持续
优先级 6: stage@D7 <1 + 持续恢复? ──→ 0     真正恢复
优先级 7: stage@D7 <1 + 恢复不持续? → NULL  反弹/不确定
```

### 逐级说明

| 优先级 | 条件 | 结果 | 含义 |
|--------|------|:----:|------|
| 1 | 死亡时间 `≥ T0-24h` 且 `≤ T7` | **1** | 未活到 D7 的竞争风险，视为 AKD |
| 2 | `[T7-24h, T7+24h]` 内 RRT 活跃 | **1** | D7 依赖肾脏替代治疗的竞争风险 |
| 3 | 随访终点（死亡/出院/末次 Cr）距 T0 `< 48h` | **NULL** | 观察时间太短，无法判断 |
| 4 | D7 时 stage ≥1 **且** `[T7-48h, T7]` 有 Cr | **1** | 有 T7 附近实测确认 AKI 持续 |
| 5 | D7 时 stage ≥1 **但** `[T7-48h, T7]` 无 Cr | **NULL** | 无法确认 AKI 真正持续到 D7 |
| 6 | D7 时 stage <1 **且** 满足持续恢复 | **0** | 确认恢复且一周内无反弹 |
| 7 | D7 时 stage <1 **但** 未满足持续恢复 | **NULL** | 恢复质量不确定（反弹/随访不足） |

---

## 两个关键验证机制

### 1. T7 附近 Cr 确认 — `has_cr_near_t7`

要求 `[T7-48h, T7]` 窗口内至少有一次肌酐测量记录。

**目的：** 防止用早期数据外推。例如某患者的末次 Cr 在第 2 天显示 stage≥1，但 D7 附近根本没有测量——这种情况下 `stage_at_7d`（[T0, T7] 内最后一条记录的 stage）会是第 2 天的值 ≥1，但不应判定为 AKD=1。

### 2. 持续恢复 — `sustained_recovery`

四个条件**全部满足**才认定为持续恢复：

| 条件 | 代码逻辑 | 含义 |
|------|----------|------|
| ① 恢复起点在 T7 前 | `first_stage0_time IS NOT NULL` | T7 前至少有一次 `stage < 1` |
| ② D7 时仍恢复 | `stage_at_7d < 1` | [T0, T7] 窗口内最后一条记录的 stage < 1 |
| ③ 无反弹 | `has_rebound = FALSE` | 恢复后一周内无 stage ≥1（48h 内波动容忍） |
| ④ 恢复窗口 ≥48h | `recovery_duration >= 48h` | 首次恢复到恢复窗口结束至少 48 小时 |

**反弹检测细节：** 仅检测 `[first_stage0 + 48h, first_stage0 + 7d]` 窗口内的 stage ≥1 记录。恢复后 48 小时内的 stage 波动被视为短暂波动，不算反弹。

---

## 输出字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `akd_flag` | `1 / 0 / NULL` | 1=AKD, 0=恢复, NULL=不确定 |
| `stage_at_7d` | numeric | [T0, T7] 内最后一条 stage 值 |
| `stage_at_7d_time` | timestamp | 对应时间戳 |
| `has_cr_near_t7` | boolean | [T7-48h, T7] 是否有 Cr 测量 |
| `is_sustained_recovery` | boolean | 是否满足持续恢复四条件 |
| `has_rebound` | boolean | 恢复后是否发生 AKI 反弹 |
| `recovery_duration` | interval | 恢复持续时长 |
| `first_stage0_time` | timestamp | 首次恢复（stage<1）的时间 |
| `death_within_7d` | boolean | 死亡时间是否在 [T0-24h, T7] |
| `death_time` | timestamp | 死亡时间 |
| `rrt_active_at_7d` | boolean | T7±24h 内是否 RRT 活跃 |
| `followup_duration` | interval | 随访总时长（T0 至死亡/出院/末次 Cr 的最小值） |
| `exclusion_reason` | text | 排除原因，仅 `akd_flag IS NULL` 时有值 |
| `t0_time` | timestamp | AKI 首发时间 |
| `t7_time` | timestamp | T0 + 7 天 |

---

## 排除原因分类

| `exclusion_reason` | 含义 | 触发条件 |
|--------------------|------|----------|
| `early_death_lt48h` | T0 后 48h 内死亡 | 随访 <48h 且死于 T0+48h 内 |
| `early_discharge_or_transfer` | T0 后 48h 内出院/转科 | 出院时间距 T0 <48h |
| `insufficient_followup_lt48h` | 随访不足 48h（其他） | 末次 Cr 距 T0 <48h |
| `no_cr_in_entire_window` | [T0, T7] 内无 Cr | `stage_at_7d IS NULL` |
| `discharged_before_day7_no_near_t7_measurement` | D7 前出院且无 T7 附近 Cr | 出院 <7d 且末次 Cr 早于 T7-48h |
| `last_cr_before_t7_window` | 末次 Cr 早于 T7-48h | 末次 Cr < `t7_assess_low` |
| `no_cr_near_day7_other` | 无 T7 附近 Cr（其他） | 上述之外的缺失 |
| `recovery_status_uncertain_no_stage0_record` | 无 stage<1 记录 | D7 stage<1 但从未有过恢复时点 |
| `rebound_second_aki_after_initial_recovery` | 恢复后二次 AKI | 恢复后一周内出现 stage≥1 |
| `recovery_confirmed_but_insufficient_followup_after_recovery` | 恢复但随访不足 | 恢复确认但恢复窗口 <48h |
| `recovery_not_sustained_unconfirmed` | 恢复不持续（未分类） | 其他恢复相关不确定 |

---

## 版本变更

### v1.1（2026-07-24）

- **[修正 ①]** `patients.dod::timestamp` 精度补齐：`dod` 为 date 类型，直接转 timestamp 得 `00:00:00`，系统性把死亡时间提前 0–24h，个别样本导致 `followup_duration` 被低估（v1.0 有 83 例 `dod < dischtime`）。v1.1 改用 `dod::timestamp + INTERVAL '1 day' - INTERVAL '1 second'`，即当日 23:59:59。
- **[修正 ②]** `sustained_recovery` 追加"总随访 ≥48h"约束：v1.0 只要求恢复窗口 `[first_stage0, recovery_week_end]` ≥48h，但未强制 `T0 → LEAST(死亡, 出院, 末次Cr)` 也 ≥48h，导致 851 例 `is_sustained_recovery=TRUE` 却整体随访不足（虽然会被优先级 3 拦截为 NULL，主标签不受影响，但字段语义不严）。v1.1 补齐后字段语义与主判定门槛一致。
- 主标签结果小幅变动（AKD=0/1/NULL 各波动 <30 例），不改变整体分布。

### v1.0（2026-07-23）

- 首次发布：`stay_id` JOIN、`has_cr_near_t7` 硬约束、`sustained_recovery` 四条件、窗口函数单次扫描。

---

## 依赖关系

```
kdigo2012_aki_after_icu_720m_without_rrt (25)  ──→ cohort + T0
kdigo2012_stages (24)                           ──→ staging 数据 (stay_id JOIN)
rrt_active (04)                                 ──→ RRT @T7 判定
admissions + patients                           ──→ death 判定
```

**索引依赖：**
- `idx_kdigo2012_stages_stay_time` ON `kdigo2012_stages(stay_id, charttime)`
- `idx_kdigo2012_720m_stay` ON `kdigo2012_aki_after_icu_720m_without_rrt(stay_id)`
- `idx_rrt_stay_time` ON `rrt_active(stay_id, charttime)`

---

## 与 `mimiciv_akd_cohort_v0.4` 的关系

两套逻辑**完全一致**（同一 ADQI-16 框架），唯一区别是数据源：

| | `mimiciv_akd_cohort_v0.4` | `kdigo2012_akd_cohort` |
|---|---|---|
| 物化视图 | `mimiciv_derived.akd_cohort` | `mimiciv_derived.kdigo2012_akd_cohort` |
| AKI 诊断 | MIMIC 官方 KDIGO | KDIGO 2012 严格版（标准 A/B） |
| 分期标准 | 1.5×/2×/3× 基线 + RRT | + ≥0.3 mg/dL 升高 / ≥4.0 mg/dL |
| 分期表 | `kdigo_stages` | `kdigo2012_stages` |
| T0 来源 | `MIN(charttime) WHERE stage≥1` | `t0_aki_relaxed`（预计算） |

---

> 修改整合：米好 🍚  
> 日期：2026-07-23  
> 用途：李朝阳医生 AKD 预测模型课题
