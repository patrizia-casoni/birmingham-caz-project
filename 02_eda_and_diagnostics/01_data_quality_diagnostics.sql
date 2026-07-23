/*******************************************************************************
  PHASE 1: DATA QUALITY DIAGNOSTICS
  Project: Birmingham CAZ Data Engineering Pipeline
  
  Contains comprehensive diagnostic assertions across all project tables:
    - Section 1: Monitoring Sites Metadata (monitoring_sites)
    - Section 2: NO2 Time-Series Readings (no2_readings)
    - Section 3: 
*******************************************************************************/


-- =============================================================================
-- SECTION 1: MONITORING SITES METADATA TABLE (monitoring_sites)
-- =============================================================================

-- =============================================================================
-- 1.1 Identifier Integrity Checks
-- =============================================================================

-- NOTE: site_id primary key uniqueness is enforced at schema creation (DDL).
-- Primary key diagnostic skipped as constraint active.


-- 1.1b. Business Logic Audit: Descriptive Identifier Uniqueness
-- Checks if multiple distinct site_ids were assigned to the same site_name
SELECT 
    site_name, 
    COUNT(DISTINCT site_id) AS distinct_site_ids,
    COUNT(*) AS total_occurrences
FROM monitoring_sites
GROUP BY site_name
HAVING COUNT(*) > 1;


-- -----------------------------------------------------------------------------
-- 1.2 Completeness Audit Across All Columns
-- -----------------------------------------------------------------------------
SELECT 
    COUNT(*) AS total_records,
    COUNT(*) - COUNT(site_id)     AS site_id_nulls,
    COUNT(*) - COUNT(site_name)   AS site_name_nulls,
    COUNT(*) - COUNT(site_type)   AS site_type_nulls,
    COUNT(*) - COUNT(caz_zone)    AS caz_zone_nulls,
    COUNT(*) - COUNT(latitude)    AS latitude_nulls,
    COUNT(*) - COUNT(longitude)   AS longitude_nulls,
    COUNT(*) - COUNT(data_source) AS data_source_nulls,
    COUNT(*) - COUNT(start_date)  AS start_date_nulls,
    COUNT(*) - COUNT(end_date)    AS end_date_nulls
FROM monitoring_sites;


-- -----------------------------------------------------------------------------
-- 1.3 Categorical Variables Distributions
-- -----------------------------------------------------------------------------
SELECT 
    'site_type' AS column_name, 
    site_type AS category_value, 
    COUNT(*) AS site_count
FROM monitoring_sites 
GROUP BY site_type

UNION ALL

SELECT 
    'caz_zone', 
    caz_zone, 
    COUNT(*) 
FROM monitoring_sites 
GROUP BY caz_zone

UNION ALL

SELECT 
    'data_source', 
    data_source, 
    COUNT(*) 
FROM monitoring_sites 
GROUP BY data_source

ORDER BY column_name, category_value;


-- -----------------------------------------------------------------------------
-- 1.4 Spatial Boundary Assertion
-- Checks for out-of-bounds locations.
-- Target Bounding Box (Birmingham Metropolitan Area):
--   Latitude:  52.30 to 52.60
--   Longitude: -2.05 to -1.70
-- -----------------------------------------------------------------------------
SELECT 
    site_id, 
    site_name, 
    latitude, 
    longitude,
    CASE 
        WHEN latitude NOT BETWEEN 52.30 AND 52.60 THEN 'Latitude Out of Bounds'
        WHEN longitude NOT BETWEEN -2.05 AND -1.70 THEN 'Longitude Out of Bounds'
        ELSE 'Within Birmingham Metro Area' 
    END AS spatial_flag
FROM monitoring_sites
WHERE latitude NOT BETWEEN 52.30 AND 52.60
   OR longitude NOT BETWEEN -2.05 AND -1.70;


-- -----------------------------------------------------------------------------
-- 1.5 Temporal Boundaries & Date Logic Sanity Check
-- -----------------------------------------------------------------------------
SELECT 
    MIN(start_date) AS earliest_site_start,
    MAX(start_date) AS latest_site_start,
    MIN(end_date)   AS earliest_site_end,
    MAX(end_date)   AS latest_site_end,
    -- Assertion: Count instances where end date precedes start date (Should return 0)
    COUNT(CASE WHEN end_date < start_date THEN 1 END) AS invalid_date_logic_count
FROM monitoring_sites;

-- 1.5b. Diagnostic Drill-Down: Identify decommissioned site(s)
SELECT 
    site_id,
    site_name,
    site_type,
    caz_zone,
    start_date,
    end_date
FROM monitoring_sites
WHERE end_date IS NOT NULL;

/*******************************************************************************
  SECTION 2: NO2 TIME-SERIES READINGS DIAGNOSTICS (no2_readings)
  Schema: (site_id, date_time, no2)
  Assumptions: FK and Composite PK constraints enforced at database layer.
*******************************************************************************/

-- -----------------------------------------------------------------------------
-- 1B.1 Column-Level Completeness Audit
-- Quantifies total record volume and NULL counts across all three columns.
-- -----------------------------------------------------------------------------

SELECT
    COUNT(*) AS total_records,
    COUNT(*) - COUNT(site_id)   AS site_id_nulls,
    COUNT(*) - COUNT(date_time) AS date_time_nulls,
    COUNT(*) - COUNT(no2)       AS no2_nulls,
    ROUND(((COUNT(*) - COUNT(no2))::numeric / COUNT(*)) * 100, 2) AS no2_nulls_percentage
FROM no2_readings;

-- -----------------------------------------------------------------------------
-- 1B.2 Temporal Horizon & Clock Sanity Check
-- Asserts earliest and latest timestamps while flagging invalid future dates.
-- -----------------------------------------------------------------------------
SELECT 
    MIN(date_time) AS earliest_reading,
    MAX(date_time) AS latest_reading,
    COUNT(CASE WHEN date_time > CURRENT_TIMESTAMP THEN 1 END) AS future_readings_count
FROM no2_readings;


-- -----------------------------------------------------------------------------
-- 1B.3 Statistical Distribution & Physical Boundary Assertions (by Site)
-- Calculates baseline metrics per site and flags sensor hardware anomalies:
--   - Negative values (zero-point drift / calibration errors)
--   - Zero values (frozen/stuck sensor output)
--   - Extreme spikes > 500 µg/m³ (physically implausible electrical noise)
-- -----------------------------------------------------------------------------
SELECT 
    site_id,
    site_name,
    COUNT(*) AS total_readings,
    MIN(no2) AS min_no2,
    MAX(no2) AS max_no2,
    ROUND(AVG(no2)::numeric, 2) AS avg_no2,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY no2) AS median_no2,
    -- Physical anomaly counts
    COUNT(CASE WHEN no2 < 0 THEN 1 END)   AS negative_values,
    COUNT(CASE WHEN no2 = 0 THEN 1 END)   AS zero_values,
    COUNT(CASE WHEN no2 > 500 THEN 1 END) AS extreme_spikes
FROM no2_readings
GROUP BY site_id
ORDER BY site_id;


-- -----------------------------------------------------------------------------
-- 1B.4 Negative Value Severity Breakdown
-- Differentiates acceptable baseline zero-drift (-1.0 to 0 µg/m³) from
-- severe hardware malfunctions (< -1.0 µg/m³).
-- -----------------------------------------------------------------------------
SELECT
    site_id,
    site_name,
    COUNT(*) AS total_site_readings,
    
    -- Negative breakdown
    COUNT(CASE WHEN no2 < 0 THEN 1 END) AS total_negative_readings,
    
    COUNT(CASE WHEN no2 BETWEEN -1.0 AND 0 THEN 1 END) AS minor_drift_count,
    ROUND(
        (COUNT(CASE WHEN no2 BETWEEN -1.0 AND 0 THEN 1 END)::numeric / COUNT(*)) * 100, 
        4
    ) AS minor_drift_pct_of_site_total,
    
    COUNT(CASE WHEN no2 < -1.0 THEN 1 END) AS severe_anomaly_count,
    ROUND(
        (COUNT(CASE WHEN no2 < -1.0 THEN 1 END)::numeric / COUNT(*)) * 100, 
        4
    ) AS severe_anomaly_pct_of_site_total,
    
    MIN(no2) AS worst_negative_reading
FROM no2_readings AS r
INNER JOIN monitoring_sites AS s
    USING (site_id)
GROUP BY site_id, site_name
ORDER BY site_id, site_name;

-- =============================================================================
-- 2.2 NO2 Data Capture & LAQM Compliance Assessment
-- Purpose: 
--   1. Replaces severe negative anomalies (< -1.0 ug/m3) with NULLs (retains drift 0 to -1.0).
--   2. Calculates monthly data capture percentages per site.
--   3. Determines valid months per year based on DEFRA 75% threshold.
--   4. Flags annual compliance status (PASS, ANNUALISATION REQUIRED, or EXCLUDE).
-- =============================================================================

WITH cleaned_readings AS (
    -- Step 1: Nullify severe anomalies dynamically without altering base table
    SELECT 
        site_id,
        date_time,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN no2 < -1.0 THEN NULL 
            ELSE no2 
        END AS no2_diagnosed
    FROM no2_readings
),

monthly_completeness AS (
    -- Step 2: Calculate data capture percentage for every site and month
    SELECT 
        site_id,
        reading_year,
        reading_month,
        COUNT(*) AS total_expected_slots,
        COUNT(no2_diagnosed) AS valid_readings_count,
        ROUND(
            (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) * 100, 
            2
        ) AS monthly_data_capture_pct,
        -- DEFRA standard: Month passes if it achieves >= 75% valid data capture
        CASE 
            WHEN (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) >= 0.75 THEN 1
            ELSE 0 
        END AS is_valid_month
    FROM cleaned_readings
    GROUP BY site_id, reading_year, reading_month
),

annual_laqm_assessment AS (
    -- Step 3: Aggregate valid months per year and assign LAQM status
    SELECT 
        site_id,
        reading_year,
        COUNT(reading_month) AS total_monitored_months,
        SUM(is_valid_month) AS valid_months_count,
        ROUND(AVG(monthly_data_capture_pct), 2) AS yearly_avg_monthly_capture_pct,
        CASE 
            WHEN SUM(is_valid_month) >= 9 
                THEN 'PASS (Use As-Is)'
            WHEN SUM(is_valid_month) BETWEEN 3 AND 8 
                THEN 'ACTION (Requires Annualisation)'
            ELSE 'ACTION (Exclude - Insufficient Data)'
        END AS laqm_action_required
    FROM monthly_completeness
    GROUP BY site_id, reading_year
)

-- Step 4: Final output combining annual compliance status with site metadata
SELECT 
    a.site_id,
    a.reading_year,
    a.total_monitored_months,
    a.valid_months_count,
    a.yearly_avg_monthly_capture_pct,
    a.laqm_action_required
FROM annual_laqm_assessment a
ORDER BY a.site_id, a.reading_year;

-- =============================================================================
-- 2.3 Traffic Data Quality & Statistical Profiling Diagnostic
-- Table: caz_traffic_compliance
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CHECK 1: Missingness & Logic Anomalies (Column-by-Column)
-- -----------------------------------------------------------------------------
SELECT 
    COUNT(*) AS total_rows,
    
    -- Missingness (Compliant & Non-Compliant tied by DDL constraint)
    COUNT(CASE WHEN compliant_vehicles IS NULL THEN 1 END) AS compliance_nulls,
    ROUND(
        100.0 * COUNT(CASE WHEN compliant_vehicles IS NULL THEN 1 END) / COUNT(*), 
        2
    ) AS compliance_nulls_pct,
    
    -- Negative Values Count (per column)
    COUNT(CASE WHEN compliant_vehicles < 0 THEN 1 END) AS negative_compliant_count,
    COUNT(CASE WHEN noncompliant_vehicles < 0 THEN 1 END) AS negative_noncompliant_count,
    COUNT(CASE WHEN total_vehicles < 0 THEN 1 END) AS negative_total_count,
    
    -- Zero Traffic Count (per column)
    COUNT(CASE WHEN compliant_vehicles = 0 THEN 1 END) AS zero_compliant_count,
    COUNT(CASE WHEN noncompliant_vehicles = 0 THEN 1 END) AS zero_noncompliant_count,
    COUNT(CASE WHEN total_vehicles = 0 THEN 1 END) AS zero_total_count,
    
    -- Categorical Integrity
    COUNT(DISTINCT vehicle_type) AS distinct_vehicle_types

FROM caz_traffic_compliance;

