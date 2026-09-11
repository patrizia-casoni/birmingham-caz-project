/*
================================================================================
Title: Birmingham CAZ Study - NO2 Data Remediation & Annualisation Pipeline
Description: 
    This SQL script processes raw nitrogen dioxide (NO2) monitoring data for the 
    Birmingham Clean Air Zone (CAZ) study using three sequential staging tables:
        1. stg_reference_mapping: Spatial matching of target sites to valid background reference sites.
        2. stg_site_yearly_metrics: Monthly aggregation and LAQM data capture assessment.
        3. stg_final_annualised_means: Final dataset creation incorporating direct means and annualisation.

Technical Notes & Limitations:
    - Sanitisation: Filters out baseline calibration anomalies (no2 >= -1.0).
    - LAQM Compliance Thresholds:
        * >= 9 months: Direct mean accepted ('PASS (Use As-Is)').
        * 3-8 months: Annualised via reference site scaling factor (Target Mean * [Reference Full Year Mean / Reference Period Mean]).
        * < 3 months: Dropped from analysis due to insufficient statistical reliability.
    - Historical Data Constraint (2018–2019): 
        Annualisation for 2018 and 2019 was not possible because the primary continuous 
        reference site (Ladywood) only commenced operation in 2020, and secondary 
        reference sites (such as New Hall) lack sufficient data capture for those years. 
        Consequently, site/year combinations with insufficient data (3–8 valid months) 
        in 2018 and 2019 have been excluded from annualisation.
================================================================================
*/

-- ============================================================================
-- STAGE 1: Reference Site Mapping (Spatial Nearest-Neighbour Matching)
-- ============================================================================
DROP TABLE IF EXISTS stg_reference_mapping;

CREATE TABLE stg_reference_mapping AS
WITH monthly_agg AS (
    SELECT 
        site_id,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        COUNT(CASE WHEN no2 >= -1.0 THEN no2 END) AS valid_count,
        COUNT(*) AS total_count,
        AVG(CASE WHEN no2 >= -1.0 THEN no2 END) AS monthly_mean
    FROM no2_readings
    GROUP BY site_id, EXTRACT(YEAR FROM date_time), EXTRACT(MONTH FROM date_time)
),
site_yearly AS (
    SELECT 
        site_id,
        reading_year,
        SUM(CASE WHEN (valid_count::NUMERIC / NULLIF(total_count, 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END) AS valid_months_count
    FROM monthly_agg
    GROUP BY site_id, reading_year
),
target_years AS (
    SELECT site_id, reading_year 
    FROM site_yearly 
    WHERE valid_months_count BETWEEN 3 AND 8
)
SELECT DISTINCT ON (t.site_id, t.reading_year)
    t.site_id,
    t.reading_year,
    ref_meta.site_id AS assigned_reference_site_id
FROM target_years t
CROSS JOIN LATERAL (
    SELECT 
        m.site_id,
        SQRT(POWER(target_meta.longitude - ref_meta.longitude, 2) + 
             POWER(target_meta.latitude - ref_meta.latitude, 2)) AS distance
    FROM monthly_agg m
    JOIN monitoring_sites ref_meta ON m.site_id = ref_meta.site_id
    JOIN site_yearly ref_status ON m.site_id = ref_status.site_id AND m.reading_year = ref_status.reading_year
    JOIN monitoring_sites target_meta ON target_meta.site_id = t.site_id
    WHERE UPPER(ref_meta.site_type) = 'BACKGROUND'
      AND ref_status.valid_months_count >= 9
      AND m.reading_year = t.reading_year
      AND m.site_id <> t.site_id
    GROUP BY m.site_id, target_meta.longitude, target_meta.latitude, ref_meta.longitude, ref_meta.latitude
    HAVING SUM(CASE WHEN (m.valid_count::NUMERIC / NULLIF(m.total_count, 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END) >= 9
    ORDER BY distance ASC
    LIMIT 1
) ref_meta;


-- ============================================================================
-- STAGE 2: Site Yearly Metrics & LAQM Status Determination
-- ============================================================================
DROP TABLE IF EXISTS stg_site_yearly_metrics;

CREATE TABLE stg_site_yearly_metrics AS
WITH monthly_agg AS (
    SELECT 
        site_id,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        AVG(CASE WHEN no2 >= -1.0 THEN no2 END) AS monthly_mean,
        CASE WHEN (COUNT(CASE WHEN no2 >= -1.0 THEN no2 END)::NUMERIC / NULLIF(COUNT(*), 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END AS is_valid_month
    FROM no2_readings
    GROUP BY site_id, EXTRACT(YEAR FROM date_time), EXTRACT(MONTH FROM date_time)
)
SELECT 
    m.site_id,
    s.site_name,
    m.reading_year,
    COUNT(m.reading_month) AS total_monitored_months,
    SUM(m.is_valid_month) AS valid_months_count,
    AVG(m.monthly_mean) AS raw_direct_mean,
    CASE 
        WHEN SUM(m.is_valid_month) >= 9 THEN 'PASS (Use As-Is)'
        WHEN SUM(m.is_valid_month) BETWEEN 3 AND 8 THEN 'ACTION (Requires Annualisation)'
        ELSE 'ACTION (Exclude - Insufficient Data)'
    END AS laqm_annual_mean_status
FROM monthly_agg m
JOIN monitoring_sites s ON m.site_id = s.site_id
GROUP BY m.site_id, s.site_name, m.reading_year;


-- ============================================================================
-- STAGE 3: Final Annualised Means Calculation
-- ============================================================================
DROP TABLE IF EXISTS stg_final_annualised_means;

CREATE TABLE stg_final_annualised_means AS
WITH monthly_data AS (
    SELECT 
        site_id,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        AVG(CASE WHEN no2 >= -1.0 THEN no2 END) AS monthly_mean
    FROM no2_readings
    GROUP BY site_id, EXTRACT(YEAR FROM date_time), EXTRACT(MONTH FROM date_time)
),
ratios AS (
    SELECT 
        m.site_id AS target_site_id,
        m.reading_year,
        AVG(t_mo.monthly_mean) AS target_period_mean,
        AVG(ref_mo.monthly_mean) AS ref_period_mean
    FROM stg_site_yearly_metrics m
    JOIN stg_reference_mapping map ON m.site_id = map.site_id AND m.reading_year = map.reading_year
    JOIN monthly_data t_mo ON m.site_id = t_mo.site_id AND m.reading_year = t_mo.reading_year
    JOIN monthly_data ref_mo ON map.assigned_reference_site_id = ref_mo.site_id AND m.reading_year = ref_mo.reading_year AND t_mo.reading_month = ref_mo.reading_month
    WHERE t_mo.monthly_mean IS NOT NULL AND ref_mo.monthly_mean IS NOT NULL
    GROUP BY m.site_id, m.reading_year
),
full_ref_avgs AS (
    SELECT 
        map.site_id AS target_site_id,
        map.reading_year,
        AVG(ref_mo.monthly_mean) AS ref_full_year_mean
    FROM stg_reference_mapping map
    JOIN monthly_data ref_mo ON map.assigned_reference_site_id = ref_mo.site_id AND map.reading_year = ref_mo.reading_year
    GROUP BY map.site_id, map.reading_year
)
SELECT 
    m.site_id,
    m.site_name,
    m.reading_year,
    m.valid_months_count,
    m.laqm_annual_mean_status,
    map.assigned_reference_site_id,
    ROUND(
        (
            CASE 
                WHEN m.valid_months_count >= 9 THEN m.raw_direct_mean
                WHEN m.valid_months_count BETWEEN 3 AND 8 AND r.ref_period_mean > 0 THEN 
                    m.raw_direct_mean * (f.ref_full_year_mean / r.ref_period_mean)
                ELSE NULL 
            END
        )::numeric, 2
    ) AS final_annualised_mean
FROM stg_site_yearly_metrics m
LEFT JOIN stg_reference_mapping map ON m.site_id = map.site_id AND m.reading_year = map.reading_year
LEFT JOIN ratios r ON m.site_id = r.target_site_id AND m.reading_year = r.reading_year
LEFT JOIN full_ref_avgs f ON m.site_id = f.target_site_id AND m.reading_year = f.reading_year;


-- ============================================================================
-- TABLE: analytics_site_yearly_summary
-- DESCRIPTION: Consolidates regulatory annualised compliance means with 
--              robust empirical peak pollution values (P99.8). Percentile 
--              calculations are restricted to valid years (PASS) to prevent 
--              statistical distortion. Designed for Power BI reporting layers.
-- ============================================================================
DROP TABLE IF EXISTS analytics_site_yearly_summary;

CREATE TABLE analytics_site_yearly_summary AS

WITH cleaned_yearly_percentiles AS (
    -- Step 1: Clean raw data (-1.0 exclusion) and aggregate percentiles efficiently
    SELECT 
        site_id,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        PERCENTILE_CONT(0.998) WITHIN GROUP (ORDER BY no2) AS p998_no2_value
    FROM no2_readings
    WHERE no2 >= -1.0 
    GROUP BY site_id, EXTRACT(YEAR FROM date_time)
)

-- Step 2: Join safe percentiles to the finalized LAQM staging table
SELECT 
    fam.site_id,
    fam.site_name,
    fam.reading_year AS year,
    fam.final_annualised_mean AS annualised_mean,
    fam.laqm_annual_mean_status,
    
    -- Step 3: Enforce strict data governance (only valid years get a percentile)
    CASE 
        WHEN fam.laqm_annual_mean_status LIKE 'PASS%' THEN p.p998_no2_value
        ELSE NULL 
    END AS p998_no2_value

FROM stg_final_annualised_means fam
LEFT JOIN cleaned_yearly_percentiles p 
    ON fam.site_id = p.site_id 
    AND fam.reading_year = p.reading_year
ORDER BY 
    fam.site_id, 
    fam.reading_year;


--------------------------------------------------------------------------------
-- TITLE: Clean Air Zone (CAZ) Yearly Traffic Summary & Pollution Load Pipeline
-- PURPOSE: Aggregates yearly traffic volumes and computes a Vehicle-Specific 
--          Weighted Fleet NO2 Pollution Load Index. 
--
-- ARCHITECTURE NOTE FOR BI: 
--          While this script calculates pollution load statically for ad-hoc 
--          database querying, the Power BI dashboard does NOT use this table. 
--          Instead, Power BI connects to the granular 'vw_powerbi_traffic' view 
--          and calculates pollution load dynamically via DAX. This enables 
--          seamless cross-filtering and interactive drill-downs in the UI.
--------------------------------------------------------------------------------
-- INTERVIEW TALKING POINTS & METHODOLOGY:
--
-- 1. BASE DATA (IMPUTED TOTALS):
--    This table builds on top of 'analytics_imputed_traffic_monthly', meaning 
--    'Unrecognised' camera misreads have already been mathematically distributed 
--    across known vehicle categories based on monthly probability shares.
--
-- 2. METRIC ALIGNMENT (NO2 vs. NOx):
--    CAZ monitoring stations measure ambient NO2 (Nitrogen Dioxide). Our weights 
--    specifically reflect real-world urban NO2 tailpipe emissions and primary NO2 
--    formation during stop-and-go driving conditions, NOT laboratory NOx.
--
-- 3. DERIVATION OF PROXY WEIGHTS:
--    * Non-Compliant Vehicles: 1.0 (Baseline heavy polluters)
--    * Compliant Cars: 0.327 (Mix of EV, Petrol, and Euro 6 Diesel)
--    * Compliant LGVs: 0.725 (Overwhelmingly Euro 6 Diesel, high primary NO2)
--    * Compliant HGVs/Buses: 0.15 (Highly effective SCR systems)
--    * Compliant Mini-Buses: 0.65 (Van chassis, tracks close to LGVs)
--    * Compliant Exempt: 0.60 (Heavy-duty diesel/van chassis)
--    * Motorcycles & Other: 0.10 (Small engine displacement)
--------------------------------------------------------------------------------

DROP TABLE IF EXISTS analytics_yearly_traffic_summary;

CREATE TABLE analytics_yearly_traffic_summary AS
SELECT 
    EXTRACT(YEAR FROM date) AS year,
    vehicle_type,  
    SUM(compliant_vehicles) AS total_compliant_vehicles,
    SUM(noncompliant_vehicles) AS total_non_compliant_vehicles,
    SUM(total_vehicles) AS total_caz_vehicles,
    
    ROUND(
        (SUM(noncompliant_vehicles)::NUMERIC / NULLIF(SUM(total_vehicles), 0)::NUMERIC) * 100, 2
    ) AS overall_non_compliant_pct,
    
    -- Absolute variance vs. 2022 baseline (Non-Compliant)
    SUM(noncompliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN noncompliant_vehicles END)) OVER () AS absolute_change_vs_2022_polluters,
    
    -- Absolute variance vs. 2022 baseline (Compliant)
    SUM(compliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN compliant_vehicles END)) OVER () AS absolute_change_vs_2022_clean,
    
    -- Data-Driven Vehicle-Specific NO2 Pollution Load Index
    SUM(
        CASE 
            WHEN vehicle_type = 'Car' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.327)
            WHEN vehicle_type = 'LGV' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.725)
            WHEN vehicle_type = 'HGV' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.15)
            WHEN vehicle_type = 'Bus/Coach' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.15)
            WHEN vehicle_type = 'Mini-Bus' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.65)
            WHEN vehicle_type = 'Exempt' THEN (COALESCE(noncompliant_vehicles, 0) * 1.0) + (COALESCE(compliant_vehicles, 0) * 0.60) 
            WHEN vehicle_type = 'Motorcycles and Other' THEN (total_vehicles * 0.10) 
            ELSE (total_vehicles * 0.50) 
        END
    ) AS estimated_total_pollution_load

FROM analytics_imputed_traffic_monthly
GROUP BY EXTRACT(YEAR FROM date), vehicle_type
ORDER BY year ASC, vehicle_type ASC;


--------------------------------------------------------------------------------
-- TITLE: Staging - Impute Unrecognised Vehicles (Physical Table)
-- PURPOSE: Dynamically splits monthly 'Unrecognised' vehicle counts across ALL 
--          vehicle types based on monthly traffic shares. 
--          Chargeable vehicles are sub-split into compliant/non-compliant counts.
--          'Motorcycles and Other' receive their share of total vehicles, but 
--          their compliance fields remain NULL per the schema constraint.
-- ARCHITECTURE: Medallion (Silver Layer)
--------------------------------------------------------------------------------

DROP TABLE IF EXISTS analytics_imputed_traffic_monthly;

CREATE TABLE analytics_imputed_traffic_monthly AS

WITH 
-- Step 1: Isolate ALL recognized traffic (Cars, LGVs, AND Motorcycles)
recognized_totals AS (
    SELECT 
        date,
        vehicle_type,
        compliant_vehicles,
        noncompliant_vehicles,
        total_vehicles
    FROM caz_traffic_compliance
    WHERE vehicle_type != 'Unrecognised'
),

-- Step 2: Calculate total recognized volume per month to determine distribution base
monthly_universe AS (
    SELECT 
        date,
        SUM(total_vehicles) AS total_recognized_volume
    FROM recognized_totals
    GROUP BY date
),

-- Step 3: Calculate each category's share of ALL traffic
category_monthly_shares AS (
    SELECT 
        r.date,
        r.vehicle_type,
        r.compliant_vehicles,
        r.noncompliant_vehicles,
        r.total_vehicles,
        -- Share of this vehicle type relative to all known traffic that month
        r.total_vehicles::NUMERIC / NULLIF(u.total_recognized_volume, 0) AS category_share
    FROM recognized_totals r
    JOIN monthly_universe u ON r.date = u.date
),

-- Step 4: Isolate the monthly 'Unrecognised' pool to be distributed
unrecognised_pool AS (
    SELECT 
        date,
        total_vehicles AS unrecognised_total_vehicles
    FROM caz_traffic_compliance
    WHERE vehicle_type = 'Unrecognised'
),

-- Step 5: Proportionally distribute unrecognised volume and conditionally apply splits
imputed_unrecognised AS (
    SELECT 
        s.date,
        s.vehicle_type,
        -- Proportioned total volume from the unrecognised pool
        ROUND(s.category_share * up.unrecognised_total_vehicles)::INTEGER AS imputed_total_vehicles,
        
        -- Conditionally apply compliance rate ONLY if the vehicle type has compliance data
        CASE 
            WHEN s.compliant_vehicles IS NOT NULL THEN 
                ROUND((s.category_share * up.unrecognised_total_vehicles) * 
                (s.compliant_vehicles::NUMERIC / s.total_vehicles))::INTEGER
            ELSE NULL 
        END AS imputed_compliant,
        
        CASE 
            WHEN s.noncompliant_vehicles IS NOT NULL THEN 
                ROUND((s.category_share * up.unrecognised_total_vehicles) * 
                (s.noncompliant_vehicles::NUMERIC / s.total_vehicles))::INTEGER
            ELSE NULL 
        END AS imputed_noncompliant

    FROM category_monthly_shares s
    JOIN unrecognised_pool up ON s.date = up.date
)

-- Step 6: Combine ALL original recognized traffic with the imputed traffic
SELECT 
    date,
    vehicle_type,
    compliant_vehicles,
    noncompliant_vehicles,
    total_vehicles,
    'Recognised Baseline' AS data_source_type
FROM recognized_totals

UNION ALL

SELECT 
    date,
    vehicle_type,
    imputed_compliant AS compliant_vehicles,
    imputed_noncompliant AS noncompliant_vehicles,
    imputed_total_vehicles AS total_vehicles,
    'Imputed Unrecognised' AS data_source_type
FROM imputed_unrecognised
ORDER BY date ASC, vehicle_type ASC, data_source_type ASC;










--------------------------------------------------------------------------------
-- STAGE 1: Reference Site Mapping (Fiscal Year Basis)
-- Description: Maps target sites requiring annualisation to nearby background 
--              reference sites using UK NHS fiscal years (April–March).
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_reference_mapping_fy;

CREATE TABLE stg_reference_mapping_fy AS
WITH cleaned_readings AS (
    SELECT 
        site_id,
        date_time,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN EXTRACT(MONTH FROM date_time) >= 4 
            THEN EXTRACT(YEAR FROM date_time)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) + 1 - 2000)::text, 2, '0')
            ELSE (EXTRACT(YEAR FROM date_time) - 1)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) - 2000)::text, 2, '0')
        END AS fiscal_year,
        CASE WHEN no2 < -1.0 THEN NULL ELSE no2 END AS no2_diagnosed
    FROM no2_readings
),
monthly_agg AS (
    SELECT 
        site_id,
        fiscal_year,
        reading_month,
        COUNT(no2_diagnosed) AS valid_count,
        COUNT(*) AS total_count,
        AVG(no2_diagnosed) AS monthly_mean
    FROM cleaned_readings
    GROUP BY site_id, fiscal_year, reading_month
),
site_fiscal_yearly AS (
    SELECT 
        site_id,
        fiscal_year,
        SUM(CASE WHEN (valid_count::NUMERIC / NULLIF(total_count, 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END) AS valid_months_count
    FROM monthly_agg
    GROUP BY site_id, fiscal_year
),
target_fiscal_years AS (
    SELECT site_id, fiscal_year 
    FROM site_fiscal_yearly 
    WHERE valid_months_count BETWEEN 3 AND 8
)
SELECT DISTINCT ON (t.site_id, t.fiscal_year)
    t.site_id,
    t.fiscal_year,
    ref_meta.site_id AS assigned_reference_site_id
FROM target_fiscal_years t
CROSS JOIN LATERAL (
    SELECT 
        m.site_id,
        SQRT(POWER(target_meta.longitude - ref_meta.longitude, 2) + 
             POWER(target_meta.latitude - ref_meta.latitude, 2)) AS distance
    FROM monthly_agg m
    JOIN monitoring_sites ref_meta ON m.site_id = ref_meta.site_id
    JOIN site_fiscal_yearly ref_status ON m.site_id = ref_status.site_id AND m.fiscal_year = ref_status.fiscal_year
    JOIN monitoring_sites target_meta ON target_meta.site_id = t.site_id
    WHERE UPPER(ref_meta.site_type) = 'BACKGROUND'
      AND ref_status.valid_months_count >= 9
      AND m.fiscal_year = t.fiscal_year
      AND m.site_id <> t.site_id
    GROUP BY m.site_id, target_meta.longitude, target_meta.latitude, ref_meta.longitude, ref_meta.latitude
    HAVING SUM(CASE WHEN (m.valid_count::NUMERIC / NULLIF(m.total_count, 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END) >= 9
    ORDER BY distance ASC
    LIMIT 1
) ref_meta;


--------------------------------------------------------------------------------
-- STAGE 2: Site Fiscal-Yearly Metrics & LAQM Status Determination
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_site_yearly_metrics_fy;

CREATE TABLE stg_site_yearly_metrics_fy AS
WITH cleaned_readings AS (
    SELECT 
        site_id,
        date_time,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN EXTRACT(MONTH FROM date_time) >= 4 
            THEN EXTRACT(YEAR FROM date_time)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) + 1 - 2000)::text, 2, '0')
            ELSE (EXTRACT(YEAR FROM date_time) - 1)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) - 2000)::text, 2, '0')
        END AS fiscal_year,
        CASE WHEN no2 < -1.0 THEN NULL ELSE no2 END AS no2_diagnosed
    FROM no2_readings
),
monthly_agg AS (
    SELECT 
        site_id,
        fiscal_year,
        reading_month,
        AVG(no2_diagnosed) AS monthly_mean,
        CASE WHEN (COUNT(no2_diagnosed)::NUMERIC / NULLIF(COUNT(*), 0)::NUMERIC) >= 0.75 THEN 1 ELSE 0 END AS is_valid_month
    FROM cleaned_readings
    GROUP BY site_id, fiscal_year, reading_month
)
SELECT 
    m.site_id,
    s.site_name,
    m.fiscal_year,
    COUNT(m.reading_month) AS total_monitored_months,
    SUM(m.is_valid_month) AS valid_months_count,
    AVG(m.monthly_mean) AS raw_direct_mean,
    CASE 
        WHEN SUM(m.is_valid_month) >= 9 THEN 'PASS (Use As-Is)'
        WHEN SUM(m.is_valid_month) BETWEEN 3 AND 8 THEN 'ACTION (Requires Annualisation)'
        ELSE 'ACTION (Exclude - Insufficient Data)'
    END AS laqm_annual_mean_status
FROM monthly_agg m
JOIN monitoring_sites s ON m.site_id = s.site_id
GROUP BY m.site_id, s.site_name, m.fiscal_year;


--------------------------------------------------------------------------------
-- STAGE 3: Final Annualised Means Calculation (Fiscal Year Basis)
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_final_annualised_means_fy;

CREATE TABLE stg_final_annualised_means_fy AS
WITH cleaned_readings AS (
    SELECT 
        site_id,
        date_time,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN EXTRACT(MONTH FROM date_time) >= 4 
            THEN EXTRACT(YEAR FROM date_time)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) + 1 - 2000)::text, 2, '0')
            ELSE (EXTRACT(YEAR FROM date_time) - 1)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) - 2000)::text, 2, '0')
        END AS fiscal_year,
        CASE WHEN no2 < -1.0 THEN NULL ELSE no2 END AS no2_diagnosed
    FROM no2_readings
),
monthly_data AS (
    SELECT 
        site_id,
        fiscal_year,
        reading_month,
        AVG(no2_diagnosed) AS monthly_mean
    FROM cleaned_readings
    GROUP BY site_id, fiscal_year, reading_month
),
ratios AS (
    SELECT 
        m.site_id AS target_site_id,
        m.fiscal_year,
        AVG(t_mo.monthly_mean) AS target_period_mean,
        AVG(ref_mo.monthly_mean) AS ref_period_mean
    FROM stg_site_yearly_metrics_fy m
    JOIN stg_reference_mapping_fy map ON m.site_id = map.site_id AND m.fiscal_year = map.fiscal_year
    JOIN monthly_data t_mo ON m.site_id = t_mo.site_id AND m.fiscal_year = t_mo.fiscal_year
    JOIN monthly_data ref_mo ON map.assigned_reference_site_id = ref_mo.site_id AND map.fiscal_year = ref_mo.fiscal_year AND t_mo.reading_month = ref_mo.reading_month
    WHERE t_mo.monthly_mean IS NOT NULL AND ref_mo.monthly_mean IS NOT NULL
    GROUP BY m.site_id, m.fiscal_year
),
full_ref_avgs AS (
    SELECT 
        map.site_id AS target_site_id,
        map.fiscal_year,
        AVG(ref_mo.monthly_mean) AS ref_full_year_mean
    FROM stg_reference_mapping_fy map
    JOIN monthly_data ref_mo ON map.assigned_reference_site_id = ref_mo.site_id AND map.fiscal_year = ref_mo.fiscal_year
    GROUP BY map.site_id, map.fiscal_year
)
SELECT 
    m.site_id,
    m.site_name,
    m.fiscal_year,
    m.valid_months_count,
    m.laqm_annual_mean_status,
    map.assigned_reference_site_id,
    ROUND(
        (
            CASE 
                WHEN m.valid_months_count >= 9 THEN m.raw_direct_mean
                WHEN m.valid_months_count BETWEEN 3 AND 8 AND r.ref_period_mean > 0 THEN 
                    m.raw_direct_mean * (f.ref_full_year_mean / r.ref_period_mean)
                ELSE NULL 
            END
        )::numeric, 2
    ) AS final_annualised_mean
FROM stg_site_yearly_metrics_fy m
LEFT JOIN stg_reference_mapping_fy map ON m.site_id = map.site_id AND m.fiscal_year = map.fiscal_year
LEFT JOIN ratios r ON m.site_id = r.target_site_id AND m.fiscal_year = r.fiscal_year
LEFT JOIN full_ref_avgs f ON m.site_id = f.target_site_id AND m.fiscal_year = f.fiscal_year;

-- ============================================================================
-- TABLE: analytics_top19_hourly_peaks
-- DESCRIPTION: Isolates the exact 19 highest hourly NO2 readings per site/year.
--              Since the 19th highest hour defines the 99.8th percentile 
--              threshold, this table provides exact drill-through transparency 
--              for executives. Restricted to LAQM-valid years.
-- ============================================================================
DROP TABLE IF EXISTS analytics_top19_hourly_peaks;

CREATE TABLE analytics_top19_hourly_peaks AS

WITH valid_site_years AS (
    -- Step 1: Identify eligible sites/years based on strict 9-month data capture
    SELECT 
        site_id, 
        reading_year, 
        site_name
    FROM 
        stg_final_annualised_means
    WHERE 
        laqm_annual_mean_status LIKE 'PASS%'
),

ranked_hourly_readings AS (
    -- Step 2: Join raw data to valid years and rank the highest NO2 hours
    SELECT 
        r.site_id,
        v.site_name,
        r.date_time AS exact_timestamp,
        EXTRACT(YEAR FROM r.date_time) AS year,
        EXTRACT(MONTH FROM r.date_time) AS month,
        EXTRACT(DAY FROM r.date_time) AS day,
        EXTRACT(HOUR FROM r.date_time) AS hour,
        r.no2 AS hourly_no2_value,
        
        -- Rank readings highest to lowest, resetting for each site and year
        ROW_NUMBER() OVER (
            PARTITION BY r.site_id, EXTRACT(YEAR FROM r.date_time) 
            ORDER BY r.no2 DESC
        ) AS peak_rank
        
    FROM 
        no2_readings r
    INNER JOIN 
        valid_site_years v 
        ON r.site_id = v.site_id 
        AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
    WHERE 
        r.no2 >= -1.0 -- Clean out equipment error codes
)

-- Step 3: Extract only the top 19 hours
SELECT 
    site_id,
    site_name,
    year,
    month,
    day,
    hour,
    exact_timestamp,
    hourly_no2_value,
    peak_rank
FROM 
    ranked_hourly_readings
WHERE 
    peak_rank <= 19
ORDER BY 
    site_id, 
    year, 
    peak_rank;

-- ============================================================================
-- INDEXES FOR POWER BI PERFORMANCE
-- ============================================================================
CREATE INDEX idx_top19_site_year 
    ON analytics_top19_hourly_peaks(site_id, year);



-- ============================================================================
-- TITLE: Analytics Site Hourly & Weekly Profiles
-- DESCRIPTION: Aggregates NO2 readings by site, year, month, day of week, 
--              and hour to support granular diurnal and weekly diagnostics.
--              Note: This replaces the legacy monthly profiles table.
-- ============================================================================

DROP TABLE IF EXISTS analytics_site_hourly_weekly_profiles;

CREATE TABLE analytics_site_hourly_weekly_profiles AS

WITH valid_site_years AS (
    SELECT 
        site_id, 
        reading_year, 
        site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month,
    
    -- Extract Day of Week (1 = Monday through 7 = Sunday in PostgreSQL ISODOW)
    EXTRACT(ISODOW FROM r.date_time) AS day_of_week_num,
    
    -- Extract Day Name (FM removes trailing blank spaces from PostgreSQL default)
    TO_CHAR(r.date_time, 'FMDay') AS day_of_week_name,
    
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
    
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(ISODOW FROM r.date_time),
    TO_CHAR(r.date_time, 'FMDay'),
    EXTRACT(HOUR FROM r.date_time);

-- ============================================================================
-- INDEX FOR POWER BI PERFORMANCE
-- ============================================================================
CREATE INDEX idx_hourly_weekly_profile_filters 
    ON analytics_site_hourly_weekly_profiles(site_id, year, month, day_of_week_num);



