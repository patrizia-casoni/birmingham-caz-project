

/* ==============================================================================================
TITLE: Presentation - Power BI Imputed Traffic View (Fiscal Year Integration)
ARCHITECTURE: Medallion (Gold Layer)
PURPOSE: Provides a clean, lightweight semantic layer for Power BI. 
         All heavy imputation is pre-calculated in the physical staging table.
=================================================================================================

NOTES & CHANGELOG:
- WHAT WAS CHANGED: 
  Added a new calculated column `fiscal_year` (format: "YYYY/YY") derived from the `date` column. 
  The calculation follows the standard UK fiscal calendar (April 1st to March 31st).
  The original `year` column was explicitly cast as an INTEGER for seamless mapping to dim_years.

- WHY THIS CHANGE WAS MADE:
  To enable cross-filtering in the Power BI Executive Summary dashboard. Hospitalisations 
  and respiratory health data are reported by fiscal year. By calculating the fiscal year 
  at the database level, we can link this traffic view to a new 'dim_years' 
  role-playing dimension table in Power BI. This allows decision-makers to view 
  traffic compliance and health outcomes on the exact same timeline without relying 
  on complex DAX dual-axis workarounds or duplicating the fact table.
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

