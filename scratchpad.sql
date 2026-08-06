CREATE TABLE IF NOT EXISTS monitoring_sites (
site_id VARCHAR(20) PRIMARY KEY,
site_name VARCHAR(100),
site_type VARCHAR(30),
caz_zone VARCHAR(30),
latitude FLOAT,
longitude FLOAT,
data_source VARCHAR(20),
start_date DATE,
end_date DATE
);


truncate table no2_readings;

drop table if exists no2_readings;
drop table if exists no2_readings_staging;

CREATE TABLE no2_readings_staging (
    site_id VARCHAR(50),
    date_time VARCHAR(50),
    no2 DOUBLE precision
);

CREATE TABLE no2_readings (
    site_id VARCHAR(20),
    date_time TIMESTAMP,
    no2 DOUBLE PRECISION,
    PRIMARY KEY (site_id, date_time),
    FOREIGN KEY (site_id) REFERENCES monitoring_sites(site_id)
);


INSERT INTO no2_readings (site_id, date_time, no2)
SELECT 
    site_id, 
    to_timestamp(date_time, 'YYYY/MM/DD HH24:MI'), 
    no2
FROM no2_readings_staging
ON CONFLICT (site_id, date_time) DO NOTHING;

DROP TABLE no2_readings_staging;

truncate no2_readings;

CREATE TABLE IF NOT EXISTS no2_readings_staging (
site_id VARCHAR(50),
date_time VARCHAR(50),
no2 VARCHAR(50)
);

drop table if exists no2_readings;

create table if not exists no2_readings (
site_id VARCHAR(50),
date_time TIMESTAMP,
no2 FLOAT8,

-- 1. Composite Primary Key (prevents duplicate site + hr rows)
primary key (site_id, date_time),

--2. Foreign Key (links site_id to monitoring sites metadata)
constraint fk_monitoring_site
foreign key (site_id)
references monitoring_sites (site_id)
);

insert into no2_readings (site_id, date_time, no2)
select 
site_id,
to_timestamp (date_time, 'DD/MM/YYYY HH24:MI'),
nullif(trim(no2), '')::float8
from no2_readings_staging
on conflict (site_id, date_time) do nothing;

truncate no2_readings_staging;

insert into no2_readings (site_id, date_time, no2)
select 
site_id,
to_timestamp (date_time, 'DD/MM/YYYY HH24:MI'),
nullif(trim(no2), '')::float8
from no2_readings_staging
on conflict (site_id, date_time) do nothing;

select count(*)
from no2_readings;

truncate no2_readings_staging;

create table if not exists caz_traffic_compliance (
date DATE not NULL,
vehicle_type VARCHAR(100) not null,
compliant_vehicles INTEGER null,
noncompliant_vehicles INTEGER null,
total_vehicles INTEGER not null,

constraint pk_caz_traffic_compliance primary key (date, vehicle_type),

constraint chk_traffic_volume_integrity check (
(compliant_vehicles is null and noncompliant_vehicles is NULL) or
(compliant_vehicles + noncompliant_vehicles = total_vehicles)
)

);

truncate caz_traffic_compliance;

create table if not exists birmingham_hospital_admissions (
    health_condition VARCHAR(100) not NULL,
    area_code CHAR(9) not null,
    area_name VARCHAR(150) not null,
    
    fiscal_start_date DATE not null,
    
    fiscal_year VARCHAR(7) generated always as (
        extract(year from fiscal_start_date)::text || '/' || 
        right((extract(year from fiscal_start_date) + 1)::text, 2)
    ) stored,
    
    admissions INTEGER not NULL,
    population integer not null,
    standardised_rate NUMERIC(5,2) not null,
    
    constraint pk_birmingham_hospital_admissions primary key (health_condition, area_code, fiscal_start_date)
);


ALTER TABLE birmingham_hospital_admissions 
ALTER COLUMN standardised_rate TYPE NUMERIC(6,2);

alter table birmingham_hospital_admissions
drop column column8,
drop column column9;

create table if not exists wards_metadata (
area_code CHAR(9) primary key,
area_name VARCHAR(150) not null,
latitude FLOAT8,
longitude FLOAT8
);

alter table wards_metadata
alter column latitude set not null,
alter column longitude set not null;

alter table birmingham_hospital_admissions
drop column area_name;

alter table birmingham_hospital_admissions
add constraint fk_hospital_admissions_ward
foreign key (area_code) references wards_metadata (area_code);


SELECT 
    COUNT(*) AS total_rows,
    
    -- Missingness (Compliant & Non-Compliant are tied by DDL constraint)
    COUNT(*) FILTER (WHERE compliant_vehicles IS NULL) AS null_records_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE compliant_vehicles IS NULL) / COUNT(*), 2) AS null_records_pct,
    
    -- Logic Anomalies
    COUNT(*) FILTER (WHERE compliant_vehicles < 0 OR noncompliant_vehicles < 0 OR total_vehicles < 0) AS negative_counts_flag,
    COUNT(*) FILTER (WHERE total_vehicles = 0) AS zero_traffic_days_count,
    
    -- Domain Integrity (Categorical)
    COUNT(DISTINCT vehicle_type) AS distinct_vehicle_types
FROM caz_traffic_compliance;

select 
count(*) as total_rows,
-- Missingness (Compliant & Non-Compliant are tied by DDL constraint)
count(*) - count(compliant_vehicles) as compliant_vehicles_nulls,
-- Logic Anomalies

select 
count(*) as total_records,
count(case when compliant_vehicles is null then 1 end) as compliance_nulls,
ROUND((count(case when compliant_vehicles is null then 1 end)::numeric/count(*))*100, 2) as percentage_compliance_nulls,
count(case when compliant_vehicles <0 then 1 end) as compliant_negvalues,
count(case when noncompliant_vehicles <0 then 1 end) as noncompliant_negvalues,
count(case when total_vehicles <0 then 1 end) as total_vehicles_negvalues,
count(case when compliant_vehicles =0 then 1 end) as compliant_zerovalues,
count(case when noncompliant_vehicles =0 then 1 end) as noncompliant_zerovalues,
count(case when total_vehicles =0 then 1 end) as total_vehicles_zerovalues,
count(distinct vehicle_type) as distinct_vehicle_types
from caz_traffic_compliance;

DROP TABLE IF EXISTS public.birmingham_wards;


UPDATE monitoring_sites
SET longitude = -1.896791
WHERE site_id = 'BCA2';



DROP TABLE IF EXISTS analytics_site_yearly_summary;

CREATE TABLE analytics_site_yearly_summary AS
SELECT 
    fam.site_id,
    fam.site_name,
    fam.reading_year AS year,
    fam.final_annualised_mean AS annualised_mean,
    fam.laqm_annual_mean_status,
    -- Only calculate p99.8 for valid years where data capture is sufficient
    CASE 
        WHEN fam.laqm_annual_mean_status LIKE 'PASS%' THEN 
            (SELECT PERCENTILE_CONT(0.998) WITHIN GROUP (ORDER BY r.no2) 
             FROM no2_readings r 
             WHERE r.site_id = fam.site_id 
               AND EXTRACT(YEAR FROM r.date_time) = fam.reading_year)
        ELSE NULL 
    END AS p998_no2_value
FROM 
    stg_final_annualised_means fam
ORDER BY 
    fam.site_id, 
    fam.reading_year;

/*******************************************************************************
  SECTION 2.2B: ACUTE PEAK (99.8th PERCENTILE) ELIGIBILITY AUDIT
  Purpose: 
    1. Evaluates temporal coverage against strict 99.8th percentile requirements.
    2. Flags incomplete years to prevent seasonal bias in peak exceedance calculations.
    3. Assigns remediation directives (Calculate Direct vs. Nullify & Proxy).
*******************************************************************************/

WITH cleaned_readings AS (
    SELECT 
        site_id,
        date_time,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        EXTRACT(MONTH FROM date_time) AS reading_month,
        CASE 
            WHEN no2 < -1.0 THEN NULL 
            ELSE no2 
        END AS no2_diagnosed
    FROM no2_readings
),

monthly_completeness AS (
    SELECT 
        site_id,
        reading_year,
        reading_month,
        CASE 
            WHEN (COUNT(no2_diagnosed)::NUMERIC / COUNT(*)::NUMERIC) >= 0.75 THEN 1
            ELSE 0 
        END AS is_valid_month
    FROM cleaned_readings
    GROUP BY site_id, reading_year, reading_month
)

SELECT 
    site_id,
    reading_year,
    SUM(is_valid_month) AS valid_months_count,
    
    -- Percentile Data Validity Status
    CASE 
        WHEN SUM(is_valid_month) >= 9 THEN 'VALID'
        ELSE 'INVALID (Seasonal Bias Risk)'
    END AS percentile_99_8_status,
    
    -- Downstream Pipeline Directive
    CASE 
        WHEN SUM(is_valid_month) >= 9 
            THEN 'Compute PERCENTILE_CONT(0.998) from hourly data'
        WHEN SUM(is_valid_month) BETWEEN 3 AND 8 
            THEN 'Nullify Percentile; Flag via DEFRA > 60 µg/m³ Mean Proxy'
        ELSE 'Suppress from acute peak reporting entirely'
    END AS remediation_instruction

FROM monthly_completeness
GROUP BY site_id, reading_year
ORDER BY site_id, reading_year;




-- ============================================================================
-- VIEW: analytics_site_yearly_summary
-- DESCRIPTION: Consolidates regulatory annualised compliance means with 
--              robust empirical peak pollution values (P99.8). Percentile 
--              calculations are restricted to valid years (PASS) to prevent 
--              statistical distortion. Designed for Power BI reporting layers.
-- ============================================================================
DROP TABLE IF EXISTS analytics_site_yearly_summary;

CREATE TABLE analytics_site_yearly_summary AS

WITH cleaned_yearly_percentiles AS (
    -- Step 1: Clean raw data (-1.0 exclusion) and aggregate percentiles efficiently
    SELECT 
        site_id,
        EXTRACT(YEAR FROM date_time) AS reading_year,
        PERCENTILE_CONT(0.998) WITHIN GROUP (ORDER BY no2) AS p998_no2_value
    FROM no2_readings
    WHERE no2 >= -1.0 
    GROUP BY site_id, EXTRACT(YEAR FROM date_time)
)

-- Step 2: Join safe percentiles to the finalized LAQM staging table
SELECT 
    fam.site_id,
    fam.site_name,
    fam.reading_year AS year,
    fam.final_annualised_mean AS annualised_mean,
    fam.laqm_annual_mean_status,
    
    -- Step 3: Enforce strict data governance (only valid years get a percentile)
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


-- ============================================================================
-- TABLE: analytics_top19_hourly_peaks
-- DESCRIPTION: Isolates the exact 19 highest hourly NO2 readings per site/year.
--              Since the 19th highest hour defines the 99.8th percentile 
--              threshold, this table provides exact drill-through transparency 
--              for executives. Restricted to LAQM-valid years.
-- ============================================================================
DROP TABLE IF EXISTS analytics_top19_hourly_peaks;

CREATE TABLE analytics_top19_hourly_peaks AS

WITH valid_site_years AS (
    -- Step 1: Identify eligible sites/years based on strict 9-month data capture
    SELECT 
        site_id, 
        reading_year, 
        site_name
    FROM 
        stg_final_annualised_means
    WHERE 
        laqm_annual_mean_status LIKE 'PASS%'
),

ranked_hourly_readings AS (
    -- Step 2: Join raw data to valid years and rank the highest NO2 hours
    SELECT 
        r.site_id,
        v.site_name,
        r.date_time AS exact_timestamp,
        EXTRACT(YEAR FROM r.date_time) AS year,
        EXTRACT(MONTH FROM r.date_time) AS month,
        EXTRACT(DAY FROM r.date_time) AS day,
        EXTRACT(HOUR FROM r.date_time) AS hour,
        r.no2 AS hourly_no2_value,
        
        -- Rank readings highest to lowest, resetting for each site and year
        ROW_NUMBER() OVER (
            PARTITION BY r.site_id, EXTRACT(YEAR FROM r.date_time) 
            ORDER BY r.no2 DESC
        ) AS peak_rank
        
    FROM 
        no2_readings r
    INNER JOIN 
        valid_site_years v 
        ON r.site_id = v.site_id 
        AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
    WHERE 
        r.no2 >= -1.0 -- Clean out equipment error codes
)

-- Step 3: Extract only the top 19 hours
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
FROM 
    ranked_hourly_readings
WHERE 
    peak_rank <= 19
ORDER BY 
    site_id, 
    year, 
    peak_rank;

-- ============================================================================
-- INDEXES FOR POWER BI PERFORMANCE
-- ============================================================================
CREATE INDEX idx_top19_site_year 
    ON analytics_top19_hourly_peaks(site_id, year);


DROP TABLE IF EXISTS analytics_site_hourly_profiles;

CREATE TABLE analytics_site_hourly_profiles AS

WITH valid_site_years AS (
    -- Step 1: Retain the strict completeness rule (PASS% status)
    SELECT 
        site_id, 
        reading_year, 
        site_name
    FROM 
        stg_final_annualised_means
    WHERE 
        laqm_annual_mean_status LIKE 'PASS%'
)

-- Step 2: Aggregate regular hourly data across each site and year (0 to 23 hours)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    -- Calculate average and max pollution levels for each specific hour of the day
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
    
    
    WITH valid_site_years AS (
    SELECT site_id, reading_year, site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month, -- Added Month
    EXTRACT(HOUR FROM r.date_time) AS hour,
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0 
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(HOUR FROM r.date_time);
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0 -- Clean out equipment error codes
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(HOUR FROM r.date_time);

-- ============================================================================
-- INDEXES FOR POWER BI PERFORMANCE
-- ============================================================================
CREATE INDEX idx_hourly_profile_site_year 
    ON analytics_site_hourly_profiles(site_id, year);



CREATE TABLE analytics_site_hourly_monthly_profiles AS

WITH valid_site_years AS (
    SELECT site_id, reading_year, site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month, -- Added Month
    EXTRACT(HOUR FROM r.date_time) AS hour,
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0 
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(HOUR FROM r.date_time);

-- ============================================================================
-- INDEXES FOR POWER BI PERFORMANCE
-- ============================================================================
CREATE INDEX idx_hourly_monthly_profile_filters 
    ON analytics_site_hourly_monthly_profiles(site_id, year, month);


-- ============================================================================
-- TITLE: Analytics Site Hourly, Daily, & Monthly Profiles
-- DESCRIPTION: Aggregates NO2 readings by site, year, month, day of week, 
--              and hour to support granular diurnal and weekly diagnostics.
-- ============================================================================

DROP TABLE IF EXISTS analytics_site_hourly_weekly_profiles;

CREATE TABLE analytics_site_hourly_weekly_profiles AS

WITH valid_site_years AS (
    SELECT site_id, reading_year, site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month,
    -- Extract Day of Week (1 = Monday through 7 = Sunday in PostgreSQL ISODOW)
    EXTRACT(ISODOW FROM r.date_time) AS day_of_week_num,
    TO_CHAR(r.date_time, 'Day') AS day_of_week_name,
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
    
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(ISODOW FROM r.date_time),
    TO_CHAR(r.date_time, 'Day'),
    EXTRACT(HOUR FROM r.date_time);

-- Index for multi-attribute filtering in Power BI
CREATE INDEX idx_hourly_weekly_profile_filters 
    ON analytics_site_hourly_weekly_profiles(site_id, year, month, day_of_week_num);





-- ============================================================================
-- TITLE: Analytics Site Hourly, Daily, & Monthly Profiles
-- DESCRIPTION: Aggregates NO2 readings by site, year, month, day of week, 
--              and hour to support granular diurnal and weekly diagnostics.
-- ============================================================================

DROP TABLE IF EXISTS analytics_site_hourly_weekly_profiles;

CREATE TABLE analytics_site_hourly_weekly_profiles AS

WITH valid_site_years AS (
    SELECT site_id, reading_year, site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month,
    -- Extract Day of Week (1 = Monday through 7 = Sunday in PostgreSQL ISODOW)
    EXTRACT(ISODOW FROM r.date_time) AS day_of_week_num,
    TO_CHAR(r.date_time, 'Day') AS day_of_week_name,
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
    
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(ISODOW FROM r.date_time),
    TO_CHAR(r.date_time, 'Day'),
    EXTRACT(HOUR FROM r.date_time);

-- Index for multi-attribute filtering in Power BI
CREATE INDEX idx_hourly_weekly_profile_filters 
    ON analytics_site_hourly_weekly_profiles(site_id, year, month, day_of_week_num);









-- ============================================================================
-- TITLE: Analytics Site Hourly, Daily, & Monthly Profiles
-- DESCRIPTION: Aggregates NO2 readings by site, year, month, day of week, 
--              and hour to support granular diurnal and weekly diagnostics.
-- ============================================================================

DROP TABLE IF EXISTS analytics_site_hourly_weekly_profiles;

CREATE TABLE analytics_site_hourly_weekly_profiles AS

WITH valid_site_years AS (
    SELECT site_id, reading_year, site_name
    FROM stg_final_annualised_means
    WHERE laqm_annual_mean_status LIKE 'PASS%'
)
SELECT 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time) AS year,
    EXTRACT(MONTH FROM r.date_time) AS month,
    -- Extract Day of Week (1 = Monday through 7 = Sunday in PostgreSQL ISODOW)
    EXTRACT(ISODOW FROM r.date_time) AS day_of_week_num,
    TO_CHAR(r.date_time, 'Day') AS day_of_week_name,
    EXTRACT(HOUR FROM r.date_time) AS hour,
    
    ROUND(AVG(r.no2)::numeric, 2) AS avg_hourly_no2,
    MAX(r.no2) AS max_hourly_no2,
    COUNT(r.no2) AS sample_count
    
FROM 
    no2_readings r
INNER JOIN 
    valid_site_years v 
    ON r.site_id = v.site_id 
    AND EXTRACT(YEAR FROM r.date_time) = v.reading_year
WHERE 
    r.no2 >= -1.0
GROUP BY 
    r.site_id,
    v.site_name,
    EXTRACT(YEAR FROM r.date_time),
    EXTRACT(MONTH FROM r.date_time),
    EXTRACT(ISODOW FROM r.date_time),
    TO_CHAR(r.date_time, 'Day'),
    EXTRACT(HOUR FROM r.date_time);

-- Index for multi-attribute filtering in Power BI
CREATE INDEX idx_hourly_weekly_profile_filters 
    ON analytics_site_hourly_weekly_profiles(site_id, year, month, day_of_week_num);