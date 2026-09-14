/*******************************************************************************
  PHASE 4: ANALYTICAL VIEWS
  File: 01_caz_impact_views.sql
  
  Description: 
    Creates the final Gold-layer analytical models and views tailored specifically 
    for direct ingestion into the Power BI Semantic Model, structured across 
    the 4 thematic project pillars: (1) Spatial/Metadata, (2) Traffic, 
    (3) Air Quality (Calendar Year), and (4) Air Quality (Fiscal Year Alignment).
*******************************************************************************/

/* ==============================================================================
   PART 1: SPATIAL ARCHITECTURE & MAP VIEWS
   Provides unified, simplified spatial datasets for Icon Map Pro rendering.
============================================================================== */

-- 1.1 Ward Boundaries Metadata Map Dimension View
DROP VIEW IF EXISTS vw_hospital_wards_map; 
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
FROM wards_metadata m
LEFT JOIN birmingham_wards w 
    ON m.area_code = w."WD23CD";

-- 1.2 CAZ Polygons and Monitoring Sites Polymorphic Map View
CREATE OR REPLACE VIEW vw_caz_and_sites_map AS 
SELECT 
    caz_tier::TEXT AS map_id,
    'CAZ Tier ' || caz_tier AS map_label,
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
FROM dim_caz_tiers

UNION ALL

SELECT 
    site_id::TEXT AS map_id,                   
    site_name AS map_label, 
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
FROM monitoring_sites;

-- 1.3 CAZ Polygons and Hospital Wards Polymorphic Map View
CREATE OR REPLACE VIEW public.vw_caz_and_wards_map AS 
SELECT 
    caz_tier::TEXT AS map_id,
    'CAZ Tier ' || caz_tier AS map_label, 
    ST_AsText(ST_Simplify(geom, 0.0001), 5) AS wkt_geometry, 
    'CAZ Boundary'::TEXT AS layer_type,
    caz_tier::TEXT AS caz_tier,
    NULL::TEXT AS area_code,
    NULL::TEXT AS area_name,
    NULL::NUMERIC AS distance_to_caz_metres,
    NULL::NUMERIC AS latitude,
    NULL::NUMERIC AS longitude
FROM public.dim_caz_tiers

UNION ALL

SELECT 
    area_code::TEXT AS map_id,
    area_name::TEXT AS map_label,
    ST_AsText(ST_Simplify(ST_GeomFromText(wkt_geometry), 0.0001), 5) AS wkt_geometry, 
    'Ward Boundary'::TEXT AS layer_type,
    caz_tier::TEXT AS caz_tier,
    area_code::TEXT AS area_code,
    area_name::TEXT AS area_name,
    distance_to_caz_metres::NUMERIC AS distance_to_caz_metres,
    latitude::NUMERIC AS latitude,
    longitude::NUMERIC AS longitude
FROM public.vw_dim_wards;


/* ==============================================================================
   PART 2: FLEET STATUS & TRAFFIC 
============================================================================== */

-- 2.1 Yearly Traffic Summary & Pollution Load Index (Table)
DROP TABLE IF EXISTS analytics_yearly_traffic_summary;

CREATE TABLE analytics_yearly_traffic_summary AS
SELECT 
    EXTRACT(YEAR FROM date) AS year, 
    vehicle_type,  
    SUM(compliant_vehicles) AS total_compliant_vehicles, 
    SUM(noncompliant_vehicles) AS total_non_compliant_vehicles, 
    SUM(total_vehicles) AS total_caz_vehicles,
    ROUND((SUM(noncompliant_vehicles)::NUMERIC / NULLIF(SUM(total_vehicles), 0)::NUMERIC) * 100, 2) AS overall_non_compliant_pct,
    
    SUM(noncompliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN noncompliant_vehicles END)) OVER () AS absolute_change_vs_2022_polluters,
    SUM(compliant_vehicles) - SUM(SUM(CASE WHEN EXTRACT(YEAR FROM date) = 2022 THEN compliant_vehicles END)) OVER () AS absolute_change_vs_2022_clean,
    
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

FROM stg_imputed_traffic_monthly 
GROUP BY 
    EXTRACT(YEAR FROM date), 
    vehicle_type
ORDER BY 
    year ASC, 
    vehicle_type ASC;

-- 2.2 Power BI Imputed Traffic View with Fiscal Year Integration (View)
DROP VIEW IF EXISTS vw_powerbi_traffic;

CREATE VIEW vw_powerbi_traffic AS 
SELECT 
    date,
    EXTRACT(YEAR FROM date)::INTEGER AS year,  
    vehicle_type,
    compliant_vehicles,
    noncompliant_vehicles,
    total_vehicles,
    data_source_type,
    CASE 
        WHEN EXTRACT(MONTH FROM date) >= 4 THEN 
            EXTRACT(YEAR FROM date)::TEXT || '/' || RIGHT((EXTRACT(YEAR FROM date) + 1)::TEXT, 2)
        ELSE 
            (EXTRACT(YEAR FROM date) - 1)::TEXT || '/' || RIGHT(EXTRACT(YEAR FROM date)::TEXT, 2)
    END AS fiscal_year
FROM analytics_imputed_traffic_monthly;


/* ==============================================================================
   PART 3: AIR QUALITY (Calendar Year)
============================================================================== */

-- 3.1 Final Site Yearly Summary with P99.8th Percentiles (Table)
DROP TABLE IF EXISTS analytics_site_yearly_summary;

CREATE TABLE analytics_site_yearly_summary AS
WITH cleaned_yearly_percentiles AS (
    SELECT 
        site_id, 
        EXTRACT(YEAR FROM date_time) AS reading_year, 
        PERCENTILE_CONT(0.998) WITHIN GROUP (ORDER BY no2) AS p998_no2_value
    FROM no2_readings 
    WHERE no2 >= -1.0 
    GROUP BY 
        site_id, 
        EXTRACT(YEAR FROM date_time)
)
SELECT 
    fam.site_id, 
    fam.site_name, 
    fam.reading_year AS year, 
    fam.final_annualised_mean AS annualised_mean, 
    fam.laqm_annual_mean_status,
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

-- 3.2 Top 19 Hourly Peaks for Executive Drill-Through (Table)
DROP TABLE IF EXISTS analytics_top19_hourly_peaks;

CREATE TABLE analytics_top19_hourly_peaks AS
WITH valid_site_years AS (
    SELECT 
        site_id, 
        reading_year, 
        site_name 
    FROM stg_final_annualised_means 
    WHERE laqm_annual_mean_status LIKE 'PASS%'
),
ranked_hourly_readings AS (
    SELECT 
        r.site_id, 
        v.site_name, 
        r.date_time AS exact_timestamp, 
        EXTRACT(YEAR FROM r.date_time) AS year, 
        EXTRACT(MONTH FROM r.date_time) AS month, 
        EXTRACT(DAY FROM r.date_time) AS day, 
        EXTRACT(HOUR FROM r.date_time) AS hour, 
        r.no2 AS hourly_no2_value,
        ROW_NUMBER() OVER (
            PARTITION BY r.site_id, EXTRACT(YEAR FROM r.date_time) 
            ORDER BY r.no2 DESC
        ) AS peak_rank
    FROM no2_readings r 
    INNER JOIN valid_site_years v 
        ON r.site_id = v.site_id 
        AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
    WHERE r.no2 >= -1.0
)
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
FROM ranked_hourly_readings 
WHERE peak_rank <= 19
ORDER BY 
    site_id, 
    year, 
    peak_rank;

CREATE INDEX idx_top19_site_year 
    ON analytics_top19_hourly_peaks(site_id, year);

-- 3.3 Hourly & Weekly Diurnal Profiles (Table)
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
    EXTRACT(ISODOW FROM r.date_time) AS day_of_week_num, 
    TO_CHAR(r.date_time, 'FMDay') AS day_of_week_name, 
    EXTRACT(HOUR FROM r.date_time) AS hour,
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2, 
    MAX(r.no2) AS max_hourly_no2, 
    COUNT(r.no2) AS sample_count
FROM no2_readings r
INNER JOIN valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE r.no2 >= -1.0
GROUP BY 
    r.site_id, 
    v.site_name, 
    EXTRACT(YEAR FROM r.date_time), 
    EXTRACT(MONTH FROM r.date_time), 
    EXTRACT(ISODOW FROM r.date_time), 
    TO_CHAR(r.date_time, 'FMDay'), 
    EXTRACT(HOUR FROM r.date_time);

CREATE INDEX idx_hourly_weekly_profile_filters 
    ON analytics_site_hourly_weekly_profiles(site_id, year, month, day_of_week_num);


/* ==============================================================================
   PART 4: AIR QUALITY (Fiscal Year Alignment)
============================================================================== */

-- 4.1 NO2 Annualised Means (Fiscal Year Alignment for Health Outcome Correlation)
CREATE OR REPLACE VIEW analytics_site_yearly_summary_fy AS
SELECT 
    site_id,
    site_name,
    fiscal_year,
    valid_months_count,
    laqm_annual_mean_status,
    assigned_reference_site_id,
    final_annualised_mean
FROM stg_final_annualised_means_fy;
