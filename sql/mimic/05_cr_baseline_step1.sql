-- 05_cr_baseline_step1.sql  v2 (2026-07-22)
--
-- 变更 (性能 + 语义等价):
--   原写法把 lab (258w+) × rrt_active (70w) 做时间窗 fan-out, 再 GROUP BY 折叠,
--   笛卡儿中间结果爆炸, 单机 40+ 分钟仍未跑完.
--   下游 13_akistage_creatinine_step2 只用到 rt_active (IS NULL ? 'no' : 'yes'),
--   never uses all_rttimes → 我们只需要一个 EXISTS 布尔.
--
--   现在做法:
--     rt_active = 1 iff ∃ rrt_active 记录 (stay_id 相同, 窗口 -72h ~ +24h)
--                  且 rt_active=1;
--                 否则 NULL (下游用 IS NULL 判 'no')
--     all_rttimes 保留一个空数组占位, 兼容任何外部脚本 (不影响下游).

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.cr_baseline_step1 CASCADE;

CREATE MATERIALIZED VIEW mimiciv_derived.cr_baseline_step1 AS
SELECT
    cr.subject_id,
    cr.hadm_id,
    cr.stay_id,
    cr.intime,
    cr.outtime,
    cr.iculos,
    cr.hoslos,
    cr.admittime,
    cr.dischtime,
    cr.charttime,
    cr.creat,
    cr.creat_low_past_48hr,
    cr.creat_low_past_7day,
    ARRAY[]::timestamp[] AS all_rttimes,   -- 兼容占位 (下游未使用)
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM mimiciv_derived.rrt_active trt
        WHERE trt.stay_id = cr.stay_id
          AND trt.rt_active = 1
          AND trt.charttime >= cr.charttime - INTERVAL '72 hours'
          AND trt.charttime <= cr.charttime + INTERVAL '24 hours'
      ) THEN 1
      ELSE NULL
    END AS rt_active
FROM mimiciv_derived.akistage_creatinine_step1 cr;

CREATE INDEX IF NOT EXISTS idx_cr_baseline_step1_key
  ON mimiciv_derived.cr_baseline_step1 (hadm_id, stay_id, charttime);
CREATE INDEX IF NOT EXISTS idx_cr_baseline_step1_stay_time
  ON mimiciv_derived.cr_baseline_step1 (stay_id, charttime);
ANALYZE mimiciv_derived.cr_baseline_step1;

\echo '=== cr_baseline_step1 v2 (EXISTS-based, no fan-out) ==='
