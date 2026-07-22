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

-- -----------------------------------------------------------------------------
-- 1.1 Primary Key & Descriptive Identifier Uniqueness Checks
-- -----------------------------------------------------------------------------
-- 1.1a. Verify Primary Key (site_id) is unique (Should return 0 rows)
SELECT 
    site_id, 
    COUNT(*) AS occurrence_count
FROM monitoring_sites
GROUP BY site_id
HAVING COUNT(*) > 1;

-- 1.1b. Verify site_names have no duplicates (Should return 0 rows)
SELECT 
    site_name, 
    COUNT(*) AS occurrence_count
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