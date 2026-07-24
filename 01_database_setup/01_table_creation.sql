-- ==========================================
-- 0. METADATA TABLE (Monitoring Sites)
-- ==========================================
-- Note: 'site_id' serves as the primary key to uniquely identify each monitoring station.

CREATE TABLE IF NOT EXISTS monitoring_sites (
site_id VARCHAR(50) PRIMARY KEY,
site_name VARCHAR(100),
site_type VARCHAR(30),
caz_zone VARCHAR(30),
latitude FLOAT,
longitude FLOAT,
data_source VARCHAR(20),
start_date DATE,
end_date DATE
);


-- ==========================================
-- 1. STAGING NO2 READINGS TABLE (For Raw CSV Imports)
-- ==========================================
-- Note: 'date_time' is VARCHAR to handle non-ISO CSV date formats.

CREATE TABLE IF NOT EXISTS no2_readings_staging (
    site_id VARCHAR(50),
    date_time VARCHAR(50),
    no2 DOUBLE PRECISION
);

-- ==========================================
-- 2. FINAL CLEAN TABLE
-- ==========================================
CREATE TABLE IF NOT EXISTS no2_readings (
    site_id VARCHAR(50),
    date_time TIMESTAMP,
    no2 DOUBLE PRECISION,

    -- Composite Primary Key (prevents duplicate site + hour rows)
    PRIMARY KEY (site_id, date_time),

    -- Foreign Key (links site_id to monitoring sites metadata)
    CONSTRAINT fk_monitoring_site
        FOREIGN KEY (site_id)
        REFERENCES monitoring_sites (site_id)
);

-- ==========================================
-- 3. ETL / DATA TRANSFER QUERY
-- ==========================================
-- Note: Transforms date_time into a proper TIMESTAMP and handles potential
-- duplicate entries (e.g., from daylight saving adjustments) using ON CONFLICT.
INSERT INTO no2_readings (site_id, date_time, no2)
SELECT 
    site_id,
    to_timestamp(date_time, 'DD/MM/YYYY HH24:MI'),
    no2
FROM no2_readings_staging
ON CONFLICT (site_id, date_time) DO NOTHING;


-- ==========================================
-- CAZ TRAFFIC COMPLIANCE TABLE
-- ==========================================
-- Note: Tracks monthly vehicle volumes. Supports both fully broken-down 
-- metrics and categories that only report a total vehicle count.

CREATE TABLE IF NOT EXISTS caz_traffic_compliance (
    date DATE NOT NULL,
    vehicle_type VARCHAR(100) NOT NULL,
    compliant_vehicles INTEGER NULL,
    noncompliant_vehicles INTEGER NULL,
    total_vehicles INTEGER NOT NULL,
    
    CONSTRAINT pk_caz_traffic_compliance PRIMARY KEY (date, vehicle_type),
    
   -- Integrity Check: Ensures either a valid math breakdown exists OR both 
   -- compliant/non-compliant are completely omitted
    
    CONSTRAINT chk_traffic_volume_integrity CHECK (
        (compliant_vehicles IS NULL AND noncompliant_vehicles IS NULL) OR
        (compliant_vehicles + noncompliant_vehicles = total_vehicles)
    )
);


-- Title: Database Setup for Wards and Hospital Admissions
-- Description: Normalized production-ready schema for Birmingham health data.
-- =========================================================================

-- 1. Create central Wards Metadata Dimension Table
CREATE TABLE IF NOT EXISTS wards_metadata (
    area_code CHAR(9) PRIMARY KEY,
    area_name VARCHAR(150) NOT NULL,
    latitude FLOAT8 NOT NULL,
    longitude FLOAT8 NOT NULL
);

-- 2. Create Hospital Admissions Fact Table
CREATE TABLE IF NOT EXISTS birmingham_hospital_admissions (
    health_condition VARCHAR(100) NOT NULL,
    area_code CHAR(9) NOT NULL,
    fiscal_start_date DATE NOT NULL,
    
    -- Automatically generates reporting string (e.g. '2019/20')
    fiscal_year VARCHAR(7) GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM fiscal_start_date)::TEXT || '/' || 
        RIGHT((EXTRACT(YEAR FROM fiscal_start_date) + 1)::TEXT, 2)
    ) STORED,

    admissions INTEGER NOT NULL,
    population INTEGER NOT NULL,
    standardised_rate NUMERIC(6,2) NOT NULL,

    -- Primary Key
    CONSTRAINT pk_birmingham_hospital_admissions 
        PRIMARY KEY (health_condition, area_code, fiscal_start_date),

    -- Foreign Key Relationship
    CONSTRAINT fk_hospital_admissions_ward 
        FOREIGN KEY (area_code) REFERENCES wards_metadata(area_code)
        
        /*******************************************************************************
  PHASE 0: DATABASE INITIALIZATION & POSTGIS SPATIAL CONFIGURATION
  Project: Birmingham CAZ Data Engineering Pipeline
  
  Executes core setup:
    1. Enables the PostGIS spatial engine.
    2. Adds projected EPSG:27700 (British National Grid) geometry columns.
    3. Transforms WGS84 Lat/Lon coordinates into planar meter projections.
    4. Builds Spatial GiST & Relational B-Tree Indexes across all project tables.
    5. Builds and populates the CAZ Boundary Polygon table.
*******************************************************************************/

-- =============================================================================
-- 1. EXTENSION & SPATIAL GEOMETRY COLUMNS SETUP
-- =============================================================================

-- Enable PostGIS Extension
CREATE EXTENSION IF NOT EXISTS postgis;

--------------------------------------------------------------------------------
-- 1.1 Monitoring Sites: Add & Transform EPSG:27700 Geometry
--------------------------------------------------------------------------------
ALTER TABLE monitoring_sites 
ADD COLUMN IF NOT EXISTS geom_27700 GEOMETRY(Point, 27700);

UPDATE monitoring_sites
SET geom_27700 = ST_Transform(
    ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
    27700
)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

--------------------------------------------------------------------------------
-- 1.2 Wards Metadata: Add & Transform EPSG:27700 Geometry
--------------------------------------------------------------------------------
ALTER TABLE wards_metadata 
ADD COLUMN IF NOT EXISTS geom_27700 GEOMETRY(Point, 27700);

UPDATE wards_metadata
SET geom_27700 = ST_Transform(
    ST_SetSRID(ST_MakePoint(longitude, latitude), 4326),
    27700
)
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;


-- =============================================================================
-- 2. COMPREHENSIVE INDEX SUITE (SPATIAL & TIME-SERIES)
-- Builds all required GiST and B-Tree indexes for optimal query execution
-- =============================================================================

--------------------------------------------------------------------------------
-- 2.1 Spatial GiST Indexes (Accelerates Distance & Boundary Calculations)
--------------------------------------------------------------------------------
-- Monitoring Sites 2D Geometry Index
CREATE INDEX IF NOT EXISTS idx_monitoring_sites_geom 
ON monitoring_sites USING GIST (geom_27700);

-- Wards Metadata 2D Geometry Index
CREATE INDEX IF NOT EXISTS idx_wards_metadata_geom 
ON wards_metadata USING GIST (geom_27700);

-- CAZ Polygon Base WGS84 Spatial Index
CREATE INDEX IF NOT EXISTS idx_caz_polygon_geom 
ON caz_polygon USING GIST (geom);

-- CAZ Polygon Functional Index (Pre-projects ST_Transform to EPSG:27700)
CREATE INDEX IF NOT EXISTS idx_caz_polygon_geom_27700 
ON caz_polygon USING GIST (ST_Transform(geom, 27700));


--------------------------------------------------------------------------------
-- 2.2 Relational & Time-Series B-Tree Indexes (Accelerates Joins & Filters)
--------------------------------------------------------------------------------
-- Time-Series NO2 Hourly Readings Lookup
CREATE INDEX IF NOT EXISTS idx_no2_readings_site_timestamp 
ON no2_readings (site_id, date_time);

-- Hospital Admissions Condition & Date Lookup
CREATE INDEX IF NOT EXISTS idx_birmingham_hosp_area_condition 
ON birmingham_hospital_admissions (area_code, health_condition);

CREATE INDEX IF NOT EXISTS idx_birmingham_hosp_area_date 
ON birmingham_hospital_admissions (area_code, fiscal_start_date);

-- Traffic Compliance Vehicle Type & Temporal Lookup
CREATE INDEX IF NOT EXISTS idx_traffic_compliance_date_vehicle 
ON caz_traffic_compliance (date, vehicle_type);


-- =============================================================================
-- 3. CAZ BOUNDARY POLYGON CREATION & VERIFICATION
-- Defines the Birmingham A4540 Middleway Ring Road boundary geometry
-- =============================================================================

CREATE TABLE IF NOT EXISTS caz_polygon (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    geom GEOMETRY(Polygon, 4326)
);

-- Insert central Birmingham CAZ boundary representation (A4540 Ring Road perimeter)
INSERT INTO caz_polygon (name, geom)
VALUES (
    'Birmingham CAZ (A4540 Ring Road)',
    ST_GeomFromText(
        'POLYGON((-1.9168 52.4883, -1.8801 52.4891, -1.8715 52.4741, -1.8902 52.4635, -1.9150 52.4690, -1.9168 52.4883))',
        4326
    )
)
ON CONFLICT DO NOTHING;


-- =============================================================================
-- 4. SPATIAL SETUP DIAGNOSTIC VERIFICATION
-- Asserts SRID, Dimensions, and Geometry Types across spatial tables
-- =============================================================================

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
);