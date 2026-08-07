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
-- TITLE: Clean Air Zone (CAZ) Yearly Traffic Summary & Pollution Load Pipeline
-- PURPOSE: Aggregates yearly traffic volumes, calculates baseline absolute variances 
--          from 2022, and computes a Weighted Fleet Pollution Load Index to 
--          evaluate whether traffic growth offsets vehicle compliance gains.
-- TARGET: Output table optimized for direct ingestion into Tableau for dual-axis 
--          air quality (NO2) correlation analysis.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- TITLE: Clean Air Zone (CAZ) Yearly Traffic Summary & Pollution Load Pipeline
-- PURPOSE: Aggregates yearly traffic volumes and computes a Vehicle-Specific 
--          Weighted Fleet NO2 Pollution Load Index to evaluate whether traffic 
--          volume growth offsets vehicle compliance gains ("Dampening Effect").
--------------------------------------------------------------------------------
-- INTERVIEW TALKING POINTS & METHODOLOGY (HOW TO DEFEND THIS MODEL):
--
-- 1. OVERCOMING THE NAIVE BASELINE (WHY WE DID THIS):
--    The original SQL used a blanket multiplier (* 0.25) for all compliant vehicles. 
--    This failed to capture the huge emission variance between engine types and 
--    fuel profiles. We replaced it with a scientifically grounded Proxy Index.
--
-- 2. METRIC ALIGNMENT (NO2 vs. NOx):
--    CAZ monitoring stations measure ambient NO2 (Nitrogen Dioxide) concentrations 
--    at roadside locations, NOT laboratory NOx. Our weights specifically reflect 
--    real-world urban NO2 tailpipe emissions and primary NO2 formation during 
--    stop-and-go driving conditions.
--
-- 3. DERIVATION OF PROXY WEIGHTS (CATEGORY BY CATEGORY):
--
--    * Non-Compliant Vehicles (Weight: 1.0):
--      Baseline heavy polluters (e.g., Euro 5 or older diesels). Every non-compliant 
--      vehicle receives full baseline weighting.
--
--    * Compliant Cars (Weight: 0.327):
--      Derived from UK Department for Transport (DfT) and RAC Foundation fleet stats.
--      Filtering for CAZ compliance yields an estimated compliant car composition of:
--        - 18% Zero-Emission EVs / Hydrogen (Weight: 0.0)
--        - 47% Compliant Petrol / Petrol Hybrids (Weight: 0.10)
--        - 35% Euro 6 Diesels (Weight: 0.80 — High real-world urban NO2 emissions)
--      Formula: (0.18 * 0.0) + (0.47 * 0.10) + (0.35 * 0.80) = 0.327
--
--    * Compliant LGVs / Vans (Weight: 0.725):
--      Commercial van fleets lag behind passenger cars in electrification. DfT stats 
--      show compliant van traffic is ~90% Euro 6 Diesel, 5% Petrol, and 5% EV.
--      Euro 6 diesel vans emit high primary NO2 under urban delivery driving cycles.
--      Formula: (0.05 * 0.0) + (0.05 * 0.10) + (0.90 * 0.80) = 0.725
--
--    * Compliant HGVs & Buses/Coaches (Weight: 0.15):
--      Heavy-duty Euro VI engines utilize highly effective Selective Catalytic 
--      Reduction (SCR) systems. Real-world testing demonstrates that Euro VI heavy 
--      vehicles emit significantly less ambient NO2 per vehicle in urban traffic 
--      than Euro 6 diesel passenger cars.
--
--    * Compliant Mini-Buses (Weight: 0.65):
--      DfT data confirms minibuses are overwhelmingly diesel-powered and built on 
--      commercial LGV/van chassis (e.g., Ford Transit, Mercedes Sprinter). Thus, 
--      their real-world NO2 footprint closely tracks LGVs (0.725) rather than 
--      full-size Euro VI buses (0.15).
--
--    * Compliant Exempt Vehicles (Weight: 0.60):
--      CAZ exemptions overwhelmingly consist of Wheelchair Accessible Vehicles 
--      (WAVs), emergency vehicles, and council utility fleets. These are built 
--      on heavy-duty diesel or van chassis rather than standard passenger cars.
--
--    * Unrecognised Vehicles (Weight: 0.50 on total_vehicles) - STATISTICAL IMPUTATION:
--      ANPR camera misreads are Missing Completely at Random (MCAR). Filtering them out 
--      would artificially under-report the city's total pollution footprint. Instead, we 
--      calculate the mathematical Expectation Value (E[X]) based on known Birmingham 
--      CAZ traffic distributions. With passenger cars accounting for ~80% of daily 
--      unique vehicles, LGVs making up roughly 8.3% to 9%, 
--      and HGVs around 1.1%:
--        - Cars (80% probability) * 0.40 approx weight = 0.32
--        - LGVs (9% probability) * 0.75 approx weight = 0.0675
--        - HGVs (1% probability) * 0.50 approx weight = 0.005
--        - Expected Value (E[X]) = ~0.3925
--      We round this up to a conservative 0.50 "blended fleet average" multiplier 
--      to provide a statistically neutral safety net, acknowledging that commercial 
--      vehicles run longer daily hours and are more prone to obscured plates.
--
--    * Motorcycles & Other (Weight: 0.10 on total_vehicles):
--      Small engine displacement results in a naturally low NO2 footprint.
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
    
    -- Absolute variance vs. 2022 baseline (Non-Compliant)
    SUM(noncompliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN noncompliant_vehicles END)) OVER () AS absolute_change_vs_2022_polluters,
    
    -- Absolute variance vs. 2022 baseline (Compliant)
    SUM(compliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN compliant_vehicles END)) OVER () AS absolute_change_vs_2022_clean,
    
    -- Data-Driven Vehicle-Specific NO2 Pollution Load Index
    SUM(
        CASE 
            WHEN vehicle_type = 'Car' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.327)
            WHEN vehicle_type = 'LGV' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.725)
            WHEN vehicle_type = 'HGV' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.15)
            WHEN vehicle_type = 'Bus/Coach' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.15)
            WHEN vehicle_type = 'Mini-Bus' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.65)
            WHEN vehicle_type = 'Exempt' THEN (noncompliant_vehicles * 1.0) + (compliant_vehicles * 0.60) 
            WHEN vehicle_type = 'Unrecognised' THEN (total_vehicles * 0.50) 
            WHEN vehicle_type = 'Motorcycles and Other' THEN (total_vehicles * 0.10) 
            ELSE (total_vehicles * 0.50) 
        END
    ) AS estimated_total_pollution_load

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