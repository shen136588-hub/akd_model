-- s03_kdigo2012_stages.sql  (2026-07-22)
-- =============================================================================
-- SICdb KDIGO 2012 严格版最终 staging 视图 (forward-fill, 仅 t0 之后)
--
-- 逻辑:
--   1) 每小时时间轴 (generate_series)
--   2) 仅保留 t0_aki_relaxed 之后的时点
--   3) 肌酐分期: 前向填充 kdigo2012_creatinine.aki_stage_creat (改良 CASE)
--   4) 尿量分期: 前向填充 kdigo_uo.aki_stage_uo
--   5) RRT 窗口: EXISTS 检查
--   6) 综合分期: CKD 跳过 UO; RRT 覆盖 Stage 3
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS sicdb.kdigo2012_stages CASCADE;

CREATE MATERIALIZED VIEW sicdb.kdigo2012_stages AS
WITH
-- 每小时时间轴
-- ★ 2026-08-06 FIX (ward-followup): 上限原为 icu_los_sec, 导致时间轴被 ICU 出室
--    硬截断, 无法覆盖"同次住院病房期"的 Cr, 与 MIMIC(78.8% 超出 ICU)/eICU(62.7%)
--    的随访口径不一致, 违背课题红线"随访 = ICU 期 + 同次住院病房 Cr"。
--    实测: 原设定下仅 664/3049 (21.8%) 的 T7 落在网格内; 496 例(16.3%)本应可评估
--    却被误丢为 NULL。
--    注意: sicdb.icustays 里 icu_los_sec 就是 cases.timeofstay 的别名(恒等),
--    故改用 timeofstay 无效; hospitalstaydays 有 512 例异常(< ICU 时长)且仍漏 447 例。
--    唯一 100% 覆盖 T7 的方案是 icu_los_sec + 7d 余量 (604800s)。
--    forward-fill 子查询取 <= 当前点的最后一条真实值, 不会伪造数据。
timeline AS (
    SELECT
        stay_id,
        generate_series(
            0::bigint,
            (icu_los_sec + 604800)::bigint,   -- ICU 出室 + 7d, 覆盖病房随访期
            3600::bigint
        ) AS charttime_offset
    FROM sicdb.icustays
    WHERE icu_los_sec IS NOT NULL AND icu_los_sec > 0
),
-- 仅保留 t0 之后的 timeline
onset AS (
    SELECT stay_id, t0_aki_relaxed_sec AS t0_sec
    FROM sicdb.kdigo2012_aki_onset
    WHERE t0_aki_relaxed_sec IS NOT NULL
),
t_t0 AS (
    SELECT t.stay_id, t.charttime_offset
    FROM timeline t
    JOIN onset o ON t.stay_id = o.stay_id
    WHERE t.charttime_offset >= o.t0_sec
),
-- 前向填充肌酐分期 (改良 CASE)
cr_ffill AS (
    SELECT
        t.stay_id,
        t.charttime_offset,
        (
            SELECT k.aki_stage_creat
            FROM sicdb.kdigo2012_creatinine k
            WHERE k.stay_id = t.stay_id
              AND k.charttime_offset <= t.charttime_offset
            ORDER BY k.charttime_offset DESC
            LIMIT 1
        ) AS aki_stage_creat,
        (
            SELECT k.rrt_72hr_prior_and_24hr_post
            FROM sicdb.kdigo2012_creatinine k
            WHERE k.stay_id = t.stay_id
              AND k.charttime_offset <= t.charttime_offset
            ORDER BY k.charttime_offset DESC
            LIMIT 1
        ) AS rrt_72hr_prior_and_24hr_post_creat
    FROM t_t0 t
),
-- 前向填充尿量分期
uo_ffill AS (
    SELECT
        t.stay_id,
        t.charttime_offset,
        (
            SELECT k.aki_stage_uo
            FROM sicdb.kdigo_uo k
            WHERE k.stay_id = t.stay_id
              AND k.charttime_offset <= t.charttime_offset
            ORDER BY k.charttime_offset DESC
            LIMIT 1
        ) AS aki_stage_uo
    FROM t_t0 t
),
-- 每小时点级 RRT 窗口
rrt_hourly AS (
    SELECT
        t.stay_id,
        t.charttime_offset,
        CASE WHEN EXISTS (
            SELECT 1 FROM sicdb.rrt r
            WHERE r.stay_id = t.stay_id
              AND r.dialysis_active = 1
              AND r.charttime_offset >= t.charttime_offset - 259200
              AND r.charttime_offset <= t.charttime_offset + 86400
        ) THEN 'yes' ELSE 'no' END AS rrt_72hr_prior_and_24hr_post
    FROM t_t0 t
),
-- stay 是否曾经 AKI
stay_aki AS (
    SELECT
        stay_id,
        CASE WHEN MAX(COALESCE(aki_stage_creat, 0)) > 0 THEN 'yes' ELSE 'no' END AS aki
    FROM cr_ffill
    GROUP BY stay_id
),
-- CKD 诊断 + baseline
stay_kd AS (
    SELECT
        b.stay_id,
        b.cr_baseline,
        k.kd_diagnosis,
        k.icd_kd_diagnosis
    FROM sicdb.cr_baseline b
    LEFT JOIN sicdb.aki_or_ckd k ON b.stay_id = k.stay_id
),
merged AS (
    SELECT
        t.stay_id,
        t.charttime_offset,
        ROUND(t.charttime_offset / 3600.0, 2)                AS charttime_hours,
        ROUND(t.charttime_offset / 86400.0, 2)               AS charttime_days,
        cr.aki_stage_creat                                    AS aki_stage_creat_raw,
        r.rrt_72hr_prior_and_24hr_post,
        uo.aki_stage_uo,
        sa.aki                                                AS aki_stay_flag,
        sk.kd_diagnosis,
        sk.icd_kd_diagnosis,
        sk.cr_baseline,
        o.t0_sec
    FROM t_t0 t
    JOIN onset o ON t.stay_id = o.stay_id
    LEFT JOIN cr_ffill cr   ON t.stay_id = cr.stay_id  AND t.charttime_offset = cr.charttime_offset
    LEFT JOIN uo_ffill uo   ON t.stay_id = uo.stay_id  AND t.charttime_offset = uo.charttime_offset
    LEFT JOIN rrt_hourly r  ON t.stay_id = r.stay_id   AND t.charttime_offset = r.charttime_offset
    LEFT JOIN stay_aki  sa  ON t.stay_id = sa.stay_id
    LEFT JOIN stay_kd   sk  ON t.stay_id = sk.stay_id
)
SELECT
    stay_id,
    charttime_offset,
    charttime_hours,
    charttime_days,
    t0_sec,
    ROUND((charttime_offset - t0_sec) / 3600.0, 2)                          AS charttime_hours_since_t0,
    COALESCE(aki_stage_creat_raw, 0)                                         AS aki_stage_creat_raw,
    -- ★ RRT 时间点级覆盖
    CASE
        WHEN aki_stay_flag = 'yes' AND rrt_72hr_prior_and_24hr_post = 'yes' THEN 3::numeric
        ELSE COALESCE(aki_stage_creat_raw, 0)
    END                                                                      AS aki_stage_creat,
    COALESCE(aki_stage_uo, 0)                                                AS aki_stage_uo,
    rrt_72hr_prior_and_24hr_post,
    CASE WHEN rrt_72hr_prior_and_24hr_post = 'yes' THEN 1 ELSE 0 END         AS rrt_flag,
    -- ★ 综合分期
    CASE
        WHEN (kd_diagnosis LIKE '%ckd%' AND cr_baseline >= 1.5)
             OR icd_kd_diagnosis ILIKE '%dependence on renal dialysis%'
             OR icd_kd_diagnosis ILIKE '%dialyse%'
        THEN CASE
               WHEN aki_stay_flag = 'yes' AND rrt_72hr_prior_and_24hr_post = 'yes' THEN 3::numeric
               ELSE COALESCE(aki_stage_creat_raw, 0)
             END
        ELSE GREATEST(
               CASE
                 WHEN aki_stay_flag = 'yes' AND rrt_72hr_prior_and_24hr_post = 'yes' THEN 3::numeric
                 ELSE COALESCE(aki_stage_creat_raw, 0)
               END,
               COALESCE(aki_stage_uo, 0)::numeric
             )
    END                                                                      AS aki_stage
FROM merged;

CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_stay
    ON sicdb.kdigo2012_stages (stay_id);
CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_stay_time
    ON sicdb.kdigo2012_stages (stay_id, charttime_offset);
ANALYZE sicdb.kdigo2012_stages;

\echo '=== kdigo2012_stages (KDIGO 2012 严格版, 从 t0 起 forward-fill) 已创建 ==='