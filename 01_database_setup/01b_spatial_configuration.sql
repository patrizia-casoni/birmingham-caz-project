/* ==============================================================================
   PART 1: ENABLE POSTGIS & CREATE SPATIAL TABLES
============================================================================== */
CREATE EXTENSION IF NOT EXISTS postgis;

-- CAZ Boundary Polygon
CREATE TABLE IF NOT EXISTS caz_polygon (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    geom GEOMETRY(Polygon, 4326)
);

INSERT INTO caz_polygon (name, geom)
VALUES (
    'Birmingham CAZ (A4540 Ring Road)',
    ST_GeomFromText('POLYGON((-1.9168 52.4883, -1.8801 52.4891, -1.8715 52.4741, -1.8902 52.4635, -1.9150 52.4690, -1.9168 52.4883))', 4326)
) ON CONFLICT DO NOTHING;

-- Birmingham Wards (WKT)
CREATE TABLE IF NOT EXISTS birmingham_wards (
    fid INTEGER,
    wd23cd VARCHAR(20),
    wd23nm VARCHAR(100) PRIMARY KEY,
    wd23nmw VARCHAR(100),
    lad23cd VARCHAR(20),
    lad23nm VARCHAR(100),
    wkt TEXT NOT NULL
);

/* ==============================================================================
   PART 2: TRANSFORM RELATIONAL COORDINATES TO PLANAR PROJECTIONS (EPSG:27700)
============================================================================== */
ALTER TABLE monitoring_sites ADD COLUMN IF NOT EXISTS geom_27700 GEOMETRY(Point, 27700);
UPDATE monitoring_sites
SET geom_27700 = ST_Transform(ST_SetSRID(ST_MakePoint(longitude, latitude), 4326), 27700)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

ALTER TABLE wards_metadata ADD COLUMN IF NOT EXISTS geom_27700 GEOMETRY(Point, 27700);
UPDATE wards_metadata
SET geom_27700 = ST_Transform(ST_SetSRID(ST_MakePoint(longitude, latitude), 4326), 27700)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

/* ==============================================================================
   PART 3: SPATIAL GIST INDEXES 
============================================================================== */
CREATE INDEX IF NOT EXISTS idx_monitoring_sites_geom ON monitoring_sites USING GIST (geom_27700);
CREATE INDEX IF NOT EXISTS idx_wards_metadata_geom ON wards_metadata USING GIST (geom_27700);
CREATE INDEX IF NOT EXISTS idx_caz_polygon_geom ON caz_polygon USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_caz_polygon_geom_27700 ON caz_polygon USING GIST (ST_Transform(geom, 27700));

/* ==============================================================================
   PART 4: SPATIAL SETUP DIAGNOSTIC VERIFICATION
============================================================================== */
SELECT 
    'caz_polygon' AS spatial_table, id, name, 
    ST_SRID(geom) AS srid, ST_NDims(geom) AS dimensions, ST_GeometryType(geom) AS geom_type 
FROM caz_polygon
UNION ALL
SELECT 
    'monitoring_sites', site_id AS id, site_name AS name,
    ST_SRID(geom_27700) AS srid, ST_NDims(geom_27700) AS dimensions, ST_GeometryType(geom_27700) AS geom_type
FROM monitoring_sites
LIMIT 1;
