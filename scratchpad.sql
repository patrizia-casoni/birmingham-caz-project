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


