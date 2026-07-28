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