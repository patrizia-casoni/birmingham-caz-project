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

