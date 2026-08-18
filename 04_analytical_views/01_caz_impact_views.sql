-- ============================================================================
-- VIEW: analytics_site_yearly_summary
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
-- TITLE: Presentation - Power BI Imputed Traffic View
-- PURPOSE: Provides a clean, lightweight semantic layer for Power BI.
--          Extracts 'year' (cast as INTEGER) for seamless mapping to dim_years.
--          All heavy imputation is pre-calculated in the physical staging table.
-- ARCHITECTURE: Medallion (Gold Layer)
--------------------------------------------------------------------------------

DROP VIEW IF EXISTS vw_powerbi_traffic;

CREATE VIEW vw_powerbi_traffic AS 
SELECT 
    date,
    EXTRACT(YEAR FROM date)::INTEGER AS year,  -- Cast to integer for perfect Power BI joins
    vehicle_type,
    compliant_vehicles,
    noncompliant_vehicles,
    total_vehicles,
    data_source_type
FROM analytics_imputed_traffic_monthly;

/* ==============================================================================================
TITLE: Power BI View Update - Traffic with Fiscal Year Integration
=================================================================================================

NOTES & CHANGELOG:
- WHAT WAS CHANGED: 
  Added a new calculated column `fiscal_year` (format: "YYYY/YY") derived from the `date` column. 
  The calculation follows the standard UK fiscal calendar (April 1st to March 31st).
  The original `year` column was explicitly cast as an INTEGER.

- WHY THIS CHANGE WAS MADE:
  To enable cross-filtering in the Power BI Executive Summary dashboard. Hospitalizations 
  and respiratory health data are reported by fiscal year. By calculating the fiscal year 
  at the database level, we can link this traffic view to a new 'Dim_Fiscal_Year' 
  role-playing dimension table in Power BI. This allows decision-makers to view 
  traffic compliance and health outcomes on the exact same timeline without relying 
  on complex DAX dual-axis workarounds or duplicating the fact table.
  The original `year` column is preserved as an integer so existing calendar-based 
  relationships are not broken.
============================================================================================== */

DROP VIEW IF EXISTS vw_powerbi_traffic;

CREATE VIEW vw_powerbi_traffic AS 
SELECT 
    date,
    EXTRACT(YEAR FROM date)::INTEGER AS year,  -- Cast to integer for perfect Power BI joins
    vehicle_type,
    compliant_vehicles,
    noncompliant_vehicles,
    total_vehicles,
    data_source_type,
    
    -- Dynamic UK Fiscal Year Calculation (April to March)
    CASE 
        WHEN EXTRACT(MONTH FROM date) >= 4 THEN 
            EXTRACT(YEAR FROM date)::TEXT || '/' || RIGHT((EXTRACT(YEAR FROM date) + 1)::TEXT, 2)
        ELSE 
            (EXTRACT(YEAR FROM date) - 1)::TEXT || '/' || RIGHT(EXTRACT(YEAR FROM date)::TEXT, 2)
    END AS fiscal_year

FROM analytics_imputed_traffic_monthly;


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
-- VIEW: vw_hospital_wards_map
-- DESCRIPTION: Formats the 69 Birmingham ward boundaries and WKT geometries 
--              into a clean, standardized schema for direct ingestion and map 
--              rendering in Power BI alongside CAZ tiers.
--------------------------------------------------------------------------------

DROP VIEW IF EXISTS vw_hospital_wards_map;

CREATE VIEW vw_hospital_wards_map AS
SELECT 
    wd23cd AS ward_code,
    wd23nm AS ward_name,
    lad23nm AS local_authority,
    wkt AS wkt_geometry,
    'Hospital Ward Boundary' AS layer_type
FROM 
    birmingham_wards;

--------------------------------------------------------------------------------
-- VIEW: vw_dim_wards
-- DESCRIPTION: Denormalized dimension view combining ward metadata with 
--              WKT (Well-Known Text) spatial boundaries from QGIS. 
--              By flattening the 1-to-1 relationship into a single view, 
--              this optimizes the Power BI Star Schema, avoids slow Power 
--              Query merges, and seamlessly links to dim_caz_tiers.
--------------------------------------------------------------------------------

DROP VIEW IF EXISTS vw_hospital_wards_map; -- Cleans up your old view
DROP VIEW IF EXISTS vw_dim_wards;

CREATE VIEW vw_dim_wards AS 
SELECT 
    m.area_code,
    m.area_name,
    m.caz_tier,
    m.distance_to_caz_metres,
    m.latitude,
    m.longitude,
    w."WKT" AS wkt_geometry,
    'Ward Boundary' AS layer_type
FROM 
    wards_metadata m
LEFT JOIN 
    birmingham_wards w 
    ON m.area_code = w."WD23CD";


/* =================================================================================================
VIEW NAME: public.vw_caz_and_sites_map
PURPOSE:   Provides a unified, single-layer spatial dataset for Power BI (Icon Map Pro).

RATIONALE & ARCHITECTURE:
1. The "Roche's Maxim" Approach: 
   Instead of appending disparate spatial datasets inside Power Query (which can degrade model 
   refresh performance), we transform and stack the data upstream in PostgreSQL using a UNION ALL.

2. Polymorphic Dimension:
   This view acts as a single dimension table in the Power BI Star Schema. Because 'map_id' holds 
   both CAZ Tier IDs and Site IDs, it can independently filter multiple fact tables (e.g., NO2 
   Readings, Respiratory Admissions) depending on which map element the user clicks.

3. Icon Map Pro & WKT (Well-Known Text):
   To render both Polygons (CAZ boundaries) and Points (Monitoring sites) on the same map layer, 
   Icon Map Pro requires a WKT text string. 
   - Polygons are generated natively from the PostGIS 'geom' column.
   - Points are manually concatenated into a 'POINT(X Y)' string.

4. Bypassing Power BI Limits (The 32k Character Rule):
   Power BI strictly limits text cells to 32,766 characters. Complex polygons with 14-decimal-place 
   precision will exceed this limit, causing the map visual to break or render blanks. 
   We apply ST_Simplify() to reduce vertex count and force ST_AsText() to round to 5 decimal places.

5. Retaining Raw Coordinates:
   While the 'wkt_geometry' column drives the visual rendering, raw Latitude and Longitude columns 
   are retained as NUMERIC data types to support human-readable tooltips and future DAX calculations.
================================================================================================= */

CREATE OR REPLACE VIEW vw_caz_and_sites_map AS 

-- ==========================================
-- LAYER 1: The CAZ Tiers (Polygons)
-- ==========================================
SELECT 
    caz_tier::TEXT AS map_id,
    'CAZ Tier ' || caz_tier AS map_label,
    
    -- SPATIAL FIX: Simplifies the geometry to reduce vertices and rounds to 5 decimal places 
    -- to prevent exceeding Power BI's 32k character limit.
    ST_AsText(ST_Simplify(geom, 0.0001), 5) AS wkt_geometry, 
    
    'CAZ Boundary' AS layer_type,
    caz_tier,
    NULL::TEXT AS site_type,
    NULL::NUMERIC AS latitude,
    NULL::NUMERIC AS longitude,
    NULL::TEXT AS data_source,
    NULL::DATE AS start_date,
    NULL::DATE AS end_date,
    NULL::NUMERIC AS distance_to_caz_metres
FROM 
    dim_caz_tiers

UNION ALL

-- ==========================================
-- LAYER 2: Monitoring Sites (Points)
-- ==========================================
SELECT 
    site_id::TEXT AS map_id,                   
    site_name AS map_label, 
    
    -- SPATIAL FIX: Manually constructs the WKT Point string from raw coordinates.                  
    'POINT(' || longitude || ' ' || latitude || ')' AS wkt_geometry, 
    
    'Monitoring Site' AS layer_type,           
    caz_tier,                                  
    site_type,                                 
    latitude,                                  
    longitude,                                 
    data_source,                               
    start_date,                                
    end_date,                                  
    distance_to_caz_metres                     
FROM 
    monitoring_sites;
    
    /* =================================================================================================
VIEW NAME: public.vw_caz_and_wards_map
PURPOSE:   Provides a unified spatial dataset for Power BI (Icon Map Pro) to render both 
           CAZ boundaries and Ward polygons on a single map layer.

RATIONALE & ARCHITECTURE:
1. Polymorphic Dimension: 
   Combines 'caz_tier' and 'area_code' into a single 'map_id' column to filter downstream 
   fact tables from one map visual.
2. 32k Limit Prevention (CAZ Tiers): 
   Applies ST_Simplify and rounding to 5 decimal places to the raw 'geom' MULTIPOLYGON.
3. 32k Limit Prevention (Wards): 
   Because vw_dim_wards outputs an unsimplified WKT text string, we use ST_GeomFromText() 
   to cast it back to a spatial object, simplify the vertices, and round the text output 
   to 5 decimal places to prevent visual rendering failures in Power BI.
================================================================================================= */

/* =================================================================================================
VIEW NAME: public.vw_caz_and_wards_map
PURPOSE:   Provides a unified spatial dataset for Power BI (Icon Map Pro) to render both 
           CAZ boundaries and Ward polygons on a single map layer.

RATIONALE & ARCHITECTURE:
1. Polymorphic Dimension: 
   Combines 'caz_tier' and 'area_code' into a single 'map_id' column to filter downstream 
   fact tables from one map visual.
2. 32k Limit Prevention (CAZ Tiers): 
   Applies ST_Simplify and rounding to 5 decimal places to the raw 'geom' MULTIPOLYGON.
3. 32k Limit Prevention (Wards): 
   Because vw_dim_wards outputs an unsimplified WKT text string, we use ST_GeomFromText() 
   to cast it back to a spatial object, simplify the vertices, and round the text output 
   to 5 decimal places to prevent visual rendering failures in Power BI.
================================================================================================= */

CREATE OR REPLACE VIEW public.vw_caz_and_wards_map AS 

-- ==========================================
-- LAYER 1: CAZ Tiers (Polygons)
-- ==========================================
SELECT 
    -- 1. Unified Map Identifiers
    caz_tier::TEXT AS map_id,
    'CAZ Tier ' || caz_tier AS map_label, 
    
    -- 2. Spatial Output: Simplify the native MULTIPOLYGON and round to 5 decimals
    ST_AsText(ST_Simplify(geom, 0.0001), 5) AS wkt_geometry, 
    
    -- 3. Layer Discriminator
    'CAZ Boundary'::TEXT AS layer_type,
    
    -- 4. Attributes 
    caz_tier::TEXT AS caz_tier,
    NULL::TEXT AS area_code,
    NULL::TEXT AS area_name,
    NULL::NUMERIC AS distance_to_caz_metres,
    NULL::NUMERIC AS latitude,
    NULL::NUMERIC AS longitude

FROM 
    public.dim_caz_tiers

UNION ALL

-- ==========================================
-- LAYER 2: Wards (Polygons)
-- ==========================================
SELECT 
    -- 1. Unified Map Identifiers
    area_code::TEXT AS map_id,
    area_name::TEXT AS map_label,
    
    -- 2. Spatial Output: Parse the unrounded text back to geometry, simplify, and round
    ST_AsText(ST_Simplify(ST_GeomFromText(wkt_geometry), 0.0001), 5) AS wkt_geometry, 
    
    -- 3. Layer Discriminator
    'Ward Boundary'::TEXT AS layer_type,
    
    -- 4. Attributes
    caz_tier::TEXT AS caz_tier,
    area_code::TEXT AS area_code,
    area_name::TEXT AS area_name,
    distance_to_caz_metres::NUMERIC AS distance_to_caz_metres,
    latitude::NUMERIC AS latitude,
    longitude::NUMERIC AS longitude

FROM 
    public.vw_dim_wards;



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
-- TITLE: Analytics Site Hourly & Monthly Profiles
-- DESCRIPTION: Aggregates NO2 readings by site, year, month, and hour to 
--              support seasonal and diumal diagnostic views in Power BI.
-- DEPENDENCIES: stg_final_annualised_means, no2_readings
-- ============================================================================

DROP TABLE IF EXISTS analytics_site_hourly_monthly_profiles;

CREATE TABLE analytics_site_hourly_monthly_profiles AS

WITH valid_site_years AS (
    -- Step 1: Retain the strict completeness rule (PASS% status)
    SELECT 
        site_id, 
        reading_year, 
        site_name
    FROM 
        stg_final_annualised_means
    WHERE 
        laqm_annual_mean_status LIKE 'PASS%'
)

-- Step 2: Aggregate regular hourly data across each site, year, month, and hour
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month,
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    -- Calculate average and max pollution levels for specific hour/month combinations
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
    r.no2 >= -1.0 -- Clean out equipment error codes
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(HOUR FROM r.date_time);

-- ============================================================================
-- INDEXES FOR POWER BI PERFORMANCE
-- ============================================================================
-- Composite index to ensure rapid filtering by site, year, and month in Power BI
CREATE INDEX idx_hourly_monthly_profile_filters 
    ON analytics_site_hourly_monthly_profiles(site_id, year, month);


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


/* =============================================================================
   Title:      Create Analytical View: NO2 Annualised Means (Fiscal Year)
   
   Purpose:    Creates a production-ready analytical view for Power BI consumption. 
               This view exposes NO2 annualised means aggregated by UK fiscal year 
               (April - March) rather than calendar year.
               
   Rationale:  Health outcome data (COPD and overall Respiratory hospital 
               admissions) is inherently tracked and reported by fiscal year. 
               By aligning our environmental NO2 aggregations to match this exact 
               same timeframe, we ensure an "apples-to-apples" temporal comparison 
               in the final dashboard. This prevents seasonal data (like winter 
               pollution spikes) from splitting across mismatched reporting buckets.
               
   Layer:      Analytics (Final presentation layer for BI tools)
   Source:     stg_final_annualised_means_fy (Staging layer)
   ============================================================================= */

CREATE OR REPLACE VIEW analytics_site_yearly_summary_fy AS
SELECT 
    site_id,
    site_name,
    fiscal_year,
    valid_months_count,
    laqm_annual_mean_status,
    assigned_reference_site_id,
    final_annualised_mean
FROM 
    stg_final_annualised_means_fy;

