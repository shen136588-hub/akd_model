-- 09_cr_baseline_min_p10_p20.sql  v4.1 (2026-07-25)
-- 近端窗口基线（合并 -7d ~ 全住院期），对齐 SICdb v3 Tier 2 语义
--
-- 【v4.1 修正 2026-07-25】
--   UNLOGGED TABLE → 普通 TABLE.
--   原因: UNLOGGED 表不写 WAL, 数据库崩溃/重启后会被自动清空,
--   导致 _crb_near / _agg / _time 三表变空 → Tier2 视图 0 行 →
--   大量患者跳过住院近端实测基线, fallback 到 Tier3 MDRD 反推,
--   AKI 系统性误判 (基线高估 → 漏诊; 或低估 → 误诊).
--   修为普通表后持久化, 重启不丢.
--
-- 变更:
--   1) 使用 05_cr_baseline_step1 中的 **时间点级 rt_active** 过滤（不再是 stay-level）
--      —— 剔除任一 -72h/+24h 邻域有 RRT 的肌酐点，避免透析后骤降污染基线
--   2) 时间分层锚点改为「相对 admittime 的小时数」:
--        <= 168h (admittime+7d) → 用 min
--        <= 336h                → p10
--        > 336h                 → p20
--      **负偏移 (入院前 -7d ~ 0h) 自动落入 "≤7d" 一档（"最近可用真实值优先"）**
--   3) 组织为普通中间表 (v4.1 已由 UNLOGGED 改回普通表, 重启不丢), 明显加速大表 GROUP BY
--
-- 依赖: mimiciv_derived.cr_baseline_step1 (含 rt_active 时点标记)

SET client_encoding = 'UTF8';
SET work_mem = '512MB';
SET maintenance_work_mem = '1GB';

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_min_p10_p20 CASCADE;

-- 1) 排除 stay-level 无 RRT 记录患者；剔除时点级 RRT 邻域
DROP TABLE IF EXISTS mimiciv_derived._crb_near;
CREATE TABLE mimiciv_derived._crb_near AS
SELECT
    cr.subject_id,
    cr.hadm_id,
    cr.stay_id,
    cr.admittime,
    cr.charttime,
    cr.creat
FROM mimiciv_derived.cr_baseline_step1 cr
WHERE cr.hadm_id NOT IN (SELECT hadm_id FROM mimiciv_derived.id_rrt_without_record)
  AND cr.rt_active IS NULL;  -- 05 版 rt_active 已用 -72h/+24h 邻域打标记
CREATE INDEX ON mimiciv_derived._crb_near (hadm_id);
CREATE INDEX ON mimiciv_derived._crb_near (subject_id, hadm_id);
ANALYZE mimiciv_derived._crb_near;

-- 2) 聚合 min / p10 / p20
DROP TABLE IF EXISTS mimiciv_derived._crb_near_agg;
CREATE TABLE mimiciv_derived._crb_near_agg AS
SELECT
    subject_id, hadm_id,
    MIN(creat)                                             AS cr_near_min,
    PERCENTILE_DISC(0.1) WITHIN GROUP (ORDER BY creat)     AS p10_cr,
    PERCENTILE_DISC(0.2) WITHIN GROUP (ORDER BY creat)     AS p20_cr,
    COUNT(*)                                               AS n_near
FROM mimiciv_derived._crb_near
GROUP BY subject_id, hadm_id;
CREATE INDEX ON mimiciv_derived._crb_near_agg (hadm_id);
ANALYZE mimiciv_derived._crb_near_agg;

-- 3) 找 min 出现时刻（用于时间分层）
DROP TABLE IF EXISTS mimiciv_derived._crb_near_time;
CREATE TABLE mimiciv_derived._crb_near_time AS
SELECT
    ep.hadm_id,
    MIN(ep.charttime) AS time_of_min_cr,
    MIN(ep.admittime) AS admittime  -- 每个 hadm 一个 admittime，MIN 只是为了聚合
FROM mimiciv_derived._crb_near ep
JOIN mimiciv_derived._crb_near_agg m
    ON ep.hadm_id = m.hadm_id AND ep.creat = m.cr_near_min
GROUP BY ep.hadm_id;
CREATE INDEX ON mimiciv_derived._crb_near_time (hadm_id);
ANALYZE mimiciv_derived._crb_near_time;

-- 4) 组合最终物化视图
CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_min_p10_p20 AS
SELECT
    a.subject_id,
    a.hadm_id,
    CASE
        WHEN EXTRACT(EPOCH FROM (t.time_of_min_cr - t.admittime)) / 3600 <= 168 THEN a.cr_near_min
        WHEN EXTRACT(EPOCH FROM (t.time_of_min_cr - t.admittime)) / 3600 <= 336 THEN a.p10_cr
        ELSE a.p20_cr
    END AS cr_baseline,
    CASE
        WHEN t.time_of_min_cr < t.admittime                                                         THEN 'near_min_preadmit_7d'
        WHEN EXTRACT(EPOCH FROM (t.time_of_min_cr - t.admittime)) / 3600 <= 168                     THEN 'near_min_within_7d'
        WHEN EXTRACT(EPOCH FROM (t.time_of_min_cr - t.admittime)) / 3600 <= 336                     THEN 'near_p10_7_14d'
        ELSE                                                                                             'near_p20_after_14d'
    END AS method_used,
    a.cr_near_min,
    a.p10_cr,
    a.p20_cr,
    a.n_near
FROM mimiciv_derived._crb_near_agg a
JOIN mimiciv_derived._crb_near_time t ON a.hadm_id = t.hadm_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_crb_np_hadm ON mimiciv_derived.cr_baseline_min_p10_p20 (hadm_id);
ANALYZE mimiciv_derived.cr_baseline_min_p10_p20;

\echo '=== cr_baseline_min_p10_p20 v4.1 (普通表, 重启不丢; 近端窗口+时点级RRT剔除) 已创建 ==='
