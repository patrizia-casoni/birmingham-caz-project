-- =========================================================================
-- SCRIPT: 03_star_schema.sql
-- PROJECT: Birmingham Clean Air Zone (CAZ) Data Warehouse
-- DESCRIPTION: Finalizes the star schema by creating conformed dimension 
--              tables, cleaning data types, and enforcing referential 
--              integrity across all fact and dimension tables.
-- =========================================================================


-- =========================================================================
-- TITLE: PART 1 - CREATION OF CONFORMED DIMENSION TABLES
-- SUBTITLE: Establishing independent dimensions for CAZ tiers and master time
-- NOTES: 
--   - dim_caz_tiers standardizes the 5 classification tiers across geography 
--     and monitoring data.
--   - dim_years bridges calendar-year traffic/air quality datasets with 
--     fiscal-year healthcare datasets.
-- =========================================================================

-- 1.1 Create and Populate dim_caz_tiers
DROP TABLE IF EXISTS dim_caz_tiers CASCADE;

CREATE TABLE dim_caz_tiers (
    caz_tier_id VARCHAR(100) PRIMARY KEY,
    tier_description TEXT
);

INSERT INTO dim_caz_tiers (caz_tier_id, tier_description) VALUES
('1. Inside CAZ', 'Core Clean Air Zone area'),
('2. Close Boundary (<=500m)', 'Buffer zone within 500 meters of boundary'),
('3. Near Boundary (500m-2km)', 'Extended buffer zone between 500m and 2km'),
('4. Background (2km-5km)', 'Background comparison zone between 2km and 5km');

-- 1.2 Create and Populate dim_years (Master Time Dimension)
DROP TABLE IF EXISTS dim_years CASCADE;

CREATE TABLE dim_years (
    calendar_year INT PRIMARY KEY,
    fiscal_year VARCHAR(20) UNIQUE NOT NULL
);

INSERT INTO dim_years (calendar_year, fiscal_year) VALUES
(2018, '2018/19'),
(2019, '2019/20'),
(2020, '2020/21'),
(2021, '2021/22'),
(2022, '2022/23'),
(2023, '2023/24'),
(2024, '2024/25'),
(2025, '2025/26');


-- =========================================================================
-- TITLE: PART 2 - LINKING DIM_CAZ_TIERS TO SUPPORTING TABLES
-- SUBTITLE: Applying foreign key relationships for spatial and health data
-- NOTES: 
--   - Enforces that all wards, monitoring sites, and respiratory records 
--     reference valid tier categories.
-- =========================================================================

-- 2.1 Link Wards Metadata
ALTER TABLE wards_metadata
ADD CONSTRAINT fk_wards_caz_tier
FOREIGN KEY (caz_tier) 
REFERENCES dim_caz_tiers(caz_tier_id)
ON UPDATE CASCADE 
ON DELETE CASCADE;

-- 2.2 Link Monitoring Sites
ALTER TABLE monitoring_sites
ADD CONSTRAINT fk_monitoring_caz_tier
FOREIGN KEY (caz_tier) 
REFERENCES dim_caz_tiers(caz_tier_id)
ON UPDATE CASCADE 
ON DELETE CASCADE;

-- 2.3 Link CAZ Respiratory Master Fact Table
ALTER TABLE caz_respiratory_master
ADD CONSTRAINT fk_respiratory_caz_tier
FOREIGN KEY (caz_tier) 
REFERENCES dim_caz_tiers(caz_tier_id)
ON UPDATE CASCADE 
ON DELETE CASCADE;


-- =========================================================================
-- TITLE: PART 3 - TYPE CORRECTIONS & GLOBAL TIMELINE INTEGRATION
-- SUBTITLE: Casting data types and establishing global time relationships
-- NOTES: 
--   - Converts traffic summary year column from numeric to integer to 
--     satisfy PostgreSQL foreign key requirements.
--   - Connects all calendar- and fiscal-based fact tables to dim_years.
-- =========================================================================

-- 3.1 Fix data type for traffic summary year column (Numeric to Integer)
ALTER TABLE analytics_yearly_traffic_summary
ALTER COLUMN year TYPE INT USING year::INTEGER;

-- 3.2 Establish Primary Key for Traffic Summary
ALTER TABLE analytics_yearly_traffic_summary
ADD CONSTRAINT pk_analytics_yearly_traffic_summary PRIMARY KEY (year);

-- 3.3 Link Traffic Summary to dim_years
ALTER TABLE analytics_yearly_traffic_summary
ADD CONSTRAINT fk_traffic_summary_year
FOREIGN KEY (year) 
REFERENCES dim_years(calendar_year)
ON UPDATE CASCADE 
ON DELETE CASCADE;

-- 3.4 Link NO2 Site Summary to dim_years
ALTER TABLE analytics_site_yearly_summary
ADD CONSTRAINT fk_site_summary_year
FOREIGN KEY (year) 
REFERENCES dim_years(calendar_year)
ON UPDATE CASCADE 
ON DELETE CASCADE;

-- 3.5 Link Respiratory Master Fact Table to dim_years (via Fiscal Year)
ALTER TABLE caz_respiratory_master
ADD CONSTRAINT fk_caz_respiratory_fiscal_year
FOREIGN KEY (fiscal_year) 
REFERENCES dim_years(fiscal_year)
ON UPDATE CASCADE 
ON DELETE CASCADE;