-- ==============================================================================
-- 02_data_import.sql
-- Description: Bulk load raw CSV datasets into PostgreSQL tables
-- Order of execution respects foreign key dependencies:
--   1. Dimension Tables (monitoring_sites, wards_metadata, birmingham_wards)
--   2. Fact & Auxiliary Tables (no2_readings_staging, caz_traffic, hospital_admissions)
--   3. ETL Transformation (Staging NO2 -> Final NO2)
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. DIMENSION METADATA TABLES
-- ------------------------------------------------------------------------------
COPY public.monitoring_sites
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/monitoring_sites.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY public.wards_metadata
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/wards_metadata.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY public.birmingham_wards
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/birmingham_wards_wkt.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 2. NO2 READINGS (Loaded into STAGING table first)
-- ------------------------------------------------------------------------------
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca1_brum_colmore_row.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca2_brum_st_chads.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca3_brum_lower_severn_street.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca4_brum_new_hall.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca5_brum_selly_oak.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca6_brum_stratford_road.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/uka00559_brum_acocks_green.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/uka00626_brum_a4540.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');
COPY public.no2_readings_staging FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/uka00655_brum_ladywood.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 3. OTHER FACT TABLES
-- ------------------------------------------------------------------------------
COPY public.caz_traffic_compliance
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/traffic_entering_brum_caz_compliance.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

COPY public.birmingham_hospital_admissions
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/hospital_admissions_brum_copd_respdisease.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 4. INITIAL ETL TRANSFORMATION (Staging -> Final)
-- ------------------------------------------------------------------------------
-- Transform staging NO2 date_time string into a proper TIMESTAMP
INSERT INTO no2_readings (site_id, date_time, no2)
SELECT 
    site_id,
    to_timestamp(date_time, 'DD/MM/YYYY HH24:MI'),
    no2
FROM no2_readings_staging
ON CONFLICT (site_id, date_time) DO NOTHING;

COMMIT;
