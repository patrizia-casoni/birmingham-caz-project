/*******************************************************************************
  PHASE 2: DATA QUALITY DIAGNOSTICS
  Project: Birmingham CAZ Data Engineering Pipeline
  
  Contains comprehensive diagnostic assertions across all project tables, 
  structured to mirror the thematic flow of the Power BI dashboard.
*******************************************************************************/

/* ==============================================================================
   PART 1: SPATIAL ARCHITECTURE & METADATA (Monitoring Sites, Wards, Polygons)
============================================================================== */

-- 1.1 Monitoring Sites: Identifier Integrity (Business Logic Audit)
SELECT 
    site_name, 
    COUNT(DISTINCT site_id) AS distinct_site_ids,
    COUNT(*) AS total_occurrences
FROM monitoring_sites
GROUP BY 
    site_name
HAVING COUNT(*) > 1;

-- 1.2 Monitoring Sites: Completeness Audit Across All Columns
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

-- 1.3 Monitoring Sites: Categorical Variables Distributions
SELECT 
    'site_type' AS column_name, 
    site_type AS category_value, 
    COUNT(*) AS site_count
FROM monitoring_sites 
GROUP BY 
    site_type

UNION ALL

SELECT 
    'caz_zone', 
    caz_zone, 
    COUNT(*) 
FROM monitoring_sites 
GROUP BY 
    caz_zone

UNION ALL

SELECT 
    'data_source', 
    data_source, 
    COUNT(*) 
FROM monitoring_sites 
GROUP BY 
    data_source
ORDER BY 
    column_name, 
    category_value;

-- 1.4 Monitoring Sites: Spatial Boundary Assertion (Birmingham Metro Area)
SELECT 
    site_id, 
    site_name, 
    latitude, 
    longitude,
    CASE 
        WHEN latitude NOT BETWEEN 52.30 AND 52.60 
            THEN 'Latitude Out of Bounds'
        WHEN longitude NOT BETWEEN -2.05 AND -1.70 
            THEN 'Longitude Out of Bounds'
        ELSE 'Within Birmingham Metro Area' 
    END AS spatial_flag
FROM monitoring_sites
WHERE latitude NOT BETWEEN 52.30 AND 52.60 
   OR longitude NOT BETWEEN -2.05 AND -1.70;

-- 1.5 Monitoring Sites: Temporal Boundaries & Decommissioned Sites
SELECT 
    MIN(start_date) AS earliest_site_start, 
    MAX(start_date) AS latest_site_start,
    MIN(end_date)   AS earliest_site_end, 
    MAX(end_date)   AS latest_site_end,
    COUNT(
        CASE 
            WHEN end_date < start_date THEN 1 
        END
    ) AS invalid_date_logic_count
FROM monitoring_sites;

SELECT 
    site_id, 
    site_name, 
    site_type, 
    caz_zone, 
    start_date, 
    end_date
FROM monitoring_sites 
WHERE end_date IS NOT NULL;

-- 1.6 Wards Metadata: Total Ward Count Integrity (Expecting 69)
SELECT 
    COUNT(*) AS total_wards_logged,
    COUNT(DISTINCT area_code) AS unique_area_codes,
    CASE 
        WHEN COUNT(*) = 69 AND COUNT(DISTINCT area_code) = 69 
            THEN 'PASS: All 69 Unique Wards Accounted For'
        ELSE 'FAIL: Incorrect Ward Count or Duplicate Area Codes'
    END AS count_check
FROM wards_metadata;

-- 1.7 Wards Metadata: Area Name Uniqueness & Whitespace Hygiene
SELECT 
    COUNT(area_name) AS total_names,
    COUNT(DISTINCT area_name) AS unique_names,
    COUNT(
        CASE 
            WHEN area_name != TRIM(area_name) THEN 1 
        END
    ) AS names_with_whitespace,
    CASE 
        WHEN COUNT(area_name) = COUNT(DISTINCT area_name) 
         AND COUNT(
             CASE 
                 WHEN area_name != TRIM(area_name) THEN 1 
             END
         ) = 0 
            THEN 'PASS: All Names Unique & Clean'
        ELSE 'FAIL: Duplicate Names or Whitespace Detected'
    END AS name_integrity_check
FROM wards_metadata;

-- 1.8 Wards Metadata: Geographic Bounds Verification
SELECT 
    MIN(latitude)  AS min_lat, 
    MAX(latitude)  AS max_lat,
    MIN(longitude) AS min_lon, 
    MAX(longitude) AS max_lon,
    COUNT(
        CASE 
            WHEN latitude NOT BETWEEN 52.30 AND 52.60 
              OR longitude NOT BETWEEN -2.05 AND -1.70 
                THEN 1 
        END
    ) AS out_of_bounds_coords
FROM wards_metadata;

-- 1.9 PostGIS Spatial Setup Diagnostic Verification
-- Asserts SRID, Dimensions, and Geometry Types across spatial tables
SELECT 
    'caz_polygon' AS spatial_table, 
    id, 
    name, 
    ST_SRID(geom) AS srid, 
    ST_NDims(geom) AS dimensions, 
    ST_GeometryType(geom) AS geom_type 
FROM caz_polygon

UNION ALL

SELECT 
    'monitoring_sites', 
    site_id AS id, 
    site_name AS name,
    ST_SRID(geom_27700) AS srid, 
    ST_NDims(geom_27700) AS dimensions, 
    ST_GeometryType(geom_27700) AS geom_type
FROM monitoring_sites
LIMIT 1;


/* ==============================================================================
   PART 2: FLEET STATUS & TRAFFIC DIAGNOSTICS (caz_traffic_compliance)
============================================================================== */

-- 2.1 Traffic Data: Missingness & Logic Anomalies
SELECT 
    COUNT(*) AS total_rows,
    COUNT(
        CASE 
            WHEN compliant_vehicles IS NULL THEN 1 
        END
    ) AS compliance_nulls,
    ROUND(
        100.0 * COUNT(
            CASE 
                WHEN compliant_vehicles IS NULL THEN 1 
            END
        ) / COUNT(*), 
        2
    ) AS compliance_nulls_pct,
    COUNT(
        CASE 
            WHEN compliant_vehicles < 0 THEN 1 
        END
    ) AS negative_compliant_count,
    COUNT(
        CASE 
            WHEN noncompliant_vehicles < 0 THEN 1 
        END
    ) AS negative_noncompliant_count,
    COUNT(
        CASE 
            WHEN total_vehicles < 0 THEN 1 
        END
    ) AS negative_total_count,
    COUNT(
        CASE 
            WHEN compliant_vehicles = 0 THEN 1 
        END
    ) AS zero_compliant_count,
    COUNT(
        CASE 
            WHEN noncompliant_vehicles = 0 THEN 1 
        END
    ) AS zero_noncompliant_count,
    COUNT(
        CASE 
            WHEN total_vehicles = 0 THEN 1 
        END
    ) AS zero_total_count,
    COUNT(DISTINCT vehicle_type) AS distinct_vehicle_types
FROM caz_traffic_compliance;

-- 2.2 Traffic Data: Summary Statistics by Vehicle Type
SELECT 
    vehicle_type,
    MIN(compliant_vehicles) AS min_compliant, 
    MAX(compliant_vehicles) AS max_compliant,
    ROUND(AVG(compliant_vehicles), 1) AS avg_compliant,
    MIN(noncompliant_vehicles) AS min_noncompliant, 
    MAX(noncompliant_vehicles) AS max_noncompliant,
    ROUND(AVG(noncompliant_vehicles), 1) AS avg_noncompliant,
    MIN(total_vehicles) AS min_total, 
    MAX(total_vehicles) AS max_total,
    ROUND(AVG(total_vehicles), 1) AS avg_total,
    ROUND(MIN(100.0 * compliant_vehicles / NULLIF(total_vehicles, 0)), 2) AS min_compliance_rate_pct,
    ROUND(MAX(100.0 * compliant_vehicles / NULLIF(total_vehicles, 0)), 2) AS max_compliance_rate_pct,
    ROUND(AVG(100.0 * compliant_vehicles / NULLIF(total_vehicles, 0)), 2) AS avg_compliance_rate_pct
FROM caz_traffic_compliance
GROUP BY 
    vehicle_type 
ORDER BY 
    vehicle_type;

-- 2.3 Traffic Data: Temporal Bounds & Alignment Check
SELECT 
    vehicle_type, 
    MIN(date) AS start_date, 
    MAX(date) AS end_date, 
    COUNT(DISTINCT date) AS unique_months
FROM caz_traffic_compliance
GROUP BY 
    vehicle_type 
ORDER BY 
    vehicle_type;


/* ==============================================================================
   PART 3: AIR QUALITY DIAGNOSTICS (no2_readings)
============================================================================== */

-- 3.1 NO2 Readings: Column-Level Completeness Audit
SELECT
    COUNT(*) AS total_records,
    COUNT(*) - COUNT(site_id)     AS site_id_nulls,
    COUNT(*) - COUNT(date_time)   AS date_time_nulls,
    COUNT(*) - COUNT(no2)         AS no2_nulls,
    ROUND(((COUNT(*) - COUNT(no2))::numeric / COUNT(*)) * 100, 2) AS no2_nulls_percentage
FROM no2_readings;

-- 3.2 NO2 Readings: Temporal Horizon & Clock Sanity Check
SELECT 
    MIN(date_time) AS earliest_reading, 
    MAX(date_time) AS latest_reading,
    COUNT(
        CASE 
            WHEN date_time > CURRENT_TIMESTAMP THEN 1 
        END
    ) AS future_readings_count
FROM no2_readings;

-- 3.3 NO2 Readings: Statistical Distribution & Physical Boundary Assertions (by Site)
SELECT 
    site_id, 
    site_name, 
    COUNT(*) AS total_readings,
    MIN(no2) AS min_no2, 
    MAX(no2) AS max_no2, 
    ROUND(AVG(no2)::numeric, 2) AS avg_no2,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY no2) AS median_no2,
    COUNT(
        CASE 
            WHEN no2 < 0 THEN 1 
        END
    ) AS negative_values,
    COUNT(
        CASE 
            WHEN no2 = 0 THEN 1 
        END
    ) AS zero_values,
    COUNT(
        CASE 
            WHEN no2 > 500 THEN 1 
        END
    ) AS extreme_spikes
FROM no2_readings
GROUP BY 
    site_id 
ORDER BY 
    site_id;

-- 3.4 NO2 Readings: Negative Value Severity Breakdown
SELECT
    site_id, 
    site_name, 
    COUNT(*) AS total_site_readings,
    COUNT(
        CASE 
            WHEN no2 < 0 THEN 1 
        END
    ) AS total_negative_readings,
    COUNT(
        CASE 
            WHEN no2 BETWEEN -1.0 AND 0 THEN 1 
        END
    ) AS minor_drift_count,
    ROUND(
        (COUNT(
            CASE 
                WHEN no2 BETWEEN -1.0 AND 0 THEN 1 
            END
        )::numeric / COUNT(*)) * 100, 
        4
    ) AS minor_drift_pct_of_site_total,
    COUNT(
        CASE 
            WHEN no2 < -1.0 THEN 1 
        END
    ) AS severe_anomaly_count,
    ROUND(
        (COUNT(
            CASE 
                WHEN no2 < -1.0 THEN 1 
            END
        )::numeric / COUNT(*)) * 100, 
        4
    ) AS severe_anomaly_pct_of_site_total,
    MIN(no2) AS worst_negative_reading
FROM no2_readings AS r
INNER JOIN monitoring_sites AS s 
    USING (site_id)
GROUP BY 
    site_id, 
    site_name 
ORDER BY 
    site_id, 
    site_name;

-- 3.5 NO2 Readings: Data Capture & Annual Mean Audit (Calendar Year)
WITH cleaned_readings AS (
    SELECT 
        site_id, 
        EXTRACT(YEAR FROM date_time) AS reading_year, 
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN no2 < -1.0 THEN NULL 
            ELSE no2 
        END AS no2_diagnosed
    FROM no2_readings
),
monthly_completeness AS (
    SELECT 
        site_id, 
        reading_year, 
        reading_month,
        ROUND(
            (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) * 100, 
            2
        ) AS monthly_data_capture_pct,
        CASE 
            WHEN (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) >= 0.75 THEN 1 
            ELSE 0 
        END AS is_valid_month
    FROM cleaned_readings 
    GROUP BY 
        site_id, 
        reading_year, 
        reading_month
)
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
    END AS laqm_annual_mean_status
FROM monthly_completeness 
GROUP BY 
    site_id, 
    reading_year 
ORDER BY 
    site_id, 
    reading_year;

-- 3.6 NO2 Readings: Acute Peak (99.8th Percentile) Eligibility Audit
WITH cleaned_readings AS (
    SELECT 
        site_id, 
        EXTRACT(YEAR FROM date_time) AS reading_year, 
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN no2 < -1.0 THEN NULL 
            ELSE no2 
        END AS no2_diagnosed
    FROM no2_readings
),
monthly_completeness AS (
    SELECT 
        site_id, 
        reading_year, 
        reading_month,
        CASE 
            WHEN (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) >= 0.75 THEN 1 
            ELSE 0 
        END AS is_valid_month
    FROM cleaned_readings 
    GROUP BY 
        site_id, 
        reading_year, 
        reading_month
)
SELECT 
    site_id, 
    reading_year, 
    SUM(is_valid_month) AS valid_months_count,
    CASE 
        WHEN SUM(is_valid_month) >= 9 THEN 'VALID' 
        ELSE 'INVALID (Seasonal Bias Risk)' 
    END AS percentile_99_8_status,
    CASE 
        WHEN SUM(is_valid_month) >= 9 
            THEN 'Compute PERCENTILE_CONT(0.998) from hourly data'
        WHEN SUM(is_valid_month) BETWEEN 3 AND 8 
            THEN 'Nullify Percentile; Flag via DEFRA > 60 µg/m³ Mean Proxy'
        ELSE 'Suppress from acute peak reporting entirely'
    END AS remediation_instruction
FROM monthly_completeness 
GROUP BY 
    site_id, 
    reading_year 
ORDER BY 
    site_id, 
    reading_year;

-- 3.7 NO2 Readings: Fiscal Year Translation & Annualisation Assessment (NHS April-March)
WITH cleaned_readings AS (
    SELECT 
        site_id, 
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN EXTRACT(MONTH FROM date_time) >= 4 
                THEN EXTRACT(YEAR FROM date_time)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) + 1 - 2000)::text, 2, '0')
            ELSE (EXTRACT(YEAR FROM date_time) - 1)::text || '/' || LPAD((EXTRACT(YEAR FROM date_time) - 2000)::text, 2, '0')
        END AS fiscal_year,
        CASE 
            WHEN no2 < -1.0 THEN NULL 
            ELSE no2 
        END AS no2_diagnosed
    FROM no2_readings
),
monthly_completeness AS (
    SELECT 
        site_id, 
        fiscal_year, 
        reading_month,
        ROUND(
            (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) * 100, 
            2
        ) AS monthly_data_capture_pct,
        CASE 
            WHEN (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) >= 0.75 THEN 1 
            ELSE 0 
        END AS is_valid_month
    FROM cleaned_readings 
    GROUP BY 
        site_id, 
        fiscal_year, 
        reading_month
)
SELECT 
    site_id, 
    fiscal_year, 
    COUNT(reading_month) AS total_monitored_months,
    SUM(is_valid_month) AS valid_months_count, 
    ROUND(AVG(monthly_data_capture_pct), 2) AS yearly_avg_monthly_capture_pct,
    CASE 
        WHEN SUM(is_valid_month) >= 9 
            THEN 'PASS (Use As-Is)'
        WHEN SUM(is_valid_month) BETWEEN 3 AND 8 
            THEN 'ACTION (Requires Annualisation)'
        ELSE 'ACTION (Exclude - Insufficient Data)'
    END AS laqm_annual_mean_status
FROM monthly_completeness 
GROUP BY 
    site_id, 
    fiscal_year 
ORDER BY 
    site_id, 
    fiscal_year;


/* ==============================================================================
   PART 4: HEALTH IMPACT DIAGNOSTICS (birmingham_hospital_admissions)
============================================================================== */

-- 4.1 Health Data: System-Generated Fiscal Year Completeness
SELECT 
    COUNT(*) AS total_rows,
    COUNT(*) - COUNT(fiscal_year) AS missing_fiscal_years,
    CASE 
        WHEN COUNT(*) = COUNT(fiscal_year) 
            THEN 'PASS: Fiscal Year Auto-Generation Complete'
        ELSE 'FAIL: NULL Values Found in Fiscal Year'
    END AS fiscal_year_check
FROM birmingham_hospital_admissions;

-- 4.2 Health Data: Metric Range & Numeric Sanity
SELECT 
    MIN(admissions) AS min_admissions, 
    MAX(admissions) AS max_admissions,
    MIN(population) AS min_population, 
    MAX(population) AS max_population,
    MIN(standardised_rate) AS min_std_rate, 
    MAX(standardised_rate) AS max_std_rate,
    COUNT(
        CASE 
            WHEN admissions < 0 
              OR population <= 0 
              OR standardised_rate < 0 
                THEN 1 
        END
    ) AS invalid_metric_rows,
    CASE 
        WHEN COUNT(
            CASE 
                WHEN admissions < 0 
                  OR population <= 0 
                  OR standardised_rate < 0 
                    THEN 1 
            END
        ) = 0 
            THEN 'PASS: All Numeric Metrics Within Valid Ranges'
        ELSE 'FAIL: Negative or Zero Values Detected in Metrics'
    END AS metric_range_check
FROM birmingham_hospital_admissions;

-- 4.3 Health Data: Health Condition Panel Balance & Temporal Coverage
SELECT 
    health_condition,
    MIN(fiscal_start_date) AS earliest_start_date, 
    MAX(fiscal_start_date) AS latest_start_date,
    COUNT(DISTINCT fiscal_start_date) AS total_fiscal_periods,
    COUNT(DISTINCT area_code) AS wards_covered,
    COUNT(*) AS total_records
FROM birmingham_hospital_admissions
GROUP BY 
    health_condition 
ORDER BY 
    health_condition;
