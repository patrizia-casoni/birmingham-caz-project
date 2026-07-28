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