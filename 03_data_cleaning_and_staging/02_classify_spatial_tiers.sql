/*******************************************************************************
  PHASE 1 (STAGING): SPATIAL TIER CLASSIFICATION
  Project: Birmingham CAZ Data Engineering Pipeline
  
  Description:
    Classifies monitoring sites and wards relative to the A4540 CAZ boundary 
    using British National Grid (EPSG:27700) meter distances.
    
    Tiers Defined:
      - 1. Inside CAZ: Within the ring road polygon
      - 2. Close Boundary: <= 500m from ring road
      - 3. Near Boundary: 500m to 2,000m (2km) from ring road
      - 4. Background: > 2,000m (up to the 5km control boundary)
*******************************************************************************/

-- =============================================================================
-- 1. ADD CLASSIFICATION COLUMNS (If not already present)
-- =============================================================================
ALTER TABLE monitoring_sites 
ADD COLUMN IF NOT EXISTS caz_tier VARCHAR(50),
ADD COLUMN IF NOT EXISTS distance_to_caz_metres NUMERIC(10, 2);

-- =============================================================================
-- 2. UPDATE MONITORING SITES WITH SPATIAL TIERS
-- =============================================================================
WITH tier_calculation AS (
    SELECT 
        ms.site_id,
        CASE 
            WHEN ST_Within(ms.geom_27700, ST_Transform(caz.geom, 27700)) THEN '1. Inside CAZ'
            WHEN ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700)) <= 500 
                THEN '2. Close Boundary (<=500m)'
            WHEN ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700)) <= 2000 
                THEN '3. Near Boundary (500m-2km)'
            ELSE '4. Background (>2km)'
        END AS calculated_tier,
        ROUND(ST_Distance(ms.geom_27700, ST_Transform(caz.geom, 27700))::numeric, 2) AS calculated_distance
    FROM monitoring_sites AS ms
    CROSS JOIN caz_polygon AS caz
)
UPDATE monitoring_sites AS ms
SET 
    caz_tier = tc.calculated_tier,
    distance_to_caz_metres = tc.calculated_distance
FROM tier_calculation AS tc
WHERE ms.site_id = tc.site_id;


-- =============================================================================
-- 3. VERIFICATION QUERY
-- Quick audit of site distribution across spatial tiers
-- =============================================================================
SELECT 
    caz_tier,
    COUNT(*) AS site_count,
    MIN(distance_to_caz_metres) AS min_distance_m,
    MAX(distance_to_caz_metres) AS max_distance_m
FROM monitoring_sites
GROUP BY caz_tier
ORDER BY caz_tier;