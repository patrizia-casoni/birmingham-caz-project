/*******************************************************************************
  PHASE 1 (STAGING): SPATIAL TIER CLASSIFICATION
  Project: Birmingham CAZ Data Engineering Pipeline
  
  Description:
    Classifies monitoring sites and wards relative to the A4540 CAZ boundary 
    using British National Grid (EPSG:27700) meter distances.
    
    Tiers Defined:
      - 1. Inside CAZ: Within the ring road polygon
      - 2. Close Boundary: Straddles boundary OR <= 500m from ring road
      - 3. Near Boundary: 500m to 2,000m (2km) from ring road
      - 4. Background: 2,000m to 5,000m (up to the 5km control boundary)
      - Excluded: > 5,000m from CAZ boundary
*******************************************************************************/

-- =============================================================================
-- 1. ADD CLASSIFICATION COLUMNS (If not already present)
-- =============================================================================
ALTER TABLE monitoring_sites 
ADD COLUMN IF NOT EXISTS caz_tier VARCHAR(50),
ADD COLUMN IF NOT EXISTS distance_to_caz_metres NUMERIC(10, 2);

ALTER TABLE wards_metadata 
ADD COLUMN IF NOT EXISTS caz_tier VARCHAR(50),
ADD COLUMN IF NOT EXISTS distance_to_caz_metres NUMERIC(10, 2);


-- =============================================================================
-- 2. UPDATE MONITORING SITES WITH SPATIAL TIERS
-- =============================================================================
WITH site_tier_calculation AS (
    SELECT 
        ms.site_id,
        CASE 
            WHEN ST_Within(ms.geom_27700, ST_Transform(caz.geom, 27700)) THEN '1. Inside CAZ'
            WHEN ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700)) <= 500 
                THEN '2. Close Boundary (<=500m)'
            WHEN ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700)) <= 2000 
                THEN '3. Near Boundary (500m-2km)'
            WHEN ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700)) <= 5000 
                THEN '4. Background (2km-5km)'
            ELSE 'Excluded (>5km Control)'
        END AS calculated_tier,
        ROUND(ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700))::numeric, 2) AS calculated_distance
    FROM monitoring_sites AS ms
    CROSS JOIN caz_polygon AS caz
)
UPDATE monitoring_sites AS ms
SET 
    caz_tier = stc.calculated_tier,
    distance_to_caz_metres = stc.calculated_distance
FROM site_tier_calculation AS stc
WHERE ms.site_id = stc.site_id;


-- =============================================================================
-- 3. UPDATE MUNICIPAL WARDS WITH SPATIAL TIERS
-- =============================================================================
WITH ward_tier_calculation AS (
    SELECT 
        w.area_code,
        CASE 
            -- Tier 1: Fully inside the CAZ polygon
            WHEN ST_Within(w.geom_27700, ST_Transform(caz.geom, 27700)) 
                THEN '1. Inside CAZ'
            
            -- Tier 2: Straddles the boundary OR within 500m perimeter buffer
            WHEN ST_Intersects(w.geom_27700, ST_Transform(caz.geom, 27700)) 
                THEN '2. Close Boundary (Straddles CAZ)'
            WHEN ST_Distance(w.geom_27700, ST_Transform(caz.geom, 27700)) <= 500 
                THEN '2. Close Boundary (<=500m)'
            
            -- Tier 3: Near Boundary (500m - 2000m)
            WHEN ST_Distance(w.geom_27700, ST_Transform(caz.geom, 27700)) <= 2000 
                THEN '3. Near Boundary (500m-2km)'
            
            -- Tier 4: Background Control (2000m - 5000m)
            WHEN ST_Distance(w.geom_27700, ST_Transform(caz.geom, 27700)) <= 5000 
                THEN '4. Background (2km-5km)'
            
            -- Excluded from study (>5km control limit)
            ELSE 'Excluded (>5km Control)'
        END AS calculated_tier,
        ROUND(ST_Distance(w.geom_27700, ST_Transform(caz.geom, 27700))::numeric, 2) AS calculated_distance
    FROM wards_metadata AS w
    CROSS JOIN caz_polygon AS caz
)
UPDATE wards_metadata AS w
SET 
    caz_tier = wtc.calculated_tier,
    distance_to_caz_metres = wtc.calculated_distance
FROM ward_tier_calculation AS wtc
WHERE w.area_code = wtc.area_code;


-- =============================================================================
-- 4. VERIFICATION QUERIES
-- Quick audit of distribution across spatial tiers for both tables
-- =============================================================================
SELECT 
    'Monitoring Sites' AS entity_type,
    caz_tier,
    COUNT(*) AS total_count,
    MIN(distance_to_caz_metres) AS min_distance_m,
    MAX(distance_to_caz_metres) AS max_distance_m
FROM monitoring_sites
GROUP BY caz_tier

UNION ALL

SELECT 
    'Municipal Wards' AS entity_type,
    caz_tier,
    COUNT(*) AS total_count,
    MIN(distance_to_caz_metres) AS min_distance_m,
    MAX(distance_to_caz_metres) AS max_distance_m
FROM wards_metadata
GROUP BY caz_tier

ORDER BY entity_type, caz_tier;