-- =============================================================================
-- 26b_kdigo2012_with_rrt_akd_cohort.sql — KDIGO 2012 AKD Cohort (含 RRT 人群, v1.0)
-- Author: 米好 for 朝阳    Date: 2026-08-02
--
-- 目的: 26_kdigo2012_akd_cohort.sql (v1.1, 排除 RRT) 的孪生视图。原视图保留不动。
--       本视图**不排除 RRT 人群**, 用于「含 RRT 的全 ICU-onset AKI 人群」分析。
--
-- 上游: mimiciv_derived.kdigo2012_aki_after_icu_720m  (25b, 不含 RRT 标注列)
--
-- =============================================================================
-- 相对 26 号(without_rrt)的三处方法学新增(缺一不可):
--
-- ① 慢性透析/ESRD 必须排除
--    RRT 早于 T0 或有透析依赖史 → KDIGO AKI 定义不适用 → akd_flag = NULL,
--    exclusion_reason = 'chronic_dialysis_or_rrt_before_t0'。
--    (这不是"数据缺失"排除, 是定义层面不适用。)
--
-- ② RRT 期间的 Cr 不可用于判定"恢复"
--    透析会人为压低 Scr → stage 可能假性降到 <1 → 会把最重症患者误判为 AKD=0。
--    本视图对 recovery 判定**只采信 RRT 净化影响窗之外的 Cr**:
--       净化影响窗 = [首次 RRT, 末次 RRT + 72h]
--    该窗内的 stage 记录**不参与** first_stage0_time / stage_at_7d(恢复方向)判定,
--    但 stage>=1 的记录仍可用于确认未恢复(方向安全, 不会低估)。
--
-- ③ RRT 竞争风险按 ADQI-16 处理
--    T7 前后 24h 内仍有活跃 RRT → AKD=1 (等同 AKD stage 3D)。
--    T0 后启动、T7 前成功撤离 RRT → 回归 Cr 判定, 但用 ② 的净化窗规则。
--
-- 其余判定逻辑(死亡竞争风险、随访≥48h、T7 附近 Cr 确认、持续恢复+反弹检测)
-- 与 26 号 v1.1 **完全一致**, 保证两个队列的 AKD 口径可直接对比。
--
-- 新增输出列(供敏感性分析与流程图):
--   rrt_ever / rrt_first_time / rrt_last_time / rrt_before_t0 / esrd_or_rrt_history
--   rrt_started_after_t0        T0 之后才启动 RRT (本视图真正新增的研究人群)
--   rrt_weaned_before_t7        T0 后启动且 T7 前撤离
--   n_cr_dropped_by_rrt_window  因落在净化窗内而被排除的 Cr 记录数(透明化)
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_kdigo2012_stages_stay_time
ON mimiciv_derived.kdigo2012_stages (stay_id, charttime)
WHERE aki_stage_creat IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_rrt_stay_time
ON mimiciv_derived.rrt_active (stay_id, charttime);

DROP MATERIALIZED VIEW IF EXISTS mimiciv_derived.kdigo2012_with_rrt_akd_cohort CASCADE;
CREATE MATERIALIZED VIEW IF NOT EXISTS mimiciv_derived.kdigo2012_with_rrt_akd_cohort
TABLESPACE pg_default
AS
 WITH cohort AS (
         SELECT DISTINCT v.subject_id,
            v.hadm_id,
            v.stay_id,
            v.intime,
            v.outtime,
            v.admittime,
            v.dischtime
           FROM mimiciv_derived.kdigo2012_aki_after_icu_720m v
          WHERE v.stayid_order = 1
        ), t0 AS (
         SELECT kdigo2012_aki_after_icu_720m.stay_id,
            min(kdigo2012_aki_after_icu_720m.t0_aki_relaxed) AS t0_time
           FROM mimiciv_derived.kdigo2012_aki_after_icu_720m
          WHERE kdigo2012_aki_after_icu_720m.stayid_order = 1
          GROUP BY kdigo2012_aki_after_icu_720m.stay_id
        ), death AS (
         SELECT b_1.stay_id,
            COALESCE(a.deathtime, p.dod::timestamp without time zone + '1 day'::interval - '00:00:01'::interval) AS death_time
           FROM cohort b_1
             JOIN mimiciv_hosp.admissions a USING (hadm_id)
             JOIN mimiciv_hosp.patients p ON a.subject_id = p.subject_id
        ), rrt_span AS (
         SELECT rrt_active.stay_id,
            min(rrt_active.charttime) AS rrt_first_time,
            max(rrt_active.charttime) AS rrt_last_time
           FROM mimiciv_derived.rrt_active
          WHERE rrt_active.rt_active = 1 AND rrt_active.stay_id IS NOT NULL
          GROUP BY rrt_active.stay_id
        ), rrt_history AS (
         SELECT DISTINCT id_rrt_without_record.stay_id
           FROM mimiciv_derived.id_rrt_without_record
          WHERE id_rrt_without_record.stay_id IS NOT NULL
        ), rrt_diag_text AS (
         SELECT DISTINCT kdigo2012_stages.stay_id
           FROM mimiciv_derived.kdigo2012_stages
          WHERE kdigo2012_stages.stay_id IS NOT NULL AND (lower(COALESCE(kdigo2012_stages.kd_diagnosis, ''::text)) ~~ '%rrt%'::text OR lower(COALESCE(kdigo2012_stages.icd_kd_diagnosis, ''::text)) ~~ '%dependence on renal dialysis%'::text)
        ), base AS (
         SELECT c.subject_id,
            c.hadm_id,
            c.stay_id,
            c.intime,
            c.outtime,
            c.admittime,
            c.dischtime,
            t.t0_time,
            t.t0_time + '7 days'::interval AS t7_time,
            t.t0_time + '7 days'::interval - '24:00:00'::interval AS rrt_low,
            t.t0_time + '7 days'::interval + '24:00:00'::interval AS rrt_high,
            t.t0_time + '7 days'::interval - '48:00:00'::interval AS t7_assess_low,
            rs.stay_id IS NOT NULL AS rrt_ever,
            rs.rrt_first_time AS rrt_span_start,
            rs.rrt_last_time AS rrt_span_end,
            rs.rrt_first_time IS NOT NULL AND rs.rrt_first_time < c.intime AS rrt_before_icu,
            rs.rrt_first_time IS NOT NULL AND rs.rrt_first_time < t.t0_time AS rrt_before_t0,
            rh.stay_id IS NOT NULL OR rd.stay_id IS NOT NULL AS esrd_or_rrt_history,
            rs.rrt_first_time AS clear_win_lo,
            rs.rrt_last_time + '72:00:00'::interval AS clear_win_hi
           FROM cohort c
             JOIN t0 t USING (stay_id)
             LEFT JOIN rrt_span rs ON rs.stay_id = c.stay_id
             LEFT JOIN rrt_history rh ON rh.stay_id = c.stay_id
             LEFT JOIN rrt_diag_text rd ON rd.stay_id = c.stay_id
        ), kd_window_all AS (
         SELECT b_1.stay_id,
            b_1.t0_time,
            b_1.t7_time,
            b_1.t7_assess_low,
            k.charttime,
            k.aki_stage_creat AS stage,
            b_1.clear_win_lo IS NOT NULL AND k.charttime >= b_1.clear_win_lo AND k.charttime <= b_1.clear_win_hi AS in_rrt_clear_window
           FROM base b_1
             JOIN mimiciv_derived.kdigo2012_stages k ON k.stay_id = b_1.stay_id
          WHERE k.aki_stage_creat IS NOT NULL AND k.charttime >= b_1.t0_time AND k.charttime <= (b_1.t0_time + '14 days'::interval)
        ), kd_labeled AS (
         SELECT kd_window_all.stay_id,
            kd_window_all.t0_time,
            kd_window_all.t7_time,
            kd_window_all.t7_assess_low,
            kd_window_all.charttime,
            kd_window_all.stage,
            kd_window_all.in_rrt_clear_window,
            min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) AS first_stage0_time,
                CASE
                    WHEN min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) IS NOT NULL AND kd_window_all.charttime > min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) THEN 1
                    ELSE 0
                END AS after_first_recovery,
                CASE
                    WHEN min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) IS NOT NULL AND kd_window_all.charttime > min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) AND kd_window_all.charttime <= (min(kd_window_all.charttime) FILTER (WHERE kd_window_all.stage < 1::numeric AND kd_window_all.charttime <= kd_window_all.t7_time AND NOT kd_window_all.in_rrt_clear_window) OVER (PARTITION BY kd_window_all.stay_id) + '7 days'::interval) THEN 1
                    ELSE 0
                END AS within_recovery_week,
                CASE
                    WHEN kd_window_all.charttime >= kd_window_all.t0_time AND kd_window_all.charttime <= kd_window_all.t7_time THEN 1
                    ELSE 0
                END AS within_t7_window
           FROM kd_window_all
        ), kd_agg AS (
         SELECT kd_labeled.stay_id,
            (array_agg(kd_labeled.stage ORDER BY kd_labeled.charttime DESC) FILTER (WHERE kd_labeled.within_t7_window = 1 AND (NOT kd_labeled.in_rrt_clear_window OR kd_labeled.stage >= 1::numeric)))[1] AS stage_at_7d,
            (array_agg(kd_labeled.charttime ORDER BY kd_labeled.charttime DESC) FILTER (WHERE kd_labeled.within_t7_window = 1 AND (NOT kd_labeled.in_rrt_clear_window OR kd_labeled.stage >= 1::numeric)))[1] AS stage_at_7d_time,
            max(
                CASE
                    WHEN kd_labeled.charttime >= kd_labeled.t7_assess_low AND kd_labeled.charttime <= kd_labeled.t7_time AND (NOT kd_labeled.in_rrt_clear_window OR kd_labeled.stage >= 1::numeric) THEN 1
                    ELSE 0
                END)::boolean AS has_cr_near_t7,
            min(kd_labeled.charttime) FILTER (WHERE kd_labeled.stage < 1::numeric AND kd_labeled.charttime <= kd_labeled.t7_time AND NOT kd_labeled.in_rrt_clear_window) AS first_stage0_time,
            max(
                CASE
                    WHEN kd_labeled.within_recovery_week = 1 AND kd_labeled.charttime > (kd_labeled.first_stage0_time + '48:00:00'::interval) AND kd_labeled.stage >= 1::numeric THEN 1
                    ELSE 0
                END) = 1 AS has_rebound,
            max(
                CASE
                    WHEN kd_labeled.within_recovery_week = 1 THEN kd_labeled.charttime
                    ELSE NULL::timestamp without time zone
                END) AS recovery_week_end,
            count(*) FILTER (WHERE kd_labeled.in_rrt_clear_window AND kd_labeled.stage < 1::numeric) AS n_cr_dropped_by_rrt_window
           FROM kd_labeled
          GROUP BY kd_labeled.stay_id
        ), last_cr AS (
         SELECT b_1.stay_id,
            max(k.charttime) AS last_cr_time
           FROM base b_1
             JOIN mimiciv_derived.kdigo2012_stages k ON k.stay_id = b_1.stay_id
          WHERE k.aki_stage_creat IS NOT NULL
          GROUP BY b_1.stay_id
        ), sustained_recovery AS (
         SELECT ka_1.stay_id,
            ka_1.first_stage0_time IS NOT NULL AND ka_1.stage_at_7d < 1::numeric AND COALESCE(ka_1.has_rebound, false) = false AND (COALESCE(ka_1.recovery_week_end, b_1.t7_time) - ka_1.first_stage0_time) >= '48:00:00'::interval AND (LEAST(COALESCE(d_1.death_time, 'infinity'::timestamp without time zone), b_1.dischtime, COALESCE(lc_1.last_cr_time, 'infinity'::timestamp without time zone)) - b_1.t0_time) >= '48:00:00'::interval AS is_sustained_recovery,
                CASE
                    WHEN ka_1.first_stage0_time IS NOT NULL THEN COALESCE(ka_1.recovery_week_end, ka_1.stage_at_7d_time) - ka_1.first_stage0_time
                    ELSE NULL::interval
                END AS recovery_duration,
            COALESCE(ka_1.has_rebound, false) AS has_rebound
           FROM kd_agg ka_1
             JOIN base b_1 ON ka_1.stay_id = b_1.stay_id
             LEFT JOIN death d_1 ON d_1.stay_id = ka_1.stay_id
             LEFT JOIN last_cr lc_1 ON lc_1.stay_id = ka_1.stay_id
        ), rrt_at_7d AS (
         SELECT b_1.stay_id,
            true AS rrt_active_at_7d
           FROM base b_1
          WHERE (EXISTS ( SELECT 1
                   FROM mimiciv_derived.rrt_active r_1
                  WHERE r_1.stay_id = b_1.stay_id AND r_1.rt_active = 1 AND r_1.charttime >= b_1.rrt_low AND r_1.charttime <= b_1.rrt_high))
        )
 SELECT b.subject_id,
    b.hadm_id,
    b.stay_id,
    b.intime AS icu_intime,
    b.outtime AS icu_outtime,
    b.admittime,
    b.dischtime,
    d.death_time,
    b.t0_time,
    b.t7_time,
    COALESCE(b.rrt_ever, false) AS rrt_ever,
    b.rrt_span_start AS rrt_first_time,
    b.rrt_span_end AS rrt_last_time,
    COALESCE(b.rrt_before_icu, false) AS rrt_before_icu,
    COALESCE(b.rrt_before_t0, false) AS rrt_before_t0,
    COALESCE(b.esrd_or_rrt_history, false) AS esrd_or_rrt_history,
    b.rrt_span_start IS NOT NULL AND b.rrt_span_start >= b.t0_time AS rrt_started_after_t0,
    b.rrt_span_start IS NOT NULL AND b.rrt_span_start >= b.t0_time AND b.rrt_span_end < b.rrt_low AS rrt_weaned_before_t7,
    COALESCE(ka.n_cr_dropped_by_rrt_window, 0::bigint) AS n_cr_dropped_by_rrt_window,
    d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= b.t7_time AS death_within_7d,
    COALESCE(ka.stage_at_7d, 0::numeric) AS stage_at_7d,
    ka.stage_at_7d_time,
    COALESCE(ka.has_cr_near_t7, false) AS has_cr_near_t7,
    ka.first_stage0_time,
    COALESCE(sr.is_sustained_recovery, false) AS is_sustained_recovery,
    sr.recovery_duration,
    COALESCE(sr.has_rebound, false) AS has_rebound,
    COALESCE(r.rrt_active_at_7d, false) AS rrt_active_at_7d,
    LEAST(COALESCE(d.death_time, 'infinity'::timestamp without time zone), b.dischtime, COALESCE(lc.last_cr_time, 'infinity'::timestamp without time zone)) - b.t0_time AS followup_duration,
        CASE
            WHEN COALESCE(b.rrt_before_t0, false) OR COALESCE(b.rrt_before_icu, false) OR COALESCE(b.esrd_or_rrt_history, false) THEN NULL::integer
            WHEN d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= b.t7_time THEN 1
            WHEN COALESCE(r.rrt_active_at_7d, false) THEN 1
            WHEN (LEAST(COALESCE(d.death_time, 'infinity'::timestamp without time zone), b.dischtime, COALESCE(lc.last_cr_time, 'infinity'::timestamp without time zone)) - b.t0_time) < '48:00:00'::interval THEN NULL::integer
            WHEN COALESCE(ka.stage_at_7d, 0::numeric) >= 1::numeric AND COALESCE(ka.has_cr_near_t7, false) = true THEN 1
            WHEN COALESCE(ka.stage_at_7d, 0::numeric) >= 1::numeric AND COALESCE(ka.has_cr_near_t7, false) = false THEN NULL::integer
            WHEN COALESCE(ka.stage_at_7d, 99::numeric) < 1::numeric AND COALESCE(sr.is_sustained_recovery, false) = true THEN 0
            WHEN COALESCE(ka.stage_at_7d, 99::numeric) < 1::numeric AND COALESCE(sr.is_sustained_recovery, false) = false THEN NULL::integer
            ELSE NULL::integer
        END AS akd_flag,
        CASE
            WHEN COALESCE(b.rrt_before_t0, false) OR COALESCE(b.rrt_before_icu, false) OR COALESCE(b.esrd_or_rrt_history, false) THEN 'chronic_dialysis_or_rrt_before_t0'::text
            WHEN (LEAST(COALESCE(d.death_time, 'infinity'::timestamp without time zone), b.dischtime, COALESCE(lc.last_cr_time, 'infinity'::timestamp without time zone)) - b.t0_time) < '48:00:00'::interval AND NOT (d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= b.t7_time) AND NOT COALESCE(r.rrt_active_at_7d, false) THEN
            CASE
                WHEN d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= (b.t0_time + '48:00:00'::interval) THEN 'early_death_lt48h'::text
                WHEN (b.dischtime - b.t0_time) < '48:00:00'::interval THEN 'early_discharge_or_transfer'::text
                ELSE 'insufficient_followup_lt48h'::text
            END
            WHEN COALESCE(ka.has_cr_near_t7, false) = false AND NOT (d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= b.t7_time) AND NOT COALESCE(r.rrt_active_at_7d, false) AND (LEAST(COALESCE(d.death_time, 'infinity'::timestamp without time zone), b.dischtime, COALESCE(lc.last_cr_time, 'infinity'::timestamp without time zone)) - b.t0_time) >= '48:00:00'::interval THEN
            CASE
                WHEN ka.stage_at_7d IS NULL AND COALESCE(ka.n_cr_dropped_by_rrt_window, 0::bigint) > 0 THEN 'cr_unusable_during_rrt_clearance_window'::text
                WHEN ka.stage_at_7d IS NULL THEN 'no_cr_in_entire_window'::text
                WHEN (b.dischtime - b.t0_time) < '7 days'::interval THEN 'discharged_before_day7_no_near_t7_measurement'::text
                WHEN lc.last_cr_time < b.t7_assess_low THEN 'last_cr_before_t7_window'::text
                ELSE 'no_cr_near_day7_other'::text
            END
            WHEN COALESCE(ka.stage_at_7d, 99::numeric) < 1::numeric AND COALESCE(sr.is_sustained_recovery, false) = false AND NOT (d.death_time IS NOT NULL AND d.death_time >= (b.t0_time - '24:00:00'::interval) AND d.death_time <= b.t7_time) AND NOT COALESCE(r.rrt_active_at_7d, false) THEN
            CASE
                WHEN ka.first_stage0_time IS NULL THEN 'recovery_status_uncertain_no_stage0_record'::text
                WHEN COALESCE(sr.has_rebound, false) = true THEN 'rebound_second_aki_after_initial_recovery'::text
                WHEN ka.stage_at_7d IS NOT NULL AND ka.stage_at_7d < 1::numeric AND ka.first_stage0_time IS NOT NULL AND COALESCE(sr.has_rebound, false) = false THEN 'recovery_confirmed_but_insufficient_followup_after_recovery'::text
                ELSE 'recovery_not_sustained_unconfirmed'::text
            END
            ELSE NULL::text
        END AS exclusion_reason
   FROM base b
     LEFT JOIN death d USING (stay_id)
     LEFT JOIN kd_agg ka USING (stay_id)
     LEFT JOIN last_cr lc USING (stay_id)
     LEFT JOIN rrt_at_7d r USING (stay_id)
     LEFT JOIN sustained_recovery sr USING (stay_id)
WITH DATA;

ALTER TABLE IF EXISTS mimiciv_derived.kdigo2012_with_rrt_akd_cohort
    OWNER TO postgres;


CREATE INDEX idx_kd2012_withrrt_akd_flag
    ON mimiciv_derived.kdigo2012_with_rrt_akd_cohort USING btree
    (akd_flag);

CREATE INDEX idx_kd2012_withrrt_akd_hadm
    ON mimiciv_derived.kdigo2012_with_rrt_akd_cohort USING btree
    (hadm_id);

CREATE INDEX idx_kd2012_withrrt_akd_rrt
    ON mimiciv_derived.kdigo2012_with_rrt_akd_cohort USING btree
    (rrt_ever);

CREATE UNIQUE INDEX idx_kd2012_withrrt_akd_stay
    ON mimiciv_derived.kdigo2012_with_rrt_akd_cohort USING btree
    (stay_id);

ANALYZE mimiciv_derived.kdigo2012_with_rrt_akd_cohort;

\echo '=== kdigo2012_with_rrt_akd_cohort v1.0 (含 RRT, ADQI-16 + RRT 净化窗校正) 已创建 ==='
