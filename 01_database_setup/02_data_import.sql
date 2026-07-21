-- ==============================================================================
-- ==============================================================================
-- 02_data_import.sql
-- Description: Bulk load raw CSV datasets into PostgreSQL tables
-- Order of execution respects foreign key dependencies:
--   1. Dimension Tables (monitoring_sites, wards_metadata)
--   2. Fact & Auxiliary Tables (no2_readings, caz_traffic_compliance, birmingham_hospital_admissions)
-- ==============================================================================

BEGIN;

-- ------------------------------------------------------------------------------
-- 1. MONITORING SITES (Dimension / Metadata - 1 CSV)
-- ------------------------------------------------------------------------------
COPY public.monitoring_sites
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/monitoring_sites.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 2. WARDS METADATA (Dimension / Metadata - 1 CSV)
-- ------------------------------------------------------------------------------
COPY public.wards_metadata
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/wards_metadata.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 3. NO2 READINGS (Fact Table - 8 CSVs)
-- ------------------------------------------------------------------------------
-- Site 1: Colmore Row
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca1_brum_colmore_row.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 2: St Chads
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca2_brum_st_chads.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 3: Lower Severn Street
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca3_brum_lower_severn_street.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 4: New Hall
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca4_brum_new_hall.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 5: Selly Oak
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca5_brum_selly_oak.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 6: Stratford Road
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/bca5_brum_stratford_road.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 7: Ladywood
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/uka00655_brum_ladywood.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

-- Site 8: A4540 Roadside
COPY public.no2_readings
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/no2_readings/uka00626_brum_a4540.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 4. CAZ TRAFFIC COMPLIANCE (1 CSV)
-- ------------------------------------------------------------------------------
COPY public.caz_traffic_compliance
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/traffic_entering_brum_caz_compliance.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');


-- ------------------------------------------------------------------------------
-- 5. BIRMINGHAM HOSPITAL ADMISSIONS (1 CSV)
-- ------------------------------------------------------------------------------
COPY public.birmingham_hospital_admissions
FROM '/YOUR_LOCAL_PATH/birmingham-caz-project/data/hospital_admissions_brum_copd_respdisease.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',');

COMMIT;