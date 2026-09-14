/* ==============================================================================
   PART 1: METADATA & STAGING TABLES
============================================================================== */
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

CREATE TABLE IF NOT EXISTS no2_readings_staging (
    site_id VARCHAR(50),
    date_time VARCHAR(50),
    no2 DOUBLE PRECISION
);

/* ==============================================================================
   PART 2: CORE ANALYTICAL TABLES (NO2, Traffic, Health)
============================================================================== */
CREATE TABLE IF NOT EXISTS no2_readings (
    site_id VARCHAR(50),
    date_time TIMESTAMP,
    no2 DOUBLE PRECISION,
    PRIMARY KEY (site_id, date_time),
    CONSTRAINT fk_monitoring_site FOREIGN KEY (site_id) REFERENCES monitoring_sites (site_id)
);

CREATE TABLE IF NOT EXISTS caz_traffic_compliance (
    date DATE NOT NULL,
    vehicle_type VARCHAR(100) NOT NULL,
    compliant_vehicles INTEGER NULL,
    noncompliant_vehicles INTEGER NULL,
    total_vehicles INTEGER NOT NULL,
    CONSTRAINT pk_caz_traffic_compliance PRIMARY KEY (date, vehicle_type),
    CONSTRAINT chk_traffic_volume_integrity CHECK (
        (compliant_vehicles IS NULL AND noncompliant_vehicles IS NULL) OR
        (compliant_vehicles + noncompliant_vehicles = total_vehicles)
    )
);

CREATE TABLE IF NOT EXISTS wards_metadata (
    area_code CHAR(9) PRIMARY KEY,
    area_name VARCHAR(150) NOT NULL,
    latitude FLOAT8 NOT NULL,
    longitude FLOAT8 NOT NULL
);

CREATE TABLE IF NOT EXISTS birmingham_hospital_admissions (
    health_condition VARCHAR(100) NOT NULL,
    area_code CHAR(9) NOT NULL,
    fiscal_start_date DATE NOT NULL,
    fiscal_year VARCHAR(7) GENERATED ALWAYS AS (
        EXTRACT(YEAR FROM fiscal_start_date)::TEXT || '/' || 
        RIGHT((EXTRACT(YEAR FROM fiscal_start_date) + 1)::TEXT, 2)
    ) STORED,
    admissions INTEGER NOT NULL,
    population INTEGER NOT NULL,
    standardised_rate NUMERIC(6,2) NOT NULL,
    CONSTRAINT pk_birmingham_hospital_admissions PRIMARY KEY (health_condition, area_code, fiscal_start_date),
    CONSTRAINT fk_hospital_admissions_ward FOREIGN KEY (area_code) REFERENCES wards_metadata(area_code)
);

/* ==============================================================================
   PART 3: RELATIONAL B-TREE INDEXES & INITIAL ETL
============================================================================== */
CREATE INDEX IF NOT EXISTS idx_no2_readings_site_timestamp ON no2_readings (site_id, date_time);
CREATE INDEX IF NOT EXISTS idx_birmingham_hosp_area_condition ON birmingham_hospital_admissions (area_code, health_condition);
CREATE INDEX IF NOT EXISTS idx_birmingham_hosp_area_date ON birmingham_hospital_admissions (area_code, fiscal_start_date);
CREATE INDEX IF NOT EXISTS idx_traffic_compliance_date_vehicle ON caz_traffic_compliance (date, vehicle_type);

-- Transform staging NO2 date_time into a proper TIMESTAMP
INSERT INTO no2_readings (site_id, date_time, no2)
SELECT 
    site_id,
    to_timestamp(date_time, 'DD/MM/YYYY HH24:MI'),
    no2
FROM no2_readings_staging
ON CONFLICT (site_id, date_time) DO NOTHING;
