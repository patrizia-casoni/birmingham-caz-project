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
);