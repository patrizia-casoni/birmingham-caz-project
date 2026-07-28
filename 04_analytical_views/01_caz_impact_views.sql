-- ============================================================================
-- VIEW: analytics_site_yearly_summary
-- DESCRIPTION: Consolidates regulatory annualised compliance means with 
--              robust empirical peak pollution values (P99). Percentile 
--              calculations are restricted to valid years (PASS) to prevent 
--              statistical distortion. Designed for Tableau reporting layers.
-- ============================================================================
DROP TABLE IF EXISTS analytics_site_yearly_summary;

CREATE TABLE analytics_site_yearly_summary AS
SELECT 
    fam.site_id,
    fam.site_name,
    fam.reading_year AS year,
    fam.final_annualised_mean AS annualised_mean,
    fam.laqm_annual_mean_status,
    -- Only calculate p99 for valid years where data capture is sufficient
    CASE 
        WHEN fam.laqm_annual_mean_status LIKE 'PASS%' THEN 
            (SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY r.no2) 
             FROM no2_readings r 
             WHERE r.site_id = fam.site_id 
               AND EXTRACT(YEAR FROM r.date_time) = fam.reading_year)
        ELSE NULL 
    END AS p99_no2_value
FROM 
    stg_final_annualised_means fam
ORDER BY 
    fam.site_id, 
    fam.reading_year;

--------------------------------------------------------------------------------
-- TITLE: Clean Air Zone (CAZ) Yearly Traffic Summary & Pollution Load Pipeline
-- PURPOSE: Aggregates yearly traffic volumes, calculates baseline absolute variances 
--          from 2022, and computes a Weighted Fleet Pollution Load Index to 
--          evaluate whether traffic growth offsets vehicle compliance gains.
-- TARGET: Output table optimized for direct ingestion into Tableau for dual-axis 
--          air quality (NO2) correlation analysis.
--------------------------------------------------------------------------------

DROP TABLE IF EXISTS analytics_yearly_traffic_summary;

CREATE TABLE analytics_yearly_traffic_summary AS
SELECT 
    EXTRACT(YEAR FROM date) AS year,
    SUM(compliant_vehicles) AS total_compliant_vehicles,
    SUM(noncompliant_vehicles) AS total_non_compliant_vehicles,
    SUM(total_vehicles) AS total_caz_vehicles,
    ROUND(
        (SUM(noncompliant_vehicles)::NUMERIC / NULLIF(SUM(total_vehicles), 0)::NUMERIC) * 100, 2
    ) AS overall_non_compliant_pct,
    
    -- Absolute change vs 2022 baseline (Polluting vehicles)
    SUM(noncompliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN noncompliant_vehicles END)) OVER () AS absolute_change_vs_2022_polluters,
    
    -- Absolute change vs 2022 baseline (Clean/Compliant vehicles)
    SUM(compliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN compliant_vehicles END)) OVER () AS absolute_change_vs_2022_clean,
    
    -- Weighted Pollution Load Index: 
    -- Note: Accounts for the reality that compliant vehicles are not zero-emission, 
    -- assigning a 25% (0.25) baseline pollution weighting relative to gross non-compliant polluters.
    SUM(noncompliant_vehicles) + (SUM(compliant_vehicles) * 0.25) AS estimated_total_pollution_load

FROM caz_traffic_compliance
GROUP BY EXTRACT(YEAR FROM date)
ORDER BY year ASC;


--------------------------------------------------------------------------------
-- Master Table Creation: Birmingham Clean Air Zone (CAZ) & Respiratory Health
-- Description: Integrates fiscal-year annualised NO2 air quality metrics with 
--              hospital admission rates by CAZ tier and fiscal year, and computes 
--              Year-over-Year (YoY) percentage changes.
--------------------------------------------------------------------------------

DROP TABLE IF EXISTS caz_respiratory_master;

CREATE TABLE caz_respiratory_master AS
WITH annual_air_quality AS (
    -- Step 1: Average out the annualised NO2 means per CAZ tier using monitoring sites metadata
    SELECT 
        m.caz_tier,
        f.fiscal_year,
        AVG(f.final_annualised_mean) AS annualised_no2_mean
    FROM stg_final_annualised_means_fy f
    JOIN monitoring_sites m ON f.site_id = m.site_id
    WHERE f.final_annualised_mean IS NOT NULL
      AND m.caz_tier IS NOT NULL
    GROUP BY m.caz_tier, f.fiscal_year
),
caz_tier_air_quality AS (
    -- Step 2: Aggregate air quality exposure up to the CAZ tier level per fiscal year
    SELECT 
        caz_tier,
        fiscal_year,
        ROUND(AVG(annualised_no2_mean)::numeric, 2) AS avg_caz_no2_exposure
    FROM annual_air_quality
    GROUP BY caz_tier, fiscal_year
),
aggregated_admissions AS (
    -- Step 3: Aggregate annual hospital admission rates per CAZ tier and fiscal year
    SELECT 
        w.caz_tier,
        h.fiscal_year,
        ROUND(AVG(CASE WHEN h.health_condition ILIKE '%copd%' THEN h.standardised_rate END)::numeric, 2) AS avg_copd_standardised_rate,
        ROUND(AVG(CASE WHEN h.health_condition ILIKE '%respiratory%' THEN h.standardised_rate END)::numeric, 2) AS avg_respiratory_standardised_rate,
        COUNT(DISTINCT w.area_code) AS ward_count
    FROM wards_metadata AS w
    JOIN birmingham_hospital_admissions AS h 
    ON w.area_code = h.area_code
    GROUP BY w.caz_tier, h.fiscal_year
),
combined_metrics AS (
    -- Step 4: Combine air quality exposure and hospital admissions by tier and fiscal year
    SELECT 
        COALESCE(a.caz_tier, h.caz_tier) AS caz_tier,
        COALESCE(a.fiscal_year, h.fiscal_year) AS fiscal_year,
        a.avg_caz_no2_exposure,
        h.avg_copd_standardised_rate,
        h.avg_respiratory_standardised_rate,
        h.ward_count
    FROM caz_tier_air_quality a
    FULL OUTER JOIN aggregated_admissions h 
        ON a.caz_tier = h.caz_tier AND a.fiscal_year = h.fiscal_year
)
-- Step 5: Apply window functions to calculate YoY percentage change per tier for both exposure and health outcomes
SELECT 
    caz_tier,
    fiscal_year,
    avg_caz_no2_exposure,
    ROUND(
        ((avg_caz_no2_exposure - LAG(avg_caz_no2_exposure) OVER (PARTITION BY caz_tier ORDER BY fiscal_year)) 
        / NULLIF(LAG(avg_caz_no2_exposure) OVER (PARTITION BY caz_tier ORDER BY fiscal_year), 0)) * 100, 
        2
    ) AS no2_yoy_pct_change,
    avg_copd_standardised_rate,
    ROUND(
        ((avg_copd_standardised_rate - LAG(avg_copd_standardised_rate) OVER (PARTITION BY caz_tier ORDER BY fiscal_year)) 
        / NULLIF(LAG(avg_copd_standardised_rate) OVER (PARTITION BY caz_tier ORDER BY fiscal_year), 0)) * 100, 
        2
    ) AS copd_yoy_pct_change,
    avg_respiratory_standardised_rate,
    ROUND(
        ((avg_respiratory_standardised_rate - LAG(avg_respiratory_standardised_rate) OVER (PARTITION BY caz_tier ORDER BY fiscal_year)) 
        / NULLIF(LAG(avg_respiratory_standardised_rate) OVER (PARTITION BY caz_tier ORDER BY fiscal_year), 0)) * 100, 
        2
    ) AS respiratory_yoy_pct_change,
    ward_count
FROM combined_metrics;